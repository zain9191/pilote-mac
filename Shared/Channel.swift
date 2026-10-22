import Foundation
import Network

/// Une connexion WebSocket sur Network.framework, utilisée des deux côtés :
/// l'agent pour chaque iPhone connecté, l'app pour joindre le Mac.
///
/// Network.framework plutôt qu'URLSession : un seul code pour le client et le
/// serveur, et App Transport Security ne s'applique pas, donc `ws://` vers
/// l'adresse Tailscale du Mac reste possible en secours de `wss://`.
final class Channel {
    enum Event {
        case ready
        case text(Data)
        case binary(Data)
        /// La connexion attend un réseau (Mac injoignable). Le message décrit la cause.
        case waiting(String)
        case closed(Error?)
    }

    /// Appelé sur `queue`.
    var onEvent: ((Event) -> Void)?

    /// La connexion a cessé de répondre aux pings.
    struct Silent: LocalizedError {
        var errorDescription: String? { "l'autre côté ne répond plus" }
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var finished = false
    /// Pings envoyés sans pong reçu.
    private var unansweredPings = 0

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Options WebSocket communes au client et au serveur.
    static func webSocketOptions() -> NWProtocolWebSocket.Options {
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = 16 * 1024 * 1024
        return options
    }

    /// Connexion sortante vers `url` (`ws://` ou `wss://`).
    static func client(url: URL, queue: DispatchQueue) -> Channel {
        let parameters: NWParameters = url.scheme == "wss" ? .tls : .tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions(), at: 0)
        return Channel(connection: NWConnection(to: .url(url), using: parameters), queue: queue)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onEvent?(.ready)
            case .waiting(let error):
                self.onEvent?(.waiting(error.localizedDescription))
            case .failed(let error):
                self.finish(error)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    /// Envoie un ping toutes les `interval` secondes et ferme la connexion après
    /// deux pings restés sans réponse. Sans ça, un pair disparu sans fermer
    /// (réseau coupé) laisserait la connexion ouverte indéfiniment.
    func keepAlive(every interval: TimeInterval) {
        queue.asyncAfter(deadline: .now() + interval) { [weak self] in
            guard let self, !self.finished else { return }
            if self.unansweredPings >= 2 {
                self.finish(Silent())
                return
            }
            self.unansweredPings += 1
            let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
            metadata.setPongHandler(self.queue) { [weak self] error in
                if error == nil {
                    self?.unansweredPings = 0
                }
            }
            let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
            self.connection.send(content: Data(), contentContext: context, isComplete: true,
                                 completion: .contentProcessed { _ in })
            self.keepAlive(every: interval)
        }
    }

    func send(text: Data, completion: ((Error?) -> Void)? = nil) {
        send(text, opcode: .text, completion: completion)
    }

    func send(binary: Data, completion: ((Error?) -> Void)? = nil) {
        send(binary, opcode: .binary, completion: completion)
    }

    /// Ferme proprement (trame de fermeture puis annulation). Sans effet si déjà fermé.
    func close() {
        // `[self]` explicite : la fermeture garde le canal en vie jusqu'à l'envoi.
        queue.async { [self] in
            guard !self.finished else { return }
            let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
            metadata.closeCode = .protocolCode(.normalClosure)
            let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
            self.connection.send(content: nil, contentContext: context, isComplete: true,
                                 completion: .contentProcessed { [weak self] _ in self?.connection.cancel() })
            // Filet : si la trame ne part pas, on coupe quand même.
            self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connection.cancel() }
        }
    }

    private func send(_ data: Data, opcode: NWProtocolWebSocket.Opcode, completion: ((Error?) -> Void)?) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true,
                        completion: .contentProcessed { error in completion?(error) })
    }

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let error {
                self.finish(error)
                return
            }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            switch metadata?.opcode {
            case .text?:
                self.onEvent?(.text(data ?? Data()))
            case .binary?:
                self.onEvent?(.binary(data ?? Data()))
            case .close?:
                self.connection.cancel()
                return
            default:
                break
            }
            // Fin de flux sans trame de fermeture.
            if context?.isFinal == true {
                self.finish(nil)
                return
            }
            if !self.finished {
                self.receive()
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        onEvent?(.closed(error))
    }
}
