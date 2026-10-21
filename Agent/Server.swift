import Foundation
import Network

/// Serveur WebSocket de l'agent.
///
/// Écoute par défaut sur 127.0.0.1 : seul `tailscale serve`, sur le Mac lui-même,
/// peut le joindre, et c'est lui qui apporte HTTPS et la restriction au tailnet.
/// Le jeton s'ajoute par-dessus.
final class Server: @unchecked Sendable {
    let queue = DispatchQueue(label: "pilote.server")
    let vault: Vault

    /// Nombre d'iPhone authentifiés. Appelé sur le fil principal.
    var onClients: (@MainActor (Int) -> Void)?
    /// Texte d'état et drapeau d'erreur. Appelé sur le fil principal.
    var onState: (@MainActor (String, Bool) -> Void)?

    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var failures: [Date] = []

    private static let maxFailures = 5
    private static let lockout: TimeInterval = 15 * 60

    init(vault: Vault) {
        self.vault = vault
    }

    func start() {
        let config = vault.config
        let host = config.listen ?? "127.0.0.1"
        let port = config.port ?? PiloteProtocol.defaultPort
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            report("Port invalide : \(port)", error: true)
            return
        }

        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(Channel.webSocketOptions(), at: 0)
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: endpointPort)
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            report("Écoute impossible : \(error.localizedDescription)", error: true)
            return
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                self?.report("À l'écoute sur \(host):\(port)", error: false)
            case .failed(let error):
                // Typiquement : l'adresse d'écoute n'existe pas encore (IP
                // Tailscale à l'ouverture de session) ou le port est pris.
                self?.report("Écoute impossible sur \(host):\(port) : \(error.localizedDescription) — nouvel essai dans 10 s",
                             error: true)
                listener?.cancel()
                self?.queue.asyncAfter(deadline: .now() + 10) { self?.start() }
            case .waiting(let error):
                self?.report("En attente du réseau : \(error.localizedDescription)", error: true)
            default:
                break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    /// Coupe toutes les connexions (après un changement de jeton).
    func disconnectAll() {
        queue.async {
            for session in self.sessions.values {
                session.close()
            }
        }
    }

    // MARK: Appelé par les sessions, sur `queue`

    /// `nil` si le jeton est accepté, sinon le motif du refus.
    ///
    /// Après 5 échecs en 15 min, tout est refusé, bon jeton compris : derrière
    /// `tailscale serve` toutes les connexions viennent de 127.0.0.1, le
    /// verrouillage ne peut donc pas être fait par adresse.
    func authenticate(_ token: String) -> String? {
        let now = Date()
        failures.removeAll { now.timeIntervalSince($0) > Self.lockout }
        if failures.count >= Self.maxFailures, let oldest = failures.first {
            let minutes = Int((Self.lockout - now.timeIntervalSince(oldest)) / 60) + 1
            return "Trop d'échecs : réessaie dans \(minutes) min"
        }
        if vault.check(token) {
            failures.removeAll()
            return nil
        }
        failures.append(now)
        return "Jeton refusé"
    }

    func sessionChanged() {
        let count = sessions.values.filter(\.authenticated).count
        let callback = onClients
        Task { @MainActor in callback?(count) }
    }

    func sessionEnded(_ session: Session) {
        sessions.removeValue(forKey: ObjectIdentifier(session))
        sessionChanged()
    }

    // MARK: Interne

    private func accept(_ connection: NWConnection) {
        let session = Session(connection: connection, server: self)
        sessions[ObjectIdentifier(session)] = session
        session.start()
    }

    private func report(_ text: String, error: Bool) {
        let callback = onState
        Task { @MainActor in callback?(text, error) }
    }
}
