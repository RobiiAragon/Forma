import Foundation
import Network

/// Parses a direct Wi-Fi destination without resolving DNS or opening a socket.
struct HybridConnectionAddress: Equatable, Sendable {
    let host: String
    let port: UInt16
    private init(host: String, port: UInt16) { self.host = host; self.port = port }

    enum AddressError: LocalizedError {
        case host, port
        var errorDescription: String? {
            switch self {
            case .host: return "Introduce una IP o un nombre del Mac como mi-mac.local, sin http://, rutas ni puerto."
            case .port: return "Introduce el puerto de recepción que muestra Forma Desktop, entre 1 y 65535."
            }
        }
    }
    static func parse(host input: String, port portInput: String) throws -> Self {
        let number = portInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !number.isEmpty, number.utf8.allSatisfy({ (48...57).contains($0) }),
              let port = UInt16(number), port > 0 else { throw AddressError.port }
        var host = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !host.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              !host.contains("/"), !host.contains("\\"), !host.contains("@"), !host.contains("?"), !host.contains("#") else { throw AddressError.host }
        let bracketed = host.hasPrefix("[") || host.hasSuffix("]")
        if bracketed {
            guard host.hasPrefix("["), host.hasSuffix("]") else { throw AddressError.host }
            host = String(host.dropFirst().dropLast())
        }
        if host.contains(":") {
            guard let address = IPv6Address(host) else { throw AddressError.host }
            return Self(host: address.debugDescription.lowercased(), port: port)
        }
        guard !bracketed, !host.contains("["), !host.contains("]"), !host.contains("%") else { throw AddressError.host }
        if host.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) {
            guard host.split(separator: ".", omittingEmptySubsequences: false).count == 4,
                  let address = IPv4Address(host) else { throw AddressError.host }
            return Self(host: address.debugDescription, port: port)
        }
        if host.hasSuffix(".") { host.removeLast() }
        // DNS wire-format bounds, rather than a limit on captures or transfers.
        guard !host.isEmpty, host.utf8.count <= 253 else { throw AddressError.host }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard !label.isEmpty, label.utf8.count <= 63,
                  label.first != "-", label.last != "-",
                  label.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { throw AddressError.host }
        }
        return Self(host: host.lowercased(), port: port)
    }
    private var authority: String { (host.contains(":") ? "[\(host)]" : host) + ":\(port)" }
    var id: String { "manual-wifi:" + authority }
    var displayName: String { "Mac por Wi-Fi · " + authority }
    var endpoint: NWEndpoint {
        // parse() already established the nonzero UInt16 representation.
        .hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
    }
}
