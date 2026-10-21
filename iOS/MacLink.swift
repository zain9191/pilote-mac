import Foundation
import Observation
import UIKit

/// Lien avec l'agent du Mac. Tout se passe sur le fil principal : la connexion
/// y délivre ses événements.
@MainActor
@Observable
final class MacLink {
    enum Phase: Equatable {
        case offline
        case connecting
        case online
        case failed(String)
    }

    enum LinkError: LocalizedError {
        case offline
        case timeout
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .offline: return "Mac non connecté"
            case .timeout: return "Le Mac ne répond pas"
            case .refused(let message): return message
            }
        }
    }

    /// Qualité du bureau à distance.
    enum Quality: String, CaseIterable, Identifiable {
        case light, standard, sharp

        var id: String { rawValue }

        var label: String {
            switch self {
            case .light: return "Économe"
            case .standard: return "Standard"
            case .sharp: return "Nette"
            }
        }

        fileprivate var parameters: (maxWidth: Int, fps: Int, quality: Double) {
            switch self {
            case .light: return (1280, 8, 0.4)
            case .standard: return (1600, 12, 0.55)
            case .sharp: return (2560, 15, 0.7)
            }
        }
    }

    private(set) var phase: Phase = .offline
    private(set) var hello: Hello?
    private(set) var status: MacStatus?
    private(set) var runningApps: [String] = []
    private(set) var screen: ScreenInfo?
    private(set) var screenError: String?
    /// Dernier message à montrer (erreur d'action, résultat d'une action personnalisée).
    var notice: String?

    /// Image reçue, déjà décodable. Posé par la vue du bureau à distance.
    @ObservationIgnored var onFrame: (@MainActor (UIImage) -> Void)?

    @ObservationIgnored private var channel: Channel?
    @ObservationIgnored private var pending: [Int: CheckedContinuation<Response, Error>] = [:]
    @ObservationIgnored private var nextID = 1
    /// Cause signalée par le réseau pendant la tentative en cours.
    @ObservationIgnored private var waitingReason: String?
    /// Décodage des images hors du fil principal, dans l'ordre d'arrivée.
    @ObservationIgnored private let decodeQueue = DispatchQueue(label: "pilote.decode")
    @ObservationIgnored private var quality: Quality = .standard

    var isOnline: Bool { phase == .online }

    // MARK: Connexion

    func connect() {
        disconnect()
        guard let url = Settings.url, let token = Settings.token, !token.isEmpty else {
            phase = .failed("Renseigne l'adresse du Mac et le jeton dans Réglages")
            return
        }
        phase = .connecting
        waitingReason = nil
        let channel = Channel.client(url: url, queue: .main)
        channel.onEvent = { [weak self, weak channel] event in
            guard let self, let channel, channel === self.channel else { return }
            self.handle(event)
        }
        self.channel = channel
        channel.start()

        // Filet : une connexion qui n'aboutit pas en 12 s est abandonnée.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard let self, self.channel === channel, self.phase == .connecting else { return }
            self.fail(self.waitingReason.map { "Mac injoignable : \($0)" }
                      ?? "Le Mac ne répond pas. Est-il allumé, éveillé et dans le tailnet ?")
        }
    }

    func disconnect() {
        let channel = self.channel
        self.channel = nil
        channel?.close()
        failPending(.offline)
        if phase != .offline {
            phase = .offline
        }
        screen = nil
    }

    func connectIfNeeded() {
        switch phase {
        case .offline, .failed:
            if Settings.isComplete { connect() }
        case .connecting, .online:
            break
        }
    }

    private func handle(_ event: Channel.Event) {
        switch event {
        case .ready:
            channel?.keepAlive(every: 10)
            Task { await authenticate() }
        case .text(let data):
            receive(data)
        case .binary(let data):
            decodeQueue.async { [weak self] in
                let image = UIImage(data: data)?.preparingForDisplay()
                Task { @MainActor in
                    guard let self else { return }
                    if let image {
                        self.onFrame?(image)
                    }
                    // Accusé de réception : l'agent n'envoie la suite qu'à ce rythme.
                    self.send(Request(Kind.screenAck))
                }
            }
        case .waiting(let reason):
            // Network réessaie seul (Tailscale qui se reconnecte au retour au
            // premier plan, par exemple) ; le délai de 12 s tranchera.
            waitingReason = reason
        case .closed(let error):
            fail(error.map { "Connexion perdue : \($0.localizedDescription)" } ?? "Connexion fermée par le Mac")
        }
    }

    private func authenticate() async {
        var request = Request(Kind.auth)
        request.token = Settings.token
        let attempt = channel
        do {
            let response = try await call(request, allowOffline: true)
            guard let hello = response.hello else {
                fail("Réponse inattendue du Mac")
                return
            }
            self.hello = hello
            phase = .online
            // L'onglet Écran relance lui-même la capture quand le lien revient.
            await refresh()
        } catch {
            // Si la connexion a déjà échoué ailleurs, son motif est le bon.
            guard channel === attempt, attempt != nil else { return }
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        let channel = self.channel
        self.channel = nil
        channel?.close()
        failPending(.offline)
        screen = nil
        phase = .failed(message)
    }

    // MARK: Requêtes

    /// Envoie une requête et attend sa réponse. Lève une erreur si l'agent refuse.
    @discardableResult
    func call(_ request: Request, timeout: Double = 8, allowOffline: Bool = false) async throws -> Response {
        guard let channel, allowOffline || phase == .online else { throw LinkError.offline }
        var request = request
        let id = nextID
        nextID += 1
        request.id = id
        let data = try JSONEncoder().encode(request)

        let response: Response = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            channel.send(text: data)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.pending.removeValue(forKey: id)?.resume(throwing: LinkError.timeout)
            }
        }
        guard response.ok == true else {
            throw LinkError.refused(response.error ?? "Refusé par le Mac")
        }
        return response
    }

    /// Envoi sans attente de réponse ; une erreur éventuelle revient en `notice`.
    func send(_ request: Request) {
        guard let channel, phase == .online, let data = try? JSONEncoder().encode(request) else { return }
        channel.send(text: data)
    }

    private func receive(_ data: Data) {
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { return }
        if let id = response.id, let continuation = pending.removeValue(forKey: id) {
            continuation.resume(returning: response)
        } else if response.ok == false || response.type == "notice" {
            notice = response.error ?? response.message
        }
    }

    private func failPending(_ error: LinkError) {
        let waiting = pending
        pending = [:]
        for continuation in waiting.values {
            continuation.resume(throwing: error)
        }
    }

    /// Exécute une requête et range l'erreur éventuelle dans `notice`.
    @discardableResult
    private func run(_ request: Request) async -> Response? {
        do {
            return try await call(request)
        } catch {
            notice = error.localizedDescription
            return nil
        }
    }

    // MARK: Mac

    func refresh() async {
        guard isOnline else { return }
        if let response = try? await call(Request(Kind.status)) {
            status = response.status
        }
    }

    func loadApps() async {
        if let response = await run(Request(Kind.apps)) {
            runningApps = response.apps ?? []
        }
    }

    func perform(_ action: ActionName) async {
        var request = Request(Kind.action)
        request.name = action.rawValue
        if await run(request) != nil, action == .mute || action == .unmute {
            await refresh()
        }
    }

    func setVolume(_ level: Int) async {
        var request = Request(Kind.volume)
        request.level = level
        await run(request)
        await refresh()
    }

    func open(url: String) async {
        var request = Request(Kind.openURL)
        request.url = url.contains("://") ? url : "https://" + url
        await run(request)
    }

    func open(app: String) async {
        var request = Request(Kind.openApp)
        request.name = app
        await run(request)
    }

    func runCustom(_ action: CustomAction) async {
        var request = Request(Kind.custom)
        request.name = action.id
        if let response = await run(request), let message = response.message {
            notice = message
        }
    }

    // MARK: Bureau à distance

    func startScreen(quality: Quality) async {
        self.quality = quality
        await sendScreenStart()
    }

    func stopScreen() {
        screen = nil
        send(Request(Kind.screenStop))
    }

    private func sendScreenStart() async {
        guard isOnline else { return }
        let parameters = quality.parameters
        var request = Request(Kind.screenStart)
        request.maxWidth = parameters.maxWidth
        request.fps = parameters.fps
        request.quality = parameters.quality
        do {
            screen = try await call(request, timeout: 15).screen
            screenError = nil
        } catch {
            screenError = error.localizedDescription
        }
    }

    func click(at point: CGPoint, right: Bool, count: Int) {
        var request = Request(Kind.click)
        request.x = Double(point.x)
        request.y = Double(point.y)
        request.button = right ? "right" : "left"
        request.count = count
        send(request)
    }

    func scroll(dx: Double, dy: Double) {
        var request = Request(Kind.scroll)
        request.dx = dx
        request.dy = dy
        send(request)
    }

    func type(_ text: String) {
        var request = Request(Kind.text)
        request.text = text
        send(request)
    }

    func press(_ key: String, modifiers: [Modifier] = []) {
        var request = Request(Kind.key)
        request.key = key
        request.modifiers = modifiers.map(\.rawValue)
        send(request)
    }
}
