import AppKit
import Carbon.HIToolbox
import CoreGraphics

/// Injection de clavier et de souris dans la session du Mac.
///
/// Exige l'autorisation « Accessibilité » (Réglages Système › Confidentialité et
/// sécurité). Sans elle, macOS ignore les événements en silence : d'où
/// `requireAccess()` avant chaque geste. À appeler sur le fil principal : la
/// lecture de la disposition du clavier (TIS) l'exige.
enum Input {
    private static let source = CGEventSource(stateID: .hidSystemState)

    static var hasAccess: Bool {
        CGPreflightPostEventAccess()
    }

    static func requireAccess() throws {
        guard hasAccess else {
            throw AgentError("Autorisation « Accessibilité » manquante sur le Mac")
        }
    }

    // MARK: Souris

    /// Point de l'écran principal correspondant à (x, y) normalisés sur l'image.
    static func point(x: Double, y: Double) -> CGPoint {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let cx = min(max(x, 0), 1)
        let cy = min(max(y, 0), 1)
        return CGPoint(x: bounds.minX + cx * (bounds.width - 1),
                       y: bounds.minY + cy * (bounds.height - 1))
    }

    static func click(at point: CGPoint, right: Bool, count: Int) {
        let button: CGMouseButton = right ? .right : .left
        let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = right ? .rightMouseUp : .leftMouseUp

        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        for clickState in 1...max(1, min(count, 3)) {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: source, mouseType: type,
                                    mouseCursorPosition: point, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Défilement en pixels. `dy` positif fait défiler vers le haut du document.
    static func scroll(dx: Double, dy: Double) {
        let vertical = Int32(max(-2000, min(2000, dy.rounded())))
        let horizontal = Int32(max(-2000, min(2000, dx.rounded())))
        CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                wheel1: vertical, wheel2: horizontal, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    // MARK: Clavier

    /// Tape du texte tel quel, quelle que soit la disposition du clavier du Mac.
    static func type(_ text: String) {
        for character in text {
            if character == "\n" || character == "\r" {
                post(keyCode: CGKeyCode(kVK_Return), flags: [])
                continue
            }
            let units = Array(String(character).utf16)
            for keyDown in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown)
                event?.flags = []
                event?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event?.post(tap: .cghidEventTap)
            }
        }
    }

    /// Appuie sur une touche spéciale (`SpecialKey`) ou un caractère, avec modificateurs.
    static func press(_ key: String, modifiers: [String]) throws {
        var flags: CGEventFlags = []
        for name in modifiers {
            switch Modifier(rawValue: name) {
            case .cmd?: flags.insert(.maskCommand)
            case .option?: flags.insert(.maskAlternate)
            case .control?: flags.insert(.maskControl)
            case .shift?: flags.insert(.maskShift)
            case nil: throw AgentError("Modificateur inconnu : \(name)")
            }
        }

        if let special = SpecialKey(rawValue: key) {
            let (code, extra) = keyCode(for: special)
            post(keyCode: code, flags: flags.union(extra))
        } else if key.count == 1, let code = keyCode(forCharacter: key) {
            post(keyCode: code, flags: flags)
        } else {
            throw AgentError("Touche inconnue sur ce clavier : \(key)")
        }
    }

    /// Touches multimédia (lecture, piste suivante…), codes `NX_KEYTYPE_*` d'IOKit.
    enum MediaKey: Int32 {
        case mute = 7
        case playPause = 16
        case next = 19      // NX_KEYTYPE_FAST, envoyé par la touche F9 des claviers Apple
        case previous = 20  // NX_KEYTYPE_REWIND, touche F7
    }

    static func media(_ key: MediaKey) {
        for keyDown in [true, false] {
            let state: Int32 = keyDown ? 0xA : 0xB
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                timestamp: 0, windowNumber: 0, context: nil,
                subtype: 8, data1: Int((key.rawValue << 16) | (state << 8)), data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Interne

    private static func post(keyCode: CGKeyCode, flags: CGEventFlags) {
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Code de touche et drapeaux que porte un vrai clavier pour cette touche.
    private static func keyCode(for key: SpecialKey) -> (CGKeyCode, CGEventFlags) {
        let arrow: CGEventFlags = [.maskSecondaryFn, .maskNumericPad]
        let function: CGEventFlags = [.maskSecondaryFn]
        let code: Int
        var extra: CGEventFlags = []
        switch key {
        case .escape: code = kVK_Escape
        case .tab: code = kVK_Tab
        case .return: code = kVK_Return
        case .delete: code = kVK_Delete
        case .forwardDelete: code = kVK_ForwardDelete; extra = function
        case .space: code = kVK_Space
        case .left: code = kVK_LeftArrow; extra = arrow
        case .right: code = kVK_RightArrow; extra = arrow
        case .up: code = kVK_UpArrow; extra = arrow
        case .down: code = kVK_DownArrow; extra = arrow
        case .home: code = kVK_Home; extra = function
        case .end: code = kVK_End; extra = function
        case .pageUp: code = kVK_PageUp; extra = function
        case .pageDown: code = kVK_PageDown; extra = function
        case .f1: code = kVK_F1; extra = function
        case .f2: code = kVK_F2; extra = function
        case .f3: code = kVK_F3; extra = function
        case .f4: code = kVK_F4; extra = function
        case .f5: code = kVK_F5; extra = function
        case .f6: code = kVK_F6; extra = function
        case .f7: code = kVK_F7; extra = function
        case .f8: code = kVK_F8; extra = function
        case .f9: code = kVK_F9; extra = function
        case .f10: code = kVK_F10; extra = function
        case .f11: code = kVK_F11; extra = function
        case .f12: code = kVK_F12; extra = function
        }
        return (CGKeyCode(code), extra)
    }

    /// Cherche quelle touche produit ce caractère dans la disposition active.
    ///
    /// Indispensable pour les raccourcis : sur un clavier AZERTY, le code de la
    /// touche « Q » d'un clavier QWERTY produit « A ». Envoyer ⌃⌘ + ce code
    /// déclencherait ⌃⌘A au lieu de verrouiller l'écran.
    static func keyCode(forCharacter character: String) -> CGKeyCode? {
        let wanted = character.lowercased()
        guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data

        return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                return nil
            }
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                            &deadKeyState, characters.count, &length, &characters)
                if status == noErr, length > 0,
                   String(utf16CodeUnits: characters, count: length).lowercased() == wanted {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
    }
}
