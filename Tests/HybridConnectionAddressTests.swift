import XCTest
import Network
@testable import Forma

/// Parsing and endpoint construction perform no DNS lookup or network request.
final class HybridConnectionAddressTests: XCTestCase {
    func testDNSCanonicalizationGivesStableManualIdentity() throws {
        let first = try HybridConnectionAddress.parse(host: "  MI-MAC.LOCAL. \n", port: " 61275\n")
        let second = try HybridConnectionAddress.parse(host: "mi-mac.local", port: "061275")
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.host, "mi-mac.local")
        XCTAssertEqual(first.port, 61275)
        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(first.displayName, "Mac por Wi-Fi · mi-mac.local:61275")
        XCTAssertNotEqual(first.id, try HybridConnectionAddress.parse(host: "otro-mac.local", port: "61275").id)
        XCTAssertNotEqual(first.id, try HybridConnectionAddress.parse(host: "mi-mac.local", port: "61276").id)
    }
    func testIPv4ProducesDirectHostPortWithoutBonjour() throws {
        let address = try HybridConnectionAddress.parse(host: "192.168.1.147", port: "61275")
        guard case .hostPort(let host, let port) = address.endpoint else { return XCTFail("Manual address must bypass service discovery") }
        XCTAssertEqual(host.debugDescription, "192.168.1.147")
        XCTAssertEqual(port.rawValue, 61275)
        XCTAssertEqual(address.id, "manual-wifi:192.168.1.147:61275")
    }
    func testIPv6CompressedAndBracketedFormsShareIdentity() throws {
        let expanded = try HybridConnectionAddress.parse(host: "[2001:0DB8:0:0:0:0:0:1]", port: "443")
        let compressed = try HybridConnectionAddress.parse(host: "2001:db8::1", port: "443")
        XCTAssertEqual(expanded, compressed)
        XCTAssertEqual(expanded.host, "2001:db8::1")
        XCTAssertEqual(expanded.id, "manual-wifi:[2001:db8::1]:443")
        guard case .hostPort(let host, let port) = expanded.endpoint else { return XCTFail("IPv6 must also use a direct endpoint") }
        XCTAssertEqual(host.debugDescription, "2001:db8::1"); XCTAssertEqual(port.rawValue, 443)
    }
    func testPortUsesActualNonzeroUInt16Range() throws {
        XCTAssertEqual(try HybridConnectionAddress.parse(host: "mac.local", port: "1").port, 1)
        XCTAssertEqual(try HybridConnectionAddress.parse(host: "mac.local", port: "65535").port, 65535)
        for value in ["", " ", "0", "000", "65536", "9999999999999999999", "-1", "+123", "12.5", "0x50", "12 34", "１２３"] {
            XCTAssertThrowsError(try HybridConnectionAddress.parse(host: "mac.local", port: value), value)
        }
    }
    func testRejectsURLPathsCredentialsControlsAndMalformedAddresses() {
        for host in ["", " ", "http://mac.local", "https://192.168.1.147", "mac.local/path", "mac.local\\path", "user@mac.local", "mac.local?x=1", "mac.local#x", "mac.local:61275", "mac local", "mac\nlocal", "mac\0.local", "mac..local", ".mac.local", "-mac.local", "mac-.local", "mac_name.local", "999.168.1.1", "192.168.1", "192.168.1.1.2", "123", "[192.168.1.1]", "[::1", "::1]", "[::1]:61275", "2001:db8:::1", "mac%en0.local"] {
            XCTAssertThrowsError(try HybridConnectionAddress.parse(host: host, port: "1234"), host)
        }
    }
    func testPlainHostnameAndDNSWireBoundsAreAcceptedWithoutResolving() throws {
        XCTAssertEqual(try HybridConnectionAddress.parse(host: "MAC-1", port: "1234").host, "mac-1")
        let label = String(repeating: "a", count: 63)
        XCTAssertNoThrow(try HybridConnectionAddress.parse(host: label + ".local", port: "1234"))
        XCTAssertThrowsError(try HybridConnectionAddress.parse(host: label + "a.local", port: "1234"))
        let longest = [label, label, label, String(repeating: "b", count: 61)].joined(separator: ".")
        XCTAssertEqual(longest.utf8.count, 253)
        XCTAssertNoThrow(try HybridConnectionAddress.parse(host: longest, port: "1234"))
        XCTAssertThrowsError(try HybridConnectionAddress.parse(host: longest + "b", port: "1234"))
    }
}
