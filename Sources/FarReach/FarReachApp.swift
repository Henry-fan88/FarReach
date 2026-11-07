import SwiftUI
import AppKit
import RemoteMedia
import RemoteCore

@main
struct FarReachApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updates = UpdateManager()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("FarReach") {
            ContentView(model: model, updates: updates)
                .frame(minWidth: 860, minHeight: 610)
                .onAppear { delegate.model = model; updates.attach(to: model); NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refreshPermissions() }
        }
        .defaultSize(width: 1080, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
                Divider()
                Button("End Viewing") { model.endViewing() }.keyboardShortcut(".", modifiers: [.command, .shift]).disabled(!model.isViewing)
                Button("Stop Sharing and Close Connection") { model.shutdown() }
            }
        }
        MenuBarExtra("FarReach", systemImage: model.isHosting ? "display.badge.shield.checkmark" : "display.2") {
            Text(model.status)
            Button("Show FarReach") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first?.makeKeyAndOrderFront(nil) }
            if model.isHosting { Button("Stop Sharing") { model.stopHosting() } }
            if model.isViewing { Button("End viewing") { model.endViewing() } }
            if model.canResumeViewing && !model.isViewing { Button("Resume viewing") { model.resumeViewing() } }
            if model.canResumeViewing || model.isConnecting { Button("Close connection") { model.disconnect() } }
            Divider()
            Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
            Button("Quit FarReach") { model.shutdown(); NSApp.terminate(nil) }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct RemoteSurface: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> RemoteDesktopView { model.desktop }
    func updateNSView(_ nsView: RemoteDesktopView, context: Context) {}
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: UpdateManager
    private let accent = Color(red: 0.18, green: 0.36, blue: 0.82)
    private var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unpackaged" }
    var body: some View {
        HStack(spacing: 0) {
            if !model.isViewing {
                VStack(alignment: .leading, spacing: 28) {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.up.right.video.fill").font(.title2).foregroundStyle(accent)
                        Text("FarReach").font(.system(size: 23, weight: .semibold, design: .rounded))
                    }.padding(.top, 26)
                    VStack(spacing: 8) {
                        ForEach(AppModel.Page.allCases, id: \.self) { page in
                            Button { model.page = page } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: icon(page)).frame(width: 22)
                                    Text(page.rawValue).fontWeight(.medium)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 13).padding(.vertical, 12)
                                .background(model.page == page ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                                .foregroundStyle(model.page == page ? accent : .primary)
                            }.buttonStyle(.plain)
                        }
                    }
                    Spacer()
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Mac to Mac", systemImage: "laptopcomputer.and.arrow.down").font(.callout.weight(.medium))
                        Text("Your screen. Your source.\nNo app subscription.").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                        Text("DEVELOPMENT BUILD · \(appVersion)").font(.system(size: 9, weight: .semibold, design: .monospaced)).foregroundStyle(.tertiary).padding(.top, 8)
                    }.padding(.bottom, 24)
                }.padding(.horizontal, 20).frame(width: 220)
                    .background(Color(nsColor: .controlBackgroundColor))
                Divider()
            }
            VStack(spacing: 0) {
                if model.isViewing { viewer } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            switch model.page {
                            case .share: share
                            case .connect: connect
                            case .devices: devices
                            case .setup: setup
                            }
                            if let error = model.error {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                    Text(error).font(.callout).textSelection(.enabled)
                                    Spacer()
                                    Button { model.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                                }.padding(14).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            }
                        }.padding(36).frame(maxWidth: 830, alignment: .leading).frame(maxWidth: .infinity)
                    }
                }
                Divider()
                HStack(spacing: 9) {
                    Circle().fill(model.isHosting || model.isViewing ? Color.green : .gray).frame(width: 6, height: 6)
                    Text(model.status).font(.caption).lineLimit(1)
                    Spacer()
                    if model.hasViewer || model.isViewing { metrics }
                    if !model.connectionPath.isEmpty { Text(model.connectionPath).font(.caption).foregroundStyle(.secondary) }
                    Label("Encrypted pairing", systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                }.padding(.horizontal, 18).frame(height: 38).background(.bar)
            }
        }.tint(accent)
    }

    private func title(_ eyebrow: String, _ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(eyebrow).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(accent)
            Text(title).font(.system(size: 32, weight: .semibold, design: .rounded))
            Text(subtitle).font(.body).foregroundStyle(.secondary).lineSpacing(3)
        }.padding(.top, 4).padding(.bottom, 5)
    }
    private var share: some View {
        Group {
            title("THIS MAC → YOUR OTHER MAC", "Bring your Mac with you.", "Share this Mac’s main display, then connect from your other Mac.")
            card {
                HStack {
                    Image(systemName: "desktopcomputer").font(.system(size: 28)).foregroundStyle(accent).frame(width: 48)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Host.current().localizedName ?? "This Mac").font(.headline)
                        Text(model.isHosting ? "Sharing is on" : "Private until you start sharing").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isHosting {
                        Button("Stop Sharing", role: .destructive) { model.stopHosting() }.buttonStyle(.bordered)
                    }
                }
                Divider().padding(.vertical, 5)
                Picker("Connection", selection: $model.connectionMode) {
                    ForEach(AppModel.ConnectionMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).disabled(model.isHosting)
                if model.connectionMode == .local {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Address your other Mac can reach").font(.callout.weight(.medium))
                        HStack {
                            TextField("IP address or host name", text: $model.address).textFieldStyle(.roundedBorder)
                            Menu {
                                ForEach(AppModel.addresses(), id: \.self) { address in Button(address) { model.address = address } }
                                Button("Refresh addresses") { model.address = AppModel.addresses().first ?? "" }
                            } label: { Image(systemName: "network") }.frame(width: 34)
                        }.disabled(model.isHosting)
                        Text("Use a reachable address on your LAN or an existing private network. This connection does not need a discovery service.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Your Macs connect directly", systemImage: "point.3.connected.trianglepath.dotted").font(.callout.weight(.medium))
                        Text("Pair once with a private invitation and response. With Cloudflare signaling configured, saved Macs can connect again without repeating that exchange. Screen and control traffic stay between the two Macs.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("A discovery service helps find public addresses. Some managed networks and hotspots block direct connections.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("Video quality").font(.callout.weight(.medium))
                    Spacer()
                    Picker("Video quality", selection: $model.quality) {
                        ForEach(AppModel.Quality.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 245).disabled(model.isHosting)
                }.padding(.vertical, 8)
                if !model.isHosting {
                    if model.connectionMode == .internet && !model.signalingURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.pairedDevices.isEmpty {
                        Button { model.startCloudHosting() } label: {
                            Label("Be available to paired Macs", systemImage: "cloud").frame(maxWidth: .infinity).padding(.vertical, 6)
                        }.buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(model.isViewing || model.isConnecting || model.canResumeViewing)
                        Text(model.signalingStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Button { model.startHosting() } label: { Label(model.connectionMode == .internet ? "Create invitation" : "Start Sharing", systemImage: "dot.radiowaves.left.and.right").frame(maxWidth: .infinity).padding(.vertical, 6) }
                        .buttonStyle(.bordered).controlSize(.large)
                        .disabled(model.isViewing || model.isConnecting || model.canResumeViewing || (model.connectionMode == .local && model.address.trimmingCharacters(in: .whitespaces).isEmpty))
                } else if model.cloudHosting {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Sharing with paired Macs is enabled", systemImage: "cloud").font(.headline)
                        Text(model.signalingStatus).font(.callout).foregroundStyle(.secondary)
                        Text("On your other Mac, open Paired Macs and choose Connect. Keep FarReach running here. Stop Sharing ends access.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(14).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Your private invitation", systemImage: "key.fill").font(.headline)
                            Spacer()
                            Button(model.copied ? "Copied" : "Copy invitation") { model.copyInvitation() }.disabled(model.invitation.isEmpty)
                        }
                        Text("Paste it in FarReach on your other Mac. Anyone with this invitation can connect while sharing is on. Stop Sharing revokes it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(14).background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    if model.connectionMode == .internet && model.connectedDeviceID == nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Finish pairing on this Mac").font(.headline)
                            SecureField("Paste the other Mac’s response", text: $model.pastedResponse).textFieldStyle(.roundedBorder)
                            Button("Finish pairing") { model.finishInternetPairing() }.disabled(model.pastedResponse.isEmpty || model.invitation.isEmpty)
                            Text("This first exchange saves device trust. Use End viewing / Resume for the current connection, or configure Cloudflare signaling in Setup to connect again later.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            HStack(spacing: 20) {
                permissionBadge("Screen Recording", granted: model.screenAllowed)
                permissionBadge("Remote input", granted: model.controlAllowed)
                Spacer()
                Button("Manage permissions") { model.page = .setup }.buttonStyle(.link)
            }
            Text("FarReach keeps this Mac awake while sharing. Closing the window leaves sharing active; use Stop Sharing in the window or menu bar to end access.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var connect: some View {
        Group {
            title("YOUR OTHER MAC → HERE", "A familiar screen, anywhere.", "Start sharing on your other Mac, then paste its private invitation here.")
            card {
                Label("Connect with an invitation", systemImage: "link").font(.headline)
                SecureField("Paste a FarReach invitation", text: $model.pastedInvitation)
                    .textFieldStyle(.roundedBorder).controlSize(.large)
                    .onSubmit { model.connect() }.disabled(model.isConnecting || model.isHosting)
                Text("The invitation contains the address and a secret pairing key. It stays in memory and is cleared after connecting.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if model.isConnecting { ProgressView().controlSize(.small); Text(model.connectionResponse.isEmpty ? "Preparing connection…" : "Waiting for the sharing Mac…").font(.callout); Spacer(); Button("Cancel") { model.disconnect() } }
                    else { Button { model.connect() } label: { Label("Connect", systemImage: "arrow.up.right").frame(maxWidth: .infinity).padding(.vertical, 6) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.pastedInvitation.isEmpty || model.isHosting) }
                }.padding(.top, 6)
                if !model.connectionResponse.isEmpty {
                    Divider()
                    HStack {
                        Label("Send a response back", systemImage: "arrow.uturn.backward").font(.headline)
                        Spacer()
                        Button(model.responseCopied ? "Copied" : "Copy response") { model.copyResponse() }
                    }
                    Text("On the sharing Mac, paste this response and choose Finish pairing. Keep both apps open. This connection uses no traffic relay.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            card {
                Label("Across different networks", systemImage: "globe").font(.headline)
                Text("Choose Direct Internet on the sharing Mac. FarReach discovers a direct encrypted path without a VPN. If the network prevents direct UDP, the connection fails rather than using a relay.")
                    .foregroundStyle(.secondary)
                Button("View setup steps") { model.page = .setup }.buttonStyle(.link)
            }
            Text("Click the remote screen to send mouse and keyboard input. Full keyboard control also sends app and system shortcuts. Control–Option–Escape releases keyboard focus; Shift–Command–. ends viewing and keeps the paired connection open.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var devices: some View {
        Group {
            title("PAIRED ONCE. READY TO RETURN.", "Your trusted Macs.", "Device identities are saved in this Mac’s Keychain. Resume an open connection, or use Cloudflare signaling to connect again.")
            if model.pairedDevices.isEmpty {
                card {
                    Label("No paired Macs yet", systemImage: "desktopcomputer").font(.headline)
                    Text("Complete an invitation and response exchange once. FarReach will remember that Mac’s identity.").foregroundStyle(.secondary)
                }
            }
            ForEach(model.pairedDevices, id: \.id) { device in
                card {
                    HStack {
                        Image(systemName: "desktopcomputer").font(.title2)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(device.name).font(.headline)
                            Text(model.connectedDeviceID == device.id ? "Authenticated connection is open" : "Trust saved · connection is not open").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.canResumeViewing && model.connectedDeviceID == device.id {
                            Button("Resume") { model.resumeViewing() }.buttonStyle(.borderedProminent)
                        } else if model.connectedDeviceID != device.id {
                            if model.signalingReady {
                                Button("Connect") { model.connectPairedDevice(device) }.buttonStyle(.borderedProminent)
                                    .disabled(model.isHosting || model.isConnecting || model.canResumeViewing)
                            } else {
                                Button("Set up connection") { model.setUpConnection(to: device) }
                                    .disabled(model.isHosting || model.isConnecting || model.canResumeViewing)
                            }
                        }
                        Button("Forget", role: .destructive) { model.forgetDevice(device.id) }
                    }
                }
            }
            Button(model.pairedDevices.isEmpty ? "Pair a Mac" : "Pair another Mac") { model.pairAnotherMac() }
                .disabled(model.isConnecting || model.isHosting || model.canResumeViewing)
            if model.canResumeViewing {
                Button("Close the background connection") { model.disconnect() }
            }
            if model.isConnecting {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.status).font(.callout)
                    Spacer()
                    Button("Cancel") { model.disconnect() }
                }
            }
            Text(model.signalingStatus).font(.caption).foregroundStyle(.secondary)
            Text("For a new connection, both Macs need the same signaling service in Setup. The sharing Mac must choose Be available to paired Macs. Opening FarReach after a restart does not start sharing automatically.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var setup: some View {
        Group {
            title("A FEW THINGS, ONCE", "Make the connection yours.", "Set up access on the Mac you want to control. The viewing Mac doesn’t need capture permissions.")
            card {
                Label("App updates", systemImage: "arrow.down.circle").font(.headline)
                Text(updates.status).font(.callout).foregroundStyle(.secondary)
                if updates.configuration == .configured {
                    Toggle("Automatically check for updates", isOn: Binding(get: { updates.automaticallyChecks }, set: updates.setAutomaticallyChecks))
                    Toggle("Download and install updates automatically", isOn: Binding(get: { updates.automaticallyInstalls }, set: updates.setAutomaticallyInstalls))
                    Button("Check for Updates…") { updates.checkForUpdates() }.disabled(!updates.canCheckForUpdates)
                    Text(updates.waitingForIdle
                         ? "An update is ready. Stop sharing and close any background connection to install it."
                         : "Installation waits until sharing, viewing, and background connections have stopped. FarReach then restarts; sharing stays off until you enable it again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            card {
                setupRow("1", "Allow Screen Recording", "Required on the sharing Mac. macOS may ask you to quit and reopen FarReach.") {
                    Button(model.screenAllowed ? "Allowed" : "Open Settings") { model.requestScreenPermission() }
                }
                Divider()
                setupRow("2", "Allow Accessibility", "Required on the sharing Mac for mouse and keyboard control, and on the viewing Mac to send system shortcuts to the remote desktop.") {
                    Button(model.controlAllowed ? "Allowed" : "Open Settings") { model.requestControlPermission() }
                }
                Divider()
                setupRow("3", "Exchange an invitation and response", "Choose Direct Internet to connect across networks. Paste the other Mac’s response on the sharing Mac to complete pairing.") {
                    Button("Share this Mac") { model.page = .share }
                }
            }
            card {
                Label("Keyboard control", systemImage: "keyboard").font(.headline)
                Toggle("Full keyboard control", isOn: Binding(get: { model.fullKeyboardControl }, set: { model.setFullKeyboardControl($0) }))
                Text("When the remote screen has focus, send typing, navigation keys, app shortcuts and system shortcuts to that Mac. Click the screen to focus it. Control–Option–Escape returns keyboard focus to this Mac; Shift–Command–. ends viewing.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Allow Accessibility on this viewing Mac to capture system shortcuts such as Command–Tab and Command–Shift–4/5. No text field needs to be selected on the remote Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card {
                Label("Cloudflare signaling", systemImage: "cloud").font(.headline)
                Text("Deploy your own signaling service and enter the same URL on both Macs. Pair once with an invitation and response, then choose Be available to paired Macs on the host and Connect from Paired Macs on the viewer.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("https://your-signaling-service.workers.dev", text: $model.signalingURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.saveSignalingSettings() }
                    Button("Save") { model.saveSignalingSettings() }
                }.disabled(model.isHosting || model.isConnecting || model.canResumeViewing)
                Text(model.signalingStatus).font(.caption).foregroundStyle(.secondary)
                Text("The service carries encrypted connection setup messages. Your screen, keyboard input, and Mac password stay on the direct connection. Leave the URL empty to use manual setup only.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Both networks must reach the signaling service and allow a direct UDP connection. Test access on the networks you plan to use.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            card {
                Label("No VPN. No desktop relay.", systemImage: "network.badge.shield.half.filled").font(.headline)
                Text("FarReach uses an open-source connection engine bundled in the app. A STUN service sees network addresses for discovery. Cloudflare signaling helps saved Macs establish a fresh connection; desktop traffic travels directly between the Macs.").font(.callout).foregroundStyle(.secondary)
                TextField("STUN discovery URL (leave empty for local address discovery only)", text: $model.stunServer)
                    .textFieldStyle(.roundedBorder).disabled(model.isHosting || model.isConnecting || model.isViewing)
                Link("About the default free discovery service ↗", destination: URL(string: "https://developers.cloudflare.com/realtime/turn/faq/")!).font(.caption)
                Button(model.networkCheckRunning ? "Checking this network…" : "Check this network") { model.inspectNetwork() }.disabled(model.networkCheckRunning)
                if let result = model.networkCheckResult { Text(result).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            card {
                Label("Stay available", systemImage: "moon.zzz").font(.headline)
                Text("Keep FarReach open in the menu bar on both Macs. End viewing pauses capture; Resume uses the existing paired connection. The sharing Mac stays awake while available, but its screen saver and display sleep can still run.").font(.callout).foregroundStyle(.secondary)
                Toggle("Open FarReach when I log in", isOn: Binding(get: { model.loginEnabled }, set: { model.setLoginEnabled($0) }))
                Text("Login startup does not provide FileVault or pre-login access. For a locked desktop, use Wake Display and type the Mac password only when its current lock screen is visible. FarReach never saves that password.").font(.caption).foregroundStyle(.secondary)
            }
            card {
                Label("Check this Mac", systemImage: "checkmark.shield").font(.headline)
                Text("After granting both permissions, test live screen capture and one keyboard event locally. Keep the test window active; no other computer is needed.").font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Test Direct Internet locally") { model.runLocalDiagnostic(internet: true) }
                    Button("Test local network") { model.runLocalDiagnostic() }
                    Button("Check lock-screen capture") { model.runLocalDiagnostic(internet: true, lockProbe: true) }
                }.disabled(model.diagnosticRunning || model.isHosting || model.isConnecting || model.isViewing)
                Text("The Direct Internet check uses two local connection engines and contacts no discovery server. It verifies the app pipeline, not reachability from another network.").font(.caption).foregroundStyle(.secondary)
                if let result = model.diagnosticResult { Text(result).font(.caption).textSelection(.enabled) }
                if let preview = model.lockProbeImage {
                    Image(nsImage: preview).resizable().scaledToFit().frame(maxHeight: 300)
                    Text("Preview stays in memory only. A captured image does not prove password entry works.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Video quality adapts to the connection, and interrupted paired sessions can reconnect automatically. Both Macs need the same version. First pairing uses a private invitation and response. FileVault, pre-login access, closed-lid sleep, and direct connectivity through every network are not guaranteed.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private var viewer: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "desktopcomputer")
                Text(model.remoteName).font(.headline)
                Spacer()
                Text("Click to control · ⇧⌘. to end viewing").font(.caption).foregroundStyle(.secondary)
                Button("Wake Display") { model.wakeRemoteDisplay() }.buttonStyle(.bordered)
                Button("End viewing") { model.endViewing() }.buttonStyle(.bordered)
            }.padding(12).background(.bar)
            HStack(spacing: 12) {
                Toggle("Full keyboard control", isOn: Binding(get: { model.fullKeyboardControl }, set: { model.setFullKeyboardControl($0) }))
                    .toggleStyle(.checkbox).fixedSize()
                Text(model.keyboardControlDescription).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if (model.fullKeyboardControl && !model.controlAllowed) || model.keyboardCaptureStatus == .permissionRequired || model.keyboardCaptureStatus == .unavailable {
                    Button("Keyboard permissions") { model.requestControlPermission() }.controlSize(.small)
                }
                if model.keyboardCaptureStatus == .capturing {
                    Button("Release keyboard") { model.desktop.releaseKeyboardFocus() }.controlSize(.small)
                }
            }.padding(.horizontal, 12).padding(.vertical, 8).background(.bar)
            ZStack {
                RemoteSurface(model: model).frame(maxWidth: .infinity, maxHeight: .infinity).background(.black)
                if model.streamUnavailable {
                    VStack(spacing: 14) {
                        Image(systemName: "display.trianglebadge.exclamationmark").font(.largeTitle)
                        Text("Waiting for the current screen").font(.headline)
                        Text("Use Wake Display. Keyboard input is disabled until a fresh image is available.").font(.callout)
                        Button("Wake Display / Retry") { model.wakeRemoteDisplay() }
                    }.padding(28).foregroundStyle(.white).background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
                }
            }
        }
    }
    private var metrics: some View {
        HStack(spacing: 10) {
            Text("\(model.fps) fps")
            Text(String(format: "%.1f Mbps", model.mbps))
            if let ping = model.pingMS { Text(String(format: "%.0f ms RTT", ping)) }
            if let stats = model.transportStatistics {
                Text(String(format: "%.0f ms queue", stats.queueMS))
                Text("\(stats.packetsLost) missing · \(stats.packetsRepaired) late-repaired")
            }
            Button("Export diagnostics") { model.exportDiagnostics() }.buttonStyle(.link)
        }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 16, content: content)
            .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.07)))
    }
    private func permissionBadge(_ title: String, granted: Bool) -> some View {
        Label(title, systemImage: granted ? "checkmark.circle.fill" : "circle.dashed")
            .font(.caption).foregroundStyle(granted ? Color.green : .secondary)
    }
    private func setupRow<Action: View>(_ number: String, _ title: String, _ detail: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(number).font(.headline).foregroundStyle(accent).frame(width: 28, height: 28).background(accent.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 6) { Text(title).font(.headline); Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            Spacer(minLength: 8)
            action().controlSize(.small)
        }
    }
    private func icon(_ page: AppModel.Page) -> String {
        switch page { case .share: return "display"; case .connect: return "arrow.up.right.video"; case .devices: return "desktopcomputer.and.macbook"; case .setup: return "slider.horizontal.3" }
    }
}
