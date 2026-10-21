import XCTest

final class AddressTests: XCTestCase {
    func testTailscaleNameUsesSecureWebSocketOn443() {
        XCTAssertEqual(Address.url(from: "mac.tail1234.ts.net")?.absoluteString,
                       "wss://mac.tail1234.ts.net:443/")
    }

    func testHTTPSBecomesWSS() {
        XCTAssertEqual(Address.url(from: " https://mac.tail1234.ts.net ")?.absoluteString,
                       "wss://mac.tail1234.ts.net:443/")
    }

    func testHTTPBecomesWS() {
        XCTAssertEqual(Address.url(from: "http://mac.local:9000")?.absoluteString,
                       "ws://mac.local:9000/")
    }

    func testBareIPv4GoesDirectToAgentPort() {
        XCTAssertEqual(Address.url(from: "100.101.102.103")?.absoluteString,
                       "ws://100.101.102.103:8770/")
    }

    func testIPv4WithPathStaysDirect() {
        XCTAssertEqual(Address.url(from: "100.101.102.103/ws")?.absoluteString,
                       "ws://100.101.102.103:8770/ws")
    }

    func testExplicitPortIsKept() {
        XCTAssertEqual(Address.url(from: "100.101.102.103:9999")?.absoluteString,
                       "ws://100.101.102.103:9999/")
        XCTAssertEqual(Address.url(from: "wss://mac.tail1234.ts.net:8444")?.absoluteString,
                       "wss://mac.tail1234.ts.net:8444/")
    }

    func testSchemeIsCaseInsensitive() {
        XCTAssertEqual(Address.url(from: "HTTPS://Mac.ts.net")?.scheme, "wss")
    }

    func testRejectsEmptyAndForeignSchemes() {
        XCTAssertNil(Address.url(from: ""))
        XCTAssertNil(Address.url(from: "   "))
        XCTAssertNil(Address.url(from: "ftp://mac.ts.net"))
        XCTAssertNil(Address.url(from: "wss://"))
    }

    func testIPv4Detection() {
        XCTAssertTrue(Address.isIPv4("100.64.0.1"))
        XCTAssertFalse(Address.isIPv4("256.1.1.1"))
        XCTAssertFalse(Address.isIPv4("1.2.3"))
        XCTAssertFalse(Address.isIPv4("01.2.3.4"))
        XCTAssertFalse(Address.isIPv4("mac.ts.net"))
    }
}

final class TokenCheckTests: XCTestCase {
    func testEqualTokens() {
        XCTAssertTrue(TokenCheck.equal("abc_DEF-123", "abc_DEF-123"))
    }

    func testDifferentTokens() {
        XCTAssertFalse(TokenCheck.equal("abc_DEF-124", "abc_DEF-123"))
        XCTAssertFalse(TokenCheck.equal("abc", "abc_DEF-123"))
        XCTAssertFalse(TokenCheck.equal("abc_DEF-123x", "abc_DEF-123"))
        XCTAssertFalse(TokenCheck.equal("", "abc"))
    }

    /// Un préfixe suivi d'octets nuls ne doit pas passer pour le jeton.
    func testPaddingDoesNotMatch() {
        XCTAssertFalse(TokenCheck.equal("ab\u{0}", "ab"))
    }
}

final class ProtocolTests: XCTestCase {
    func testRequestOmitsUnusedFields() throws {
        var request = Request(Kind.click)
        request.id = 7
        request.x = 0.25
        request.y = 0.75
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(request), encoding: .utf8))
        XCTAssertFalse(json.contains("token"))
        XCTAssertFalse(json.contains("null"))
        let decoded = try JSONDecoder().decode(Request.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, request)
    }

    func testResponseRoundTrip() throws {
        var response = Response()
        response.id = 3
        response.ok = true
        response.hello = Hello(name: "MacBook", protocolVersion: PiloteProtocol.version,
                               actions: [CustomAction(id: "a", label: "A", confirm: true)])
        response.status = MacStatus(
            name: "MacBook", osVersion: "Version 26.0", model: "Mac15,3", uptime: 3600, cpu: 0.12,
            memoryUsed: 8_000_000_000, memoryTotal: 16_000_000_000,
            diskAvailable: 100_000_000_000, diskTotal: 500_000_000_000,
            battery: Battery(level: 80, charging: false, onAC: false, minutesLeft: 240),
            thermal: "nominal", frontApp: "Safari", volume: 40, muted: false,
            permissions: Permissions(input: true, screen: false))
        let data = try JSONEncoder().encode(response)
        XCTAssertEqual(try JSONDecoder().decode(Response.self, from: data), response)
    }

    /// L'agent et l'app s'accordent sur ces noms : les changer casse le protocole.
    func testWireNamesAreStable() {
        XCTAssertEqual(ActionName.displaySleep.rawValue, "displaySleep")
        XCTAssertEqual(SpecialKey.return.rawValue, "return")
        XCTAssertEqual(SpecialKey.pageDown.rawValue, "pageDown")
        XCTAssertEqual(Modifier.cmd.rawValue, "cmd")
        XCTAssertEqual(Kind.screenStart, "screen.start")
    }
}
