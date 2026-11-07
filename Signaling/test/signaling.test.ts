import { env, exports } from "cloudflare:workers";
import { evictDurableObject, reset, runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { afterEach, describe, expect, it } from "vitest";
import { encodeBase64URL } from "../src/index";

const encoder = new TextEncoder();
type Message = Record<string, unknown>;
const sockets: Client[] = [];

function decode(text: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(atob(text.replaceAll("-", "+").replaceAll("_", "/")), (c) => c.charCodeAt(0));
}

function bytes(...parts: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const result = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) { result.set(part, offset); offset += part.length; }
  return result;
}

async function identity() {
  const generated = await crypto.subtle.generateKey("Ed25519", true, ["sign", "verify"]);
  if (!("privateKey" in generated)) throw new Error("Expected Ed25519 key pair");
  const exported = await crypto.subtle.exportKey("raw", generated.publicKey);
  if (!(exported instanceof ArrayBuffer)) throw new Error("Expected raw Ed25519 key");
  const raw = new Uint8Array(exported);
  const agreement = crypto.getRandomValues(new Uint8Array(32));
  const publicKey = encodeBase64URL(raw);
  const agreementKey = encodeBase64URL(agreement);
  const keySignature = encodeBase64URL(new Uint8Array(await crypto.subtle.sign("Ed25519", generated.privateKey,
    bytes(encoder.encode("FarReach-signaling-key-v1\0"), agreement))));
  return {
    id: encodeBase64URL(new Uint8Array(await crypto.subtle.digest("SHA-256", raw))), publicKey, agreementKey, keySignature,
    async auth(nonce: string, peers: string[]) {
      const signature = encodeBase64URL(new Uint8Array(await crypto.subtle.sign("Ed25519", generated.privateKey,
        bytes(encoder.encode("FarReach-signaling-auth-v1\0"), decode(nonce), agreement))));
      return { type: "authenticate", publicKey, agreementKey, keySignature, signature, peers };
    },
  };
}

class Client {
  private queue: string[] = [];
  private waiting: Array<(value: string) => void> = [];
  readonly closed: Promise<number>;
  constructor(readonly ws: WebSocket) {
    ws.addEventListener("message", (event) => {
      const value = String(event.data);
      const waiting = this.waiting.shift();
      if (waiting) waiting(value); else this.queue.push(value);
    });
    this.closed = new Promise((resolve) => ws.addEventListener("close", (event) => resolve(event.code)));
    ws.accept();
    sockets.push(this);
  }
  send(message: Message | string): void { this.ws.send(typeof message === "string" ? message : JSON.stringify(message)); }
  async raw(): Promise<string> {
    if (this.queue.length) return this.queue.shift()!;
    return new Promise((resolve) => this.waiting.push(resolve));
  }
  async next(): Promise<Message> { return JSON.parse(await this.raw()) as Message; }
  close(): void { try { this.ws.close(1000, "Test complete"); } catch { /* Already closed. */ } }
}

async function open(id: string): Promise<Client> {
  const response = await exports.default.fetch(`https://example.com/v1/devices/${id}`, { headers: { Upgrade: "websocket" } });
  expect(response.status).toBe(101);
  expect(response.webSocket).not.toBeNull();
  return new Client(response.webSocket!);
}

async function connect(device: Awaited<ReturnType<typeof identity>>, peers: string[]): Promise<Client> {
  const client = await open(device.id);
  const challenge = await client.next();
  expect(challenge.type).toBe("challenge");
  client.send(await device.auth(challenge.nonce as string, peers));
  expect(await client.next()).toEqual({ type: "ready", capabilities: ["request-correlation-v1"] });
  return client;
}

afterEach(async () => {
  for (const client of sockets) client.close();
  sockets.length = 0;
  await reset();
});

describe("Cloudflare signaling runtime", () => {
  it("echoes optional request correlation without forwarding it to the recipient", async () => {
    const a = await identity(), b = await identity();
    const alice = await connect(a, [b.id]), bob = await connect(b, [a.id]);
    const lookup = crypto.randomUUID();
    alice.send({ type: "lookup", to: b.id, requestId: lookup });
    expect(await alice.next()).toMatchObject({ type: "peer", to: b.id, online: true, requestId: lookup });
    const requestId = crypto.randomUUID();
    alice.send({ type: "signal", to: b.id, requestId, payload: encodeBase64URL(new Uint8Array(28)) });
    expect(await bob.next()).not.toHaveProperty("requestId");
    expect(await alice.next()).toEqual({ type: "sent", to: b.id, requestId });
    const unauthorized = await identity();
    const denied = crypto.randomUUID();
    alice.send({ type: "lookup", to: unauthorized.id, requestId: denied });
    expect(await alice.next()).toEqual({ type: "error", code: "not-authorized", to: unauthorized.id, requestId: denied });
  });

  it("rejects malformed request correlation without echoing unbounded data", async () => {
    const a = await identity(), b = await identity();
    const alice = await connect(a, [b.id]);
    alice.send({ type: "lookup", to: b.id, requestId: "not-a-request-id" });
    expect(await alice.next()).toEqual({ type: "error", code: "invalid-message" });
    expect(await alice.closed).toBe(1008);
  });

  it("serves health, validates routes, and refuses browser origins and HTTP access", async () => {
    expect(await (await exports.default.fetch("https://example.com/health")).json()).toEqual({ service: "farreach-signaling", protocol: 1 });
    expect((await exports.default.fetch("https://example.com/v1/devices/invalid")).status).toBe(404);
    const a = await identity();
    const url = `https://example.com/v1/devices/${a.id}`;
    expect((await exports.default.fetch(url)).status).toBe(426);
    expect((await exports.default.fetch(url, { method: "POST" })).status).toBe(405);
    expect((await exports.default.fetch(url, { headers: { Upgrade: "websocket", Origin: "https://untrusted.example" } })).status).toBe(403);
    expect((await exports.default.fetch(`${url}?token=unwanted`, { headers: { Upgrade: "websocket" } })).status).toBe(404);
  });

  it("relays opaque AES-GCM data only between mutually trusted authenticated peers", async () => {
    const a = await identity(), b = await identity();
    const alice = await connect(a, [b.id]), bob = await connect(b, [a.id]);
    alice.send({ type: "lookup", to: b.id });
    expect(await alice.next()).toEqual({ type: "peer", to: b.id, online: true, publicKey: b.publicKey, agreementKey: b.agreementKey, keySignature: b.keySignature });
    const key = await crypto.subtle.generateKey({ name: "AES-GCM", length: 256 }, false, ["encrypt", "decrypt"]);
    if ("privateKey" in key) throw new Error("Expected AES symmetric key");
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const encrypted = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, encoder.encode("synthetic private offer")));
    const payload = encodeBase64URL(bytes(iv, encrypted));
    alice.send({ type: "signal", to: b.id, payload });
    const delivered = await bob.next();
    expect(delivered).toEqual({ type: "signal", from: a.id, payload, publicKey: a.publicKey, agreementKey: a.agreementKey, keySignature: a.keySignature });
    expect(await alice.next()).toEqual({ type: "sent", to: b.id });
    const received = decode(delivered.payload as string);
    expect(new TextDecoder().decode(await crypto.subtle.decrypt({ name: "AES-GCM", iv: received.slice(0, 12) }, key, received.slice(12)))).toBe("synthetic private offer");
  });

  it("does not reveal presence without mutual approval and applies Forget immediately", async () => {
    const a = await identity(), b = await identity();
    const alice = await connect(a, [b.id]), bob = await connect(b, []);
    alice.send({ type: "lookup", to: b.id });
    expect(await alice.next()).toEqual({ type: "peer", to: b.id, online: false });
    bob.send({ type: "peers", peers: [a.id] });
    bob.send({ type: "lookup", to: a.id });
    expect((await bob.next()).online).toBe(true);
    alice.send({ type: "peers", peers: [] });
    alice.send({ type: "lookup", to: b.id });
    expect(await alice.next()).toEqual({ type: "error", code: "not-authorized", to: b.id });
    bob.send({ type: "signal", to: a.id, payload: encodeBase64URL(new Uint8Array(28)) });
    expect(await bob.next()).toEqual({ type: "error", code: "offline", to: a.id });
  });

  it("rejects auth replay without displacing the real authenticated socket", async () => {
    const a = await identity(), b = await identity();
    const first = await open(a.id);
    const auth = await a.auth((await first.next()).nonce as string, [b.id]);
    first.send(auth); expect(await first.next()).toEqual({ type: "ready", capabilities: ["request-correlation-v1"] });
    const replay = await open(a.id);
    expect((await replay.next()).type).toBe("challenge");
    replay.send(auth);
    expect(await replay.next()).toEqual({ type: "error", code: "authentication-failed" });
    expect(await replay.closed).toBe(1008);
    first.send({ type: "lookup", to: b.id });
    expect(await first.next()).toEqual({ type: "peer", to: b.id, online: false });
  });

  it("rejects forged identity and tampered agreement key signatures", async () => {
    const a = await identity(), b = await identity();
    const impostor = await open(a.id);
    impostor.send(await b.auth((await impostor.next()).nonce as string, []));
    expect((await impostor.next()).code).toBe("authentication-failed");
    const tampered = await open(a.id);
    const auth = await a.auth((await tampered.next()).nonce as string, []);
    auth.keySignature = b.keySignature;
    tampered.send(auth);
    expect((await tampered.next()).code).toBe("authentication-failed");
  });

  it("rejects client-supplied sender identities and oversized payloads", async () => {
    const a = await identity(), b = await identity();
    const alice = await connect(a, [b.id]);
    alice.send({ type: "signal", from: b.id, to: b.id, payload: encodeBase64URL(new Uint8Array(28)) });
    expect((await alice.next()).code).toBe("invalid-message");
    const second = await connect(a, [b.id]);
    second.send({ type: "signal", to: b.id, payload: "A".repeat(401 * 1024) });
    expect((await second.next()).code).toBe("invalid-message");
    expect(await second.closed).toBe(1009);
  });

  it("replaces a socket only after valid fresh authentication", async () => {
    const a = await identity();
    const first = await connect(a, []);
    const second = await connect(a, []);
    expect(await first.closed).toBe(4001);
    second.send("ping");
    expect(await second.raw()).toBe("pong");
  });

  it("keeps key metadata and all 64 ACL entries through hibernation", async () => {
    const a = await identity(), b = await identity();
    const extra = Array.from({ length: 63 }, () => encodeBase64URL(crypto.getRandomValues(new Uint8Array(32))));
    const alice = await connect(a, [b.id, ...extra]), bob = await connect(b, [a.id]);
    await evictDurableObject(env.DEVICES.getByName(a.id));
    await evictDurableObject(env.DEVICES.getByName(b.id));
    alice.send({ type: "lookup", to: b.id });
    expect((await alice.next()).online).toBe(true);
    bob.send({ type: "signal", to: a.id, payload: encodeBase64URL(new Uint8Array(28)) });
    expect((await alice.next()).from).toBe(b.id);
    expect((await bob.next()).type).toBe("sent");
  });

  it("expires unauthenticated sockets and caps pending connections", async () => {
    const a = await identity();
    const pending = await Promise.all([open(a.id), open(a.id), open(a.id)]);
    for (const client of pending) await client.next();
    const limited = await exports.default.fetch(`https://example.com/v1/devices/${a.id}`, { headers: { Upgrade: "websocket" } });
    expect(limited.status).toBe(429);
    const stub = env.DEVICES.getByName(a.id);
    await runInDurableObject(stub, (_instance, state) => {
      for (const ws of state.getWebSockets()) {
        const data = ws.deserializeAttachment() as { deadline: number };
        data.deadline = Date.now() - 1;
        ws.serializeAttachment(data);
      }
    });
    expect(await runDurableObjectAlarm(stub)).toBe(true);
    for (const client of pending) expect((await client.next()).code).toBe("authentication-failed");
  });

  it("bounds authenticated traffic and fails closed on unauthenticated operations", async () => {
    const a = await identity(), b = await identity();
    const unauthed = await open(a.id);
    await unauthed.next();
    unauthed.send({ type: "lookup", to: b.id });
    expect((await unauthed.next()).code).toBe("invalid-message");
    const alice = await connect(a, [b.id]);
    await runInDurableObject(env.DEVICES.getByName(a.id), (_instance, state) => {
      for (const ws of state.getWebSockets()) {
        const data = ws.deserializeAttachment() as { phase: string; messages: number };
        if (data.phase === "ready") { data.messages = 120; ws.serializeAttachment(data); }
      }
    });
    alice.send({ type: "lookup", to: b.id });
    expect((await alice.next()).code).toBe("rate-limited");
    expect(await alice.closed).toBe(1008);
  });
});
