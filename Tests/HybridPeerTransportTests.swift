import XCTest
import Network
@testable import Forma

/// Pure parameter/endpoint checks; no browser or connection is started.
final class HybridPeerTransportTests: XCTestCase {
    func testExistingPeerInitializerKeepsPeerToPeerDisabled() {
        let peer = HybridTransfer.Peer(id: "legacy", displayName: "Legacy Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1234))
        XCTAssertFalse(peer.includePeerToPeer)
        XCTAssertFalse(HybridTransfer.networkParameters(for: peer).includePeerToPeer)
    }
    func testExplicitPeerPolicyProducesIndependentUnscopedParameters() {
        let peer = HybridTransfer.Peer(id: "direct", displayName: "Nearby Mac", endpoint: .hostPort(host: "127.0.0.1", port: 1234), includePeerToPeer: true)
        let first = HybridTransfer.networkParameters(for: peer), second = HybridTransfer.networkParameters(for: peer)
        XCTAssertTrue(first.includePeerToPeer); XCTAssertTrue(second.includePeerToPeer)
        XCTAssertNil(first.requiredInterface)
        XCTAssertEqual(first.requiredInterfaceType, .other)
        first.includePeerToPeer = false
        XCTAssertTrue(second.includePeerToPeer)
        XCTAssertTrue(peer.includePeerToPeer)
    }
    func testWiFiAndNearbyBrowserPoliciesRemainDistinct() {
        let wifi = HybridTransferBrowser.networkParameters(peerToPeer: false)
        XCTAssertFalse(wifi.includePeerToPeer); XCTAssertEqual(wifi.requiredInterfaceType, .wifi)
        let nearby = HybridTransferBrowser.networkParameters(peerToPeer: true)
        XCTAssertTrue(nearby.includePeerToPeer); XCTAssertNil(nearby.requiredInterface)
        XCTAssertEqual(nearby.requiredInterfaceType, .other)
    }
    func testNearbyBonjourPeerKeepsServiceAndLeavesInterfaceSelectionToNetwork() throws {
        let endpoint = NWEndpoint.service(name: "Forma fixture", type: HybridTransfer.serviceType, domain: "local.", interface: nil)
        let peer = try XCTUnwrap(HybridTransferBrowser.peer(endpoint: endpoint, interfaces: [], peerToPeer: true))
        XCTAssertTrue(peer.includePeerToPeer)
        XCTAssertEqual(peer.displayName, "Forma fixture")
        guard case .service(let name, let type, let domain, let interface) = peer.endpoint else { return XCTFail("Nearby discovery must retain a Bonjour endpoint") }
        XCTAssertEqual(name, "Forma fixture"); XCTAssertEqual(type, HybridTransfer.serviceType); XCTAssertEqual(domain, "local.")
        XCTAssertNil(interface)
        XCTAssertEqual(peer.id, HybridTransferBrowser.peer(endpoint: endpoint, interfaces: [], peerToPeer: true)?.id)
    }
    func testWiFiPeerNeedsWiFiInterfaceAndDiscoveryRejectsDirectEndpoint() {
        let endpoint = NWEndpoint.service(name: "Forma fixture", type: HybridTransfer.serviceType, domain: "local.", interface: nil)
        XCTAssertNil(HybridTransferBrowser.peer(endpoint: endpoint, interfaces: [], peerToPeer: false))
        XCTAssertNil(HybridTransferBrowser.peer(endpoint: .hostPort(host: "127.0.0.1", port: 1234), interfaces: [], peerToPeer: true))
    }
}
