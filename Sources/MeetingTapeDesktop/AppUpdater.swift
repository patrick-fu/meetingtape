import AppKit
import Sparkle

@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate, NSMenuItemValidation {
    private let model: AppModel
    private lazy var controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    private var started = false
    private var installHandler: (() -> Void)?
    private var invokingInstall = false
    private var updateOnQuitReady = false
    private(set) var installationPending = false

    init(model: AppModel) { self.model = model }

    func updateState() {
        guard !model.updateBusy else { return }
        if !started { started = true; controller.startUpdater() }
        if let installHandler, !invokingInstall {
            invokingInstall = true
            setInstalling(true)
            installHandler()
        }
    }

    @objc func checkForUpdates(_ sender: Any?) { controller.checkForUpdates(sender) }

    @objc func toggleAutomaticUpdates(_ sender: Any?) {
        let enabled = !controller.updater.automaticallyChecksForUpdates
        controller.updater.automaticallyDownloadsUpdates = enabled
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleAutomaticUpdates(_:)) {
            menuItem.state = controller.updater.automaticallyChecksForUpdates ? .on : .off
            return started
        }
        return started && !model.updateBusy && controller.updater.canCheckForUpdates
    }

    private func requireIdle() throws {
        if model.updateBusy {
            throw NSError(domain: "MeetingTape.Update", code: 1, userInfo: [NSLocalizedDescriptionKey: "录音或任务仍在进行，完成后即可更新。"])
        }
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws { try requireIdle() }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws { try requireIdle() }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        installationPending = true
        setInstalling(true)
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        queue(installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        updateOnQuitReady = true
        installationPending = true
        return false
    }

    private func queue(_ handler: @escaping () -> Void) {
        installationPending = true
        installHandler = handler
        invokingInstall = false
        setInstalling(false)
    }

    func cancelTerminationWhileBusy() {
        invokingInstall = false
        setInstalling(false)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        clearInstallation()
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip && state.stage == .installing {
            updateOnQuitReady = false
            clearInstallation()
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        clearInstallation()
    }

    private func setInstalling(_ value: Bool) {
        model.installingUpdate = value
        model.transcription.updating = value
    }

    private func clearInstallation() {
        installHandler = nil
        invokingInstall = false
        installationPending = updateOnQuitReady
        setInstalling(false)
    }
}
