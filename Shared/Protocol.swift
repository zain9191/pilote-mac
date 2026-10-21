import Foundation

/// Protocole entre l'app iPhone et l'agent du Mac.
///
/// Une seule connexion WebSocket. L'iPhone envoie des `Request` en JSON (texte),
/// l'agent répond par des `Response` en JSON (texte) et pousse les images de
/// l'écran en JPEG (binaire). Toute requête qui porte un `id` reçoit une réponse
/// avec le même `id` ; sans `id`, l'agent ne répond qu'en cas d'erreur.
enum PiloteProtocol {
    static let version = 1
    static let defaultPort: UInt16 = 8770
}

/// Types de requêtes.
enum Kind {
    static let auth = "auth"                 // token
    static let status = "status"
    static let apps = "apps"                 // apps ouvertes
    static let action = "action"             // name: ActionName
    static let volume = "volume"             // level 0...100
    static let openURL = "openURL"           // url (http/https)
    static let openApp = "openApp"           // name
    static let custom = "custom"             // name: id d'une action personnalisée
    static let screenStart = "screen.start"  // maxWidth, fps, quality
    static let screenStop = "screen.stop"
    static let screenAck = "screen.ack"      // image reçue et affichée
    static let click = "pointer.click"       // x, y, button, count
    static let scroll = "pointer.scroll"     // dx, dy
    static let text = "key.text"             // text
    static let key = "key.press"             // key, modifiers
}

/// Actions rapides sans paramètre.
enum ActionName: String, CaseIterable, Codable {
    case lock, sleep, displaySleep, playPause, next, previous, mute, unmute
}

/// Touches spéciales, indépendantes de la disposition du clavier.
enum SpecialKey: String, CaseIterable {
    case escape, tab, `return`, delete, forwardDelete, space
    case left, right, up, down, home, end, pageUp, pageDown
    case f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12
}

/// Touches de modification.
enum Modifier: String, CaseIterable, Codable {
    case cmd, option, control, shift

    var symbol: String {
        switch self {
        case .cmd: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        case .shift: return "⇧"
        }
    }
}

/// Requête de l'iPhone. Structure plate : chaque type n'utilise que ses champs,
/// les autres restent `nil` et ne sont pas encodés.
struct Request: Codable, Equatable {
    var id: Int?
    var type: String
    var token: String?
    var name: String?
    var level: Int?
    var url: String?
    /// Position sur l'image, de 0 à 1 (coin haut gauche = 0, 0).
    var x: Double?
    var y: Double?
    /// Défilement, en points du Mac.
    var dx: Double?
    var dy: Double?
    /// "left" ou "right".
    var button: String?
    /// 1 = clic simple, 2 = double clic.
    var count: Int?
    var text: String?
    var key: String?
    var modifiers: [String]?
    var maxWidth: Int?
    var fps: Int?
    var quality: Double?

    init(_ type: String) {
        self.type = type
    }
}

/// Réponse de l'agent.
struct Response: Codable, Equatable {
    var id: Int?
    /// "result" pour une réponse à une requête, "notice" pour une alerte spontanée.
    var type: String
    var ok: Bool?
    var error: String?
    var message: String?
    var hello: Hello?
    var status: MacStatus?
    var apps: [String]?
    var screen: ScreenInfo?

    init(_ type: String = "result") {
        self.type = type
    }
}

/// Présentation de l'agent, renvoyée quand le jeton est accepté.
struct Hello: Codable, Equatable {
    var name: String
    var protocolVersion: Int
    var actions: [CustomAction]
}

/// Action personnalisée telle que l'iPhone la voit : jamais la commande elle-même.
struct CustomAction: Codable, Equatable, Identifiable {
    var id: String
    var label: String
    var confirm: Bool
}

/// Taille en pixels des images de l'écran envoyées.
struct ScreenInfo: Codable, Equatable {
    var width: Int
    var height: Int
}

struct MacStatus: Codable, Equatable {
    var name: String
    var osVersion: String
    var model: String?
    /// Secondes depuis le démarrage.
    var uptime: Double?
    /// Charge processeur depuis la mesure précédente, de 0 à 1.
    var cpu: Double?
    var memoryUsed: Int64?
    var memoryTotal: Int64?
    var diskAvailable: Int64?
    var diskTotal: Int64?
    var battery: Battery?
    /// "nominal", "fair", "serious" ou "critical".
    var thermal: String?
    var frontApp: String?
    var volume: Int?
    var muted: Bool?
    var permissions: Permissions
}

struct Battery: Codable, Equatable {
    var level: Int
    var charging: Bool
    var onAC: Bool
    var minutesLeft: Int?
}

/// Autorisations macOS accordées à l'agent.
struct Permissions: Codable, Equatable {
    /// Accessibilité : injecter clavier et souris, verrouiller, touches multimédia.
    var input: Bool
    /// Enregistrement de l'écran : bureau à distance.
    var screen: Bool
}
