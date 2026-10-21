import Foundation

/// Transforme ce que l'utilisateur tape en adresse WebSocket complète.
///
/// - `mac.tail1234.ts.net`          → `wss://mac.tail1234.ts.net:443/` (via `tailscale serve`)
/// - `https://mac.tail1234.ts.net`  → `wss://mac.tail1234.ts.net:443/`
/// - `100.101.102.103`              → `ws://100.101.102.103:8770/` (agent écouté en direct)
/// - `ws://…`, `wss://…`            → conservés, port complété si absent
enum Address {
    static func url(from input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let lower = text.lowercased()
        if lower.hasPrefix("https://") {
            text = "wss://" + text.dropFirst("https://".count)
        } else if lower.hasPrefix("http://") {
            text = "ws://" + text.dropFirst("http://".count)
        } else if !lower.hasPrefix("ws://") && !lower.hasPrefix("wss://") {
            // Un autre schéma (ftp://…) n'a pas de sens ici.
            guard !text.contains("://") else { return nil }
            let host = text.split(whereSeparator: { $0 == ":" || $0 == "/" }).first.map(String.init) ?? text
            text = (isIPv4(host) ? "ws://" : "wss://") + text
        }

        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              let host = components.host, !host.isEmpty
        else { return nil }

        components.scheme = scheme
        if components.port == nil {
            components.port = scheme == "wss" ? 443 : Int(PiloteProtocol.defaultPort)
        }
        if components.path.isEmpty {
            components.path = "/"
        }
        return components.url
    }

    static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            guard let value = Int(part), String(value) == part else { return false }
            return (0...255).contains(value)
        }
    }
}

/// Comparaison de jetons en temps constant : la durée ne dit rien de la position
/// du premier caractère faux.
enum TokenCheck {
    static func equal(_ candidate: String, _ expected: String) -> Bool {
        let a = Array(candidate.utf8)
        let b = Array(expected.utf8)
        var difference: UInt8 = a.count == b.count ? 0 : 1
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            difference |= x ^ y
        }
        return difference == 0
    }
}
