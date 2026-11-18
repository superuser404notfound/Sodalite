import Foundation

/// Turns what somebody typed into the scheme and port candidates discovery races, and adopts the
/// one redirect a probe may teach it. Jellyfin and Seerr used to keep a copy each, and the copies
/// drifted: the redirect fix of audit NETWORK-4 landed in one of them only (audit NET-R201,
/// NET-207). The backends now differ only in their default ports.
nonisolated enum DiscoveryCandidates {
    struct Ports: Sendable {
        /// Tried for a bare host or IP, in this order.
        let defaults: [(scheme: String, port: Int)]
        /// Added after a typed `scheme://host` that names no port and no path.
        let typedScheme: [String: Int]

        static let jellyfin = Ports(
            defaults: [("https", 8920), ("http", 8096)],
            typedScheme: ["https": 8920, "http": 8096]
        )
        /// Seerr serves plain http on 5055 out of the box and has no https default.
        static let seerr = Ports(
            defaults: [("http", 5055), ("https", 5055)],
            typedScheme: ["http": 5055]
        )
    }

    static func build(from input: String, ports: Ports) -> [URL] {
        var cleaned = input.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if cleaned.hasPrefix("https://") || cleaned.hasPrefix("http://") {
            guard let url = URL(string: cleaned) else { return [] }
            var candidates = [url]
            // Set via URLComponents, NOT string append (":8920" on https://host/jellyfin glues onto
            // the path); a base path means a reverse proxy, where default ports don't apply.
            let scheme = cleaned.hasPrefix("https://") ? "https" : "http"
            if url.port == nil, url.path.isEmpty || url.path == "/",
               let port = ports.typedScheme[scheme],
               var components = URLComponents(url: url, resolvingAgainstBaseURL: true) {
                components.port = port
                if let withPort = components.url {
                    candidates.append(withPort)
                }
            }
            return candidates
        }

        let isIPAddress = cleaned.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}"#, options: .regularExpression) != nil
        let hasPort = cleaned.contains(":")
        // Port variants only without a path (":8920" on "host/jellyfin" glues onto the path).
        let defaultPorts = cleaned.contains("/") ? [] : ports.defaults.compactMap {
            URL(string: "\($0.scheme)://\(cleaned):\($0.port)")
        }
        let standardPorts = ["https", "http"].compactMap { URL(string: "\($0)://\(cleaned)") }

        if hasPort {
            // Appending another port yields host:port:port, which URL(string:) rejects.
            return standardPorts
        }
        // An IP is a LAN box on its own port first; a name is likely a reverse proxy first.
        return isIPAddress ? defaultPorts + standardPorts : standardPorts + defaultPorts
    }

    /// The address to store for a candidate, given where its probe actually ended up.
    ///
    /// A server entered as `http://` behind a proxy that upgrades to https passed discovery on the
    /// redirect, but the pre-redirect URL was stored, and every later request lost its credentials
    /// on that hop (audit NETWORK-4). Only that one hop is adopted: same host, http to https, and the
    /// endpoint still at the end of the path. Any other redirect keeps the address that was typed.
    static func upgradedBaseURL(candidate: URL, finalURL: URL?, endpointPath: String) -> URL {
        guard let finalURL,
              candidate.scheme?.lowercased() == "http", finalURL.scheme?.lowercased() == "https",
              let candidateHost = candidate.host(percentEncoded: false)?.lowercased(),
              candidateHost == finalURL.host(percentEncoded: false)?.lowercased(),
              var components = URLComponents(url: finalURL, resolvingAgainstBaseURL: false),
              components.path.hasSuffix(endpointPath)
        else { return candidate }
        components.path = String(components.path.dropLast(endpointPath.count))
        components.query = nil
        components.fragment = nil
        return components.url ?? candidate
    }
}
