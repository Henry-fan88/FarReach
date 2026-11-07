import { DurableObject } from "cloudflare:workers";

const encoder = new TextEncoder();
const AUTH_DOMAIN = encoder.encode("FarReach-signaling-auth-v1\0");
const KEY_DOMAIN = encoder.encode("FarReach-signaling-key-v1\0");
const MAX_PAYLOAD = 400 * 1024;
const MAX_MESSAGE = MAX_PAYLOAD + 1024;
const AUTH_TIMEOUT = 10_000;
const MAX_PEERS = 64;
const MAX_PENDING = 3;
const MESSAGES_PER_MINUTE = 120;
const BYTES_PER_MINUTE = 4 * 1024 * 1024;

interface KeyBundle {
  publicKey: string;
  agreementKey: string;
  keySignature: string;
}

interface Attachment {
  id: string;
  connection: string;
  phase: "pending" | "verifying" | "ready" | "closed";
  nonce?: string;
  deadline: number;
  window: number;
  messages: number;
  bytes: number;
  keys?: KeyBundle;
}

type JSONObject = Record<string, unknown>;

function object(value: unknown): JSONObject {
  if (value === null || typeof value !== "object" || Array.isArray(value)) throw new Error("invalid-message");
  return value as JSONObject;
}

function exactKeys(value: JSONObject, keys: string[]): void {
  if (Object.keys(value).length !== keys.length || keys.some((key) => !(key in value))) throw new Error("invalid-message");
}

export function encodeBase64URL(bytes: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 8192) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
  }
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

function decodeBase64URL(value: unknown, length?: number): Uint8Array<ArrayBuffer> {
  if (typeof value !== "string" || value.length === 0 || value.length > MAX_PAYLOAD || !/^[A-Za-z0-9_-]+$/.test(value)) {
    throw new Error("invalid-message");
  }
  let binary: string;
  try { binary = atob(value.replaceAll("-", "+").replaceAll("_", "/")); }
  catch { throw new Error("invalid-message"); }
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
  if ((length !== undefined && bytes.length !== length) || encodeBase64URL(bytes) !== value) throw new Error("invalid-message");
  return bytes;
}

function deviceID(value: unknown): string {
  decodeBase64URL(value, 32);
  return value as string;
}

function peerIDs(value: unknown, ownID: string): string[] {
  if (!Array.isArray(value) || value.length > MAX_PEERS) throw new Error("invalid-message");
  const peers = value.map(deviceID);
  if (new Set(peers).size !== peers.length || peers.includes(ownID)) throw new Error("invalid-message");
  return peers;
}

function concat(...values: Uint8Array[]): Uint8Array<ArrayBuffer> {
  const result = new Uint8Array(values.reduce((total, bytes) => total + bytes.length, 0));
  let offset = 0;
  for (const bytes of values) { result.set(bytes, offset); offset += bytes.length; }
  return result;
}

function attachment(ws: WebSocket): Attachment { return ws.deserializeAttachment() as Attachment; }

function send(ws: WebSocket, value: JSONObject): boolean {
  if (ws.readyState !== WebSocket.OPEN) return false;
  try { ws.send(JSON.stringify(value)); return true; }
  catch { return false; }
}

function close(ws: WebSocket, code: number, reason: string): void {
  const state = attachment(ws);
  state.phase = "closed";
  state.nonce = undefined;
  state.keys = undefined;
  ws.serializeAttachment(state);
  try { ws.close(code, reason); } catch { /* Already disconnected. */ }
}

function error(ws: WebSocket, code: string, to?: string, requestId?: string): void {
  send(ws, { type: "error", code, ...(to === undefined ? {} : { to }), ...(requestId === undefined ? {} : { requestId }) });
}

function correlation(body: JSONObject, required: string[]): { requestId?: string } {
  exactKeys(body, body.requestId === undefined ? required : [...required, "requestId"]);
  if (body.requestId === undefined) return {};
  if (typeof body.requestId !== "string" || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(body.requestId)) {
    throw new Error("invalid-message");
  }
  return { requestId: body.requestId };
}

export class DeviceMailbox extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // Peer lists can exceed the 2 KiB WebSocket attachment limit. Only the
    // current authenticated socket's ACL is held in SQLite; messages are never stored.
    this.ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS active (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), connection TEXT NOT NULL)");
    this.ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS peers (id TEXT PRIMARY KEY)");
    this.ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS connection_limit (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), started INTEGER NOT NULL, hits INTEGER NOT NULL)");
    this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const id = url.pathname.slice("/v1/devices/".length);
    if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("WebSocket required", { status: 426 });
    if (!this.env.DEVICES.idFromName(id).equals(this.ctx.id)) return new Response("Not found", { status: 404 });
    const sockets = this.ctx.getWebSockets();
    const pending = sockets.filter((ws) => ["pending", "verifying"].includes(attachment(ws).phase));
    if (pending.length >= MAX_PENDING) return new Response("Too many pending connections", { status: 429 });
    const now = Date.now();
    const previous = this.ctx.storage.sql.exec<{ started: number; hits: number }>("SELECT started, hits FROM connection_limit WHERE singleton = 1").toArray()[0];
    const started = previous && now - previous.started < 60_000 ? previous.started : now;
    const hits = previous && started === previous.started ? previous.hits + 1 : 1;
    if (hits > 30) return new Response("Connection rate exceeded", { status: 429 });
    this.ctx.storage.sql.exec("INSERT OR REPLACE INTO connection_limit (singleton, started, hits) VALUES (1, ?, ?)", started, hits);
    const pair = new WebSocketPair();
    const nonce = encodeBase64URL(crypto.getRandomValues(new Uint8Array(32)));
    this.ctx.acceptWebSocket(pair[1]);
    pair[1].serializeAttachment({
      id, connection: crypto.randomUUID(), phase: "pending", nonce,
      deadline: now + AUTH_TIMEOUT, window: now, messages: 0, bytes: 0,
    } satisfies Attachment);
    send(pair[1], { type: "challenge", nonce });
    await this.scheduleAuthenticationAlarm();
    return new Response(null, { status: 101, webSocket: pair[0] });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const state = attachment(ws);
    if (state.phase === "closed") return;
    if (typeof message !== "string" || message.length > MAX_MESSAGE || encoder.encode(message).length > MAX_MESSAGE) {
      error(ws, "invalid-message"); close(ws, 1009, "Message size or type rejected"); this.clearIfCurrent(state.connection); return;
    }
    const now = Date.now();
    if (now - state.window >= 60_000) { state.window = now; state.messages = 0; state.bytes = 0; }
    state.messages += 1; state.bytes += message.length;
    ws.serializeAttachment(state);
    if (state.messages > MESSAGES_PER_MINUTE || state.bytes > BYTES_PER_MINUTE) {
      error(ws, "rate-limited"); close(ws, 1008, "Message rate exceeded"); this.clearIfCurrent(state.connection); return;
    }
    try {
      const body = object(JSON.parse(message));
      if (state.phase === "pending") {
        await this.authenticate(ws, state, body);
        return;
      }
      if (!this.isCurrent(ws, state) || state.phase !== "ready") throw new Error("not-authenticated");
      if (body.type === "peers") {
        exactKeys(body, ["type", "peers"]);
        this.setPeers(peerIDs(body.peers, state.id));
      } else if (body.type === "lookup") {
        const correlated = correlation(body, ["type", "to"]);
        const to = deviceID(body.to);
        if (!this.allows(to)) { error(ws, "not-authorized", to, correlated.requestId); return; }
        const keys = await this.env.DEVICES.getByName(to).lookup(state.id);
        // Re-check after the RPC: Forget or socket replacement can run meanwhile.
        if (!this.isCurrent(ws, state) || !this.allows(to)) return;
        send(ws, keys ? { type: "peer", to, online: true, ...keys, ...correlated } : { type: "peer", to, online: false, ...correlated });
      } else if (body.type === "signal") {
        const correlated = correlation(body, ["type", "to", "payload"]);
        const to = deviceID(body.to);
        const bytes = decodeBase64URL(body.payload);
        if (bytes.length < 28) throw new Error("invalid-message"); // AES-GCM nonce + tag.
        if (!this.allows(to)) { error(ws, "not-authorized", to, correlated.requestId); return; }
        const delivered = await this.env.DEVICES.getByName(to).relay(state.id, state.keys!, body.payload as string);
        if (!this.isCurrent(ws, state)) return;
        if (delivered) send(ws, { type: "sent", to, ...correlated });
        else error(ws, "offline", to, correlated.requestId);
      } else throw new Error("invalid-message");
    } catch (failure) {
      const code = failure instanceof Error && ["invalid-message", "authentication-failed", "not-authenticated"].includes(failure.message)
        ? failure.message : "internal-error";
      error(ws, code);
      close(ws, 1008, "Signaling request rejected");
      this.clearIfCurrent(state.connection);
    }
  }

  private async authenticate(ws: WebSocket, state: Attachment, body: JSONObject): Promise<void> {
    exactKeys(body, ["type", "publicKey", "agreementKey", "keySignature", "signature", "peers"]);
    if (body.type !== "authenticate" || !state.nonce || Date.now() >= state.deadline) throw new Error("authentication-failed");
    const publicKey = decodeBase64URL(body.publicKey, 32);
    const agreementKey = decodeBase64URL(body.agreementKey, 32);
    const keySignature = decodeBase64URL(body.keySignature, 64);
    const signature = decodeBase64URL(body.signature, 64);
    const peers = peerIDs(body.peers, state.id);
    const nonce = decodeBase64URL(state.nonce, 32);
    // Consume the challenge before crypto awaits so duplicate/reordered auth
    // cannot share one nonce, including after a hibernation wakeup.
    state.phase = "verifying"; state.nonce = undefined;
    ws.serializeAttachment(state);
    const identifier = encodeBase64URL(new Uint8Array(await crypto.subtle.digest("SHA-256", publicKey)));
    if (identifier !== state.id) throw new Error("authentication-failed");
    const key = await crypto.subtle.importKey("raw", publicKey, { name: "Ed25519" }, false, ["verify"]);
    const validKey = await crypto.subtle.verify("Ed25519", key, keySignature, concat(KEY_DOMAIN, agreementKey));
    const validAuth = await crypto.subtle.verify("Ed25519", key, signature, concat(AUTH_DOMAIN, nonce, agreementKey));
    if (!validKey || !validAuth || Date.now() >= state.deadline || attachment(ws).phase !== "verifying" || ws.readyState !== WebSocket.OPEN) {
      throw new Error("authentication-failed");
    }
    for (const other of this.ctx.getWebSockets()) {
      if (other !== ws && attachment(other).phase === "ready") close(other, 4001, "Replaced by authenticated connection");
    }
    this.ctx.storage.sql.exec("INSERT OR REPLACE INTO active (singleton, connection) VALUES (1, ?)", state.connection);
    this.setPeers(peers);
    state.phase = "ready";
    state.keys = { publicKey: body.publicKey as string, agreementKey: body.agreementKey as string, keySignature: body.keySignature as string };
    ws.serializeAttachment(state);
    send(ws, { type: "ready", capabilities: ["request-correlation-v1"] });
    await this.scheduleAuthenticationAlarm();
  }

  /** Internal binding RPC only. There is no corresponding public HTTP route. */
  lookup(requester: string): KeyBundle | null {
    if (!this.allows(requester)) return null;
    const ws = this.currentSocket();
    return ws ? attachment(ws).keys! : null;
  }

  /** Sender identity/keys originate only in an authenticated source mailbox. */
  relay(from: string, keys: KeyBundle, payload: string): boolean {
    if (!this.allows(from)) return false;
    const ws = this.currentSocket();
    if (!ws) return false;
    // Bound aggregate fan-in from all trusted peers as well as each sender.
    const state = attachment(ws);
    const now = Date.now();
    if (now - state.window >= 60_000) { state.window = now; state.messages = 0; state.bytes = 0; }
    state.messages += 1; state.bytes += payload.length;
    ws.serializeAttachment(state);
    if (state.messages > MESSAGES_PER_MINUTE || state.bytes > BYTES_PER_MINUTE) {
      error(ws, "rate-limited"); close(ws, 1008, "Message rate exceeded"); this.clearIfCurrent(state.connection); return false;
    }
    return send(ws, { type: "signal", from, payload, ...keys });
  }

  webSocketClose(ws: WebSocket, code: number): void {
    const state = attachment(ws);
    close(ws, code === 1005 || code === 1006 ? 1000 : code, "Connection closed");
    this.clearIfCurrent(state.connection);
  }

  webSocketError(ws: WebSocket): void {
    const state = attachment(ws);
    close(ws, 1011, "Connection failed");
    this.clearIfCurrent(state.connection);
  }

  async alarm(): Promise<void> {
    for (const ws of this.ctx.getWebSockets()) {
      const state = attachment(ws);
      if ((state.phase === "pending" || state.phase === "verifying") && state.deadline <= Date.now()) {
        error(ws, "authentication-failed"); close(ws, 1008, "Authentication timed out");
      }
    }
    await this.scheduleAuthenticationAlarm();
  }

  private currentConnection(): string | undefined {
    return this.ctx.storage.sql.exec<{ connection: string }>("SELECT connection FROM active WHERE singleton = 1").toArray()[0]?.connection;
  }

  private currentSocket(): WebSocket | undefined {
    const current = this.currentConnection();
    return this.ctx.getWebSockets().find((ws) => {
      const state = attachment(ws);
      return ws.readyState === WebSocket.OPEN && state.phase === "ready" && state.connection === current;
    });
  }

  private isCurrent(ws: WebSocket, original: Attachment): boolean {
    return ws.readyState === WebSocket.OPEN && attachment(ws).phase === "ready" && this.currentConnection() === original.connection;
  }

  private allows(id: string): boolean {
    return this.ctx.storage.sql.exec("SELECT id FROM peers WHERE id = ?", id).toArray().length === 1;
  }

  private setPeers(peers: string[]): void {
    this.ctx.storage.sql.exec("DELETE FROM peers");
    for (const id of peers) this.ctx.storage.sql.exec("INSERT INTO peers (id) VALUES (?)", id);
  }

  private clearIfCurrent(connection: string): void {
    if (this.currentConnection() !== connection) return;
    this.ctx.storage.sql.exec("DELETE FROM active");
    this.ctx.storage.sql.exec("DELETE FROM peers");
  }

  private async scheduleAuthenticationAlarm(): Promise<void> {
    const deadlines = this.ctx.getWebSockets().map(attachment)
      .filter((state) => state.phase === "pending" || state.phase === "verifying").map((state) => state.deadline);
    if (deadlines.length) await this.ctx.storage.setAlarm(Math.min(...deadlines));
    else await this.ctx.storage.deleteAlarm();
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health" && request.method === "GET") {
      return Response.json({ service: "farreach-signaling", protocol: 1 }, { headers: { "Cache-Control": "no-store" } });
    }
    const match = /^\/v1\/devices\/([A-Za-z0-9_-]{43})$/.exec(url.pathname);
    if (!match || url.search) return new Response("Not found", { status: 404 });
    try { deviceID(match[1]); } catch { return new Response("Not found", { status: 404 }); }
    if (request.method !== "GET") return new Response("Method not allowed", { status: 405, headers: { Allow: "GET" } });
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response("WebSocket required", { status: 426 });
    // This endpoint is for the native app; accepting arbitrary browser origins
    // would unnecessarily expose a cross-site WebSocket access surface.
    if (request.headers.has("Origin")) return new Response("Origin not allowed", { status: 403 });
    const ip = request.headers.get("CF-Connecting-IP") ?? "local-development";
    if (!(await env.CONNECTION_RATE_LIMITER.limit({ key: ip })).success) return new Response("Connection rate exceeded", { status: 429 });
    return env.DEVICES.getByName(match[1]).fetch(request);
  },
} satisfies ExportedHandler<Env>;
