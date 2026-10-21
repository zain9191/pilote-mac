import AppKit
import Observation
import ServiceManagement

/// État affiché dans la barre des menus.
@MainActor
@Observable
final class AgentModel {
    private(set) var listening = "Démarrage…"
    private(set) var listenFailed = false
    private(set) var clients = 0
    private(set) var canControl = false
    private(set) var canCapture = false
    private(set) var actionCount = 0
    private(set) var configError: String?
    private(set) var launchAtLogin = false
    private(set) var notice: String?

    @ObservationIgnored let vault = Vault()
    @ObservationIgnored private var server: Server?
    @ObservationIgnored private var refreshTimer: Timer?

    func start() {
        refresh()
        // Les autorisations se donnent dans Réglages Système : relire
        // régulièrement plutôt que de compter sur l'ouverture du menu.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        let server = Server(vault: vault)
        server.onClients = { [weak self] count in self?.clients = count }
        server.onState = { [weak self] text, failed in
            self?.listening = text
            self?.listenFailed = failed
        }
        server.start()
        self.server = server
    }

    /// Relu à chaque ouverture du menu : les autorisations se donnent ailleurs.
    func refresh() {
        canControl = Input.hasAccess
        canCapture = CGPreflightScreenCaptureAccess()
        actionCount = vault.config.actions?.count ?? 0
        configError = vault.configError
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func requestControl() {
        if !CGRequestPostEventAccess() {
            openPrivacyPane("Privacy_Accessibility")
        }
        refresh()
    }

    func requestCapture() {
        if !CGRequestScreenCaptureAccess() {
            openPrivacyPane("Privacy_ScreenCapture")
        }
        refresh()
    }

    func copyToken() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(vault.token, forType: .string)
        notice = "Jeton copié. Colle-le dans l'app sur l'iPhone."
    }

    /// Nouveau jeton : l'ancien ne vaut plus rien, l'iPhone est déconnecté.
    func regenerateToken() {
        vault.regenerateToken()
        server?.disconnectAll()
        copyToken()
        notice = "Nouveau jeton copié. L'iPhone a été déconnecté."
    }

    func openConfig() {
        NSWorkspace.shared.open(Vault.configURL)
    }

    func reloadConfig() {
        vault.reloadConfig()
        refresh()
        notice = configError == nil
            ? "Configuration relue. Les iPhone voient les actions à la reconnexion."
            : nil
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            notice = nil
        } catch {
            notice = "Lancement automatique : \(error.localizedDescription)"
        }
        refresh()
    }

    private func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
