import AppKit
import Combine
import RemoteCore
import Sparkle

/// Recheck session state at invocation time, including sessions begun after scheduling.
@MainActor final class UpdateInstallGate {
    var isBusy: () -> Bool = { true }
    var onPendingChanged: ((Bool) -> Void)?
    private var pending: (() -> Void)?
    private var revision: UInt64 = 0

    func enqueue(_ handler: @escaping () -> Void) {
        revision &+= 1
        pending = handler
        onPendingChanged?(true)
        resumeIfIdle()
    }

    func cancel() {
        revision &+= 1; pending = nil; onPendingChanged?(false)
    }

    func resumeIfIdle() {
        guard pending != nil, !isBusy() else { return }
        let token = revision
        DispatchQueue.main.async { [weak self] in
            guard let self, self.revision == token, !self.isBusy(), let handler = self.pending else { return }
            self.pending = nil; self.revision &+= 1; self.onPendingChanged?(false)
            handler()
        }
    }
}

@MainActor final class UpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyInstalls = false
    @Published private(set) var waitingForIdle = false
    @Published private(set) var status = "Updates are not available in this build yet."
    let configuration: UpdateConfiguration
    private var controller: SPUStandardUpdaterController?
    private var subscriptions = Set<AnyCancellable>()
    private var attached = false
    private let installGate = UpdateInstallGate()

    override init() {
        configuration = UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:])
        super.init()
        if configuration == .invalid { status = "Update configuration is invalid. Install a corrected release to enable updates." }
    }

    func attach(to model: AppModel) {
        guard !attached else { return }
        attached = true
        installGate.isBusy = { [weak model] in model?.preventsUpdateRestart ?? true }
        installGate.onPendingChanged = { [weak self] pending in self?.waitingForIdle = pending }
        model.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.installGate.resumeIfIdle()
        }.store(in: &subscriptions)
        guard configuration == .configured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyInstalls)
        do {
            try updater.start()
            status = "Updates replace this installed app. Your saved pairing and settings are kept."
        } catch {
            status = "Updates could not start: \(error.localizedDescription)"
            canCheckForUpdates = false
        }
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func setAutomaticallyChecks(_ enabled: Bool) { controller?.updater.automaticallyChecksForUpdates = enabled }
    func setAutomaticallyInstalls(_ enabled: Bool) { controller?.updater.automaticallyDownloadsUpdates = enabled }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard installGate.isBusy() else { return false }
        installGate.enqueue(installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installGate.enqueue(immediateInstallHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installGate.cancel()
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }
}
