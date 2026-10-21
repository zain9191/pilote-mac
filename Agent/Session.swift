import CoreGraphics
import Foundation
import Network

/// Un iPhone connecté. Tout l'état vit sur `server.queue` ; le travail lent
/// (état du Mac, commandes) part sur d'autres files. `@unchecked Sendable` :
/// la file série tient lieu de verrou.
final class Session: @unchecked Sendable {
    private(set) var authenticated = false

    private let channel: Channel
    private unowned let server: Server
    private var queue: DispatchQueue { server.queue }
    /// État du Mac : file série, pour que le calcul de charge processeur
    /// compare toujours deux mesures successives.
    private let statusQueue = DispatchQueue(label: "pilote.session.status")
    private let statusReader = StatusReader()

    private var streamer: ScreenStreamer?
    /// Images envoyées et pas encore affichées par l'iPhone.
    private var framesInFlight = 0
    /// Dernière image en attente : les intermédiaires sont abandonnées.
    private var pendingFrame: Data?
    private static let maxFramesInFlight = 2

    private let decoder = JSONDecoder()

    init(connection: NWConnection, server: Server) {
        self.server = server
        self.channel = Channel(connection: connection, queue: server.queue)
    }

    func start() {
        channel.onEvent = { [weak self] event in
            self?.handle(event)
        }
        channel.start()
        // Un iPhone parti sans fermer (réseau perdu) est détecté et la session
        // libérée, capture d'écran comprise.
        channel.keepAlive(every: 10)
        // Sans jeton dans les 5 s, on raccroche.
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !self.authenticated else { return }
            self.channel.close()
        }
    }

    func close() {
        channel.close()
    }

    // MARK: Réception

    private func handle(_ event: Channel.Event) {
        switch event {
        case .text(let data):
            guard let request = try? decoder.decode(Request.self, from: data) else {
                if !authenticated { channel.close() }
                return
            }
            handle(request)
        case .binary:
            // L'iPhone n'envoie jamais de binaire.
            if !authenticated { channel.close() }
        case .closed:
            stopScreen()
            server.sessionEnded(self)
        case .ready, .waiting:
            break
        }
    }

    private func handle(_ request: Request) {
        guard authenticated else {
            authenticate(request)
            return
        }

        switch request.type {
        case Kind.status:
            statusQueue.async { [weak self] in
                guard let self else { return }
                var response = Response()
                response.status = self.statusReader.read()
                self.reply(to: request, response)
            }

        case Kind.apps:
            work(request) {
                var response = Response()
                response.apps = Actions.runningApps()
                return response
            }

        case Kind.action:
            guard let action = request.name.flatMap(ActionName.init(rawValue:)) else {
                fail(request, "Action inconnue")
                return
            }
            work(request) {
                try Actions.perform(action)
                return nil
            }

        case Kind.volume:
            guard let level = request.level else {
                fail(request, "Volume manquant")
                return
            }
            work(request) {
                try Actions.setVolume(level)
                return nil
            }

        case Kind.openURL:
            work(request) {
                try Actions.open(url: request.url ?? "")
                return nil
            }

        case Kind.openApp:
            work(request) {
                try Actions.open(app: request.name ?? "")
                return nil
            }

        case Kind.custom:
            guard let action = request.name.flatMap(server.vault.action(id:)) else {
                fail(request, "Action personnalisée inconnue")
                return
            }
            work(request) {
                var response = Response()
                response.message = try Actions.run(action)
                return response
            }

        case Kind.screenStart:
            startScreen(request)

        case Kind.screenStop:
            stopScreen()
            reply(to: request, Response())

        case Kind.screenAck:
            framesInFlight = max(0, framesInFlight - 1)
            sendPendingFrame()

        case Kind.click, Kind.scroll, Kind.text, Kind.key:
            input(request)

        default:
            fail(request, "Requête inconnue : \(request.type)")
        }
    }

    private func authenticate(_ request: Request) {
        guard request.type == Kind.auth else {
            channel.close()
            return
        }
        if let refusal = server.authenticate(request.token ?? "") {
            fail(request, refusal)
            // Laisser partir le refus avant de raccrocher.
            queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.channel.close() }
            return
        }
        authenticated = true
        server.sessionChanged()

        var response = Response()
        response.hello = Hello(
            name: StatusReader.computerName(),
            protocolVersion: PiloteProtocol.version,
            actions: (server.vault.config.actions ?? []).map {
                CustomAction(id: $0.id, label: $0.label, confirm: $0.confirm ?? false)
            }
        )
        reply(to: request, response)
    }

    // MARK: Clavier et souris

    private func input(_ request: Request) {
        DispatchQueue.main.async { [weak self] in
            do {
                try Input.requireAccess()
                switch request.type {
                case Kind.click:
                    let point = Input.point(x: request.x ?? 0.5, y: request.y ?? 0.5)
                    Input.click(at: point, right: request.button == "right", count: request.count ?? 1)
                case Kind.scroll:
                    Input.scroll(dx: request.dx ?? 0, dy: request.dy ?? 0)
                case Kind.text:
                    Input.type(request.text ?? "")
                default:
                    try Input.press(request.key ?? "", modifiers: request.modifiers ?? [])
                }
                self?.reply(to: request, Response())
            } catch {
                self?.fail(request, error.localizedDescription)
            }
        }
    }

    // MARK: Écran

    private func startScreen(_ request: Request) {
        stopScreen()
        guard CGPreflightScreenCaptureAccess() else {
            fail(request, "Autorisation « Enregistrement de l'écran » manquante sur le Mac")
            return
        }
        let streamer = ScreenStreamer(maxWidth: request.maxWidth, fps: request.fps, quality: request.quality)
        // Chaque rappel vérifie qu'il s'agit toujours de la capture en cours : une
        // capture remplacée ne doit plus rien envoyer.
        streamer.onFrame = { [weak self, weak streamer] jpeg in
            self?.queue.async {
                guard let self, let streamer, self.streamer === streamer else { return }
                self.enqueue(frame: jpeg)
            }
        }
        streamer.onStop = { [weak self, weak streamer] error in
            self?.queue.async {
                guard let self, let streamer, self.streamer === streamer else { return }
                self.stopScreen()
                var notice = Response("notice")
                notice.error = "Capture de l'écran arrêtée : \(error.localizedDescription)"
                self.send(notice)
            }
        }
        self.streamer = streamer

        Task { [weak self] in
            do {
                let info = try await streamer.start()
                self?.queue.async {
                    guard let self, self.streamer === streamer else { return }
                    var response = Response()
                    response.screen = info
                    self.reply(to: request, response)
                }
            } catch is CancellationError {
                // Arrêtée pendant le démarrage : une autre requête a pris la main.
            } catch {
                self?.queue.async {
                    guard let self, self.streamer === streamer else { return }
                    self.streamer = nil
                    self.fail(request, "Capture impossible : \(error.localizedDescription)")
                }
            }
        }
    }

    private func stopScreen() {
        streamer?.stop()
        streamer = nil
        framesInFlight = 0
        pendingFrame = nil
    }

    /// Au plus deux images en vol : sur un lien lent, l'iPhone reçoit la plus
    /// récente au lieu d'accumuler du retard.
    private func enqueue(frame: Data) {
        pendingFrame = frame
        sendPendingFrame()
    }

    private func sendPendingFrame() {
        guard framesInFlight < Self.maxFramesInFlight, let frame = pendingFrame else { return }
        pendingFrame = nil
        framesInFlight += 1
        channel.send(binary: frame)
    }

    // MARK: Réponses

    /// Exécute `body` hors du fil de la session et répond. `body` renvoie `nil`
    /// pour une réponse « ok » sans contenu.
    private func work(_ request: Request, _ body: @escaping () throws -> Response?) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let response = try body() ?? Response()
                self?.reply(to: request, response)
            } catch {
                self?.fail(request, error.localizedDescription)
            }
        }
    }

    private func reply(to request: Request, _ response: Response) {
        guard request.id != nil else { return }
        var response = response
        response.id = request.id
        response.ok = true
        send(response)
    }

    private func fail(_ request: Request, _ message: String) {
        var response = Response(request.id == nil ? "notice" : "result")
        response.id = request.id
        response.ok = false
        response.error = message
        send(response)
    }

    private func send(_ response: Response) {
        // Encodeur neuf à chaque envoi : `send` est appelé depuis plusieurs files.
        guard let data = try? JSONEncoder().encode(response) else { return }
        channel.send(text: data)
    }
}
