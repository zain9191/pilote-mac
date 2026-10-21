import Foundation
import Security

/// Configuration de l'agent, lue dans `config.json`.
struct AgentConfig: Codable {
    /// Adresse d'écoute. Par défaut la boucle locale : `tailscale serve` relaie.
    var listen: String?
    var port: UInt16?
    var actions: [ConfiguredAction]?

    static let example = AgentConfig(
        listen: "127.0.0.1",
        port: PiloteProtocol.defaultPort,
        actions: [
            ConfiguredAction(id: "eveil", label: "Empêcher la veille 1 h",
                             command: ["/usr/bin/caffeinate", "-d", "-t", "3600"], confirm: false),
        ]
    )
}

/// Action personnalisée : une commande précise, jamais un shell libre envoyé
/// depuis le téléphone. Le chemin de l'exécutable doit être absolu.
struct ConfiguredAction: Codable {
    var id: String
    var label: String
    var command: [String]
    var confirm: Bool?
}

/// Jeton et configuration, rangés dans `~/Library/Application Support/PiloteMac`
/// (dossier en 700, fichiers en 600). Accessible depuis n'importe quel fil.
final class Vault: @unchecked Sendable {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/PiloteMac", isDirectory: true)
    static let tokenURL = directory.appendingPathComponent("token")
    static let configURL = directory.appendingPathComponent("config.json")

    private let lock = NSLock()
    private var currentToken: String
    private var currentConfig: AgentConfig
    private var currentError: String?

    init() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.directory.path)

        if let data = try? Data(contentsOf: Self.tokenURL),
           let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           token.count >= 32 {
            currentToken = token
        } else {
            currentToken = Self.newToken()
            Self.writePrivate(Data(currentToken.utf8), to: Self.tokenURL)
        }

        if !fm.fileExists(atPath: Self.configURL.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(AgentConfig.example) {
                Self.writePrivate(data, to: Self.configURL)
            }
        }
        currentConfig = AgentConfig()
        reloadConfig()
    }

    var token: String {
        lock.withLock { currentToken }
    }

    var config: AgentConfig {
        lock.withLock { currentConfig }
    }

    /// Dernière erreur de lecture de `config.json`, ou `nil`.
    var configError: String? {
        lock.withLock { currentError }
    }

    func check(_ candidate: String) -> Bool {
        TokenCheck.equal(candidate, token)
    }

    /// Remplace le jeton. L'ancien cesse d'être valable immédiatement.
    @discardableResult
    func regenerateToken() -> String {
        let token = Self.newToken()
        Self.writePrivate(Data(token.utf8), to: Self.tokenURL)
        lock.withLock { currentToken = token }
        return token
    }

    /// Relit `config.json`. En cas d'erreur, l'ancienne configuration reste en place.
    func reloadConfig() {
        do {
            let data = try Data(contentsOf: Self.configURL)
            let config = try JSONDecoder().decode(AgentConfig.self, from: data)
            try Self.validate(config)
            lock.withLock {
                currentConfig = config
                currentError = nil
            }
        } catch {
            lock.withLock { currentError = "config.json : \(error.localizedDescription)" }
        }
    }

    func action(id: String) -> ConfiguredAction? {
        config.actions?.first { $0.id == id }
    }

    private static func validate(_ config: AgentConfig) throws {
        var seen = Set<String>()
        for action in config.actions ?? [] {
            guard let executable = action.command.first, executable.hasPrefix("/") else {
                throw AgentError("action « \(action.id) » : la commande doit commencer par un chemin absolu")
            }
            guard seen.insert(action.id).inserted else {
                throw AgentError("action « \(action.id) » en double")
            }
        }
    }

    /// 32 octets aléatoires en base64url : 43 caractères.
    private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes a échoué")
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func writePrivate(_ data: Data, to url: URL) {
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

struct AgentError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
