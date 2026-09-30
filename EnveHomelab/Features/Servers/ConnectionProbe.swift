import Foundation

enum ConnectionProbeOutcome: Sendable {
    case identified(ConnectionProbe.Service, URL)
    case unrecognized(URL)
    case certificate(URL, CertificateSummary)
    case redirected(URL)
    case failed(String)
}

enum ConnectionProbe {
    enum Service: Hashable, Sendable {
        case unraid
        case integration(IntegrationKind)
    }

    static func detect(address: String, pinnedFingerprint: String? = nil) async -> ConnectionProbeOutcome {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred: URL
        switch EndpointURLParser.parse(text) {
        case .success(let url): preferred = url
        case .failure(let error): return .failed(error.localizedDescription)
        }

        var candidates = [preferred]
        if !text.contains("://"), var alternate = URLComponents(url: preferred, resolvingAgainstBaseURL: false) {
            alternate.scheme = "http"
            if let url = alternate.url { candidates.append(url) }
        }

        var certificate: (URL, CertificateSummary)?
        for (index, candidate) in candidates.enumerated() {
            let result = await inspect(candidate, pinnedFingerprint: pinnedFingerprint)
            if Task.isCancelled { return .failed("Connection check cancelled.") }
            switch result {
            case .identified(let service): return .identified(service, candidate)
            case .unrecognized: return .unrecognized(candidate)
            case .certificate(let summary):
                if index < candidates.count - 1 {
                    certificate = (candidate, summary)
                    continue
                }
                return .certificate(candidate, summary)
            case .redirected(let target): return .redirected(target)
            case .failed(let error):
                if index == candidates.count - 1 || !mayTryHTTP(after: error) {
                    if let certificate { return .certificate(certificate.0, certificate.1) }
                    return .failed([error.errorDescription, error.recoverySuggestion].compactMap { $0 }.joined(separator: " "))
                }
            }
        }
        return .failed("The server couldn't be reached.")
    }

    static func isTailnetAddress(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        if host.hasSuffix(".ts.net") { return true }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        return octets.count == 4 && octets[0] == 100 && (64...127).contains(octets[1])
            && octets.dropFirst(2).allSatisfy { (0...255).contains($0) }
    }

    private enum Inspection {
        case identified(Service)
        case unrecognized
        case certificate(CertificateSummary)
        case redirected(URL)
        case failed(NetworkError)
    }

    private static func inspect(_ base: URL, pinnedFingerprint: String?) async -> Inspection {
        let home = await fetch(base, path: "", pinnedFingerprint: pinnedFingerprint)
        switch home {
        case .failed(.untrustedCertificate(let certificate)), .failed(.certificateChanged(let certificate, _)):
            return .certificate(certificate)
        case .failed(let error):
            return .failed(error)
        case .response(let response):
            if (300..<400).contains(response.status), let location = response.location,
               let target = URL(string: location, relativeTo: base)?.absoluteURL {
                return .redirected(target)
            }
            if let service = serviceInPage(response.data) { return .identified(service) }
        }

        let paths = ["status", "System/Info/Public", "identity", "api/status", "api/v1/claim", "api/info/version", "api2/json/version"]
        return await withTaskGroup(of: (String, ProbeResponse?).self) { group in
            for path in paths {
                group.addTask {
                    guard case .response(let response) = await fetch(base, path: path, pinnedFingerprint: pinnedFingerprint) else {
                        return (path, nil)
                    }
                    return (path, response)
                }
            }
            var found: Service?
            for await (path, response) in group {
                if let response, let service = service(at: path, response: response) {
                    found = service
                    group.cancelAll()
                    break
                }
            }
            return found.map(Inspection.identified) ?? .unrecognized
        }
    }

    private struct ProbeResponse: Sendable {
        let status: Int
        let data: Data
        let location: String?
    }

    private enum FetchResult: Sendable {
        case response(ProbeResponse)
        case failed(NetworkError)
    }

    private static func fetch(_ base: URL, path: String, pinnedFingerprint: String?) async -> FetchResult {
        var url = RESTClient(baseURL: base, pinnedFingerprint: pinnedFingerprint, timeout: 4).url(for: path)
        for hop in 0...3 {
            do {
                let client = RESTClient(baseURL: url, pinnedFingerprint: pinnedFingerprint, timeout: 4)
                let (data, http) = try await client.raw(.get(""))
                let response = ProbeResponse(status: http.statusCode, data: Data(data.prefix(16384)), location: http.value(forHTTPHeaderField: "Location"))
                if path.isEmpty, hop < 3, (300..<400).contains(response.status), let location = response.location,
                   let target = URL(string: location, relativeTo: url)?.absoluteURL,
                   target.host() == base.host(), target.scheme == base.scheme, target.port == base.port {
                    url = target
                    continue
                }
                return .response(response)
            } catch {
                return .failed(NetworkError.from(error))
            }
        }
        return .failed(.unexpectedResponse("Too many redirects."))
    }

    private static func serviceInPage(_ data: Data) -> Service? {
        guard let html = String(data: data, encoding: .utf8) else { return nil }
        if html.range(of: "/webGui/", options: .caseInsensitive) != nil { return .unraid }
        guard let range = html.range(of: "<title[^>]*>[^<]*</title>", options: [.regularExpression, .caseInsensitive]) else { return nil }
        let title = html[range].replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if title.contains("unraid") { return .unraid }
        let names: [(IntegrationKind, String)] = [
            (.proxmox, "proxmox"), (.truenas, "truenas"), (.portainer, "portainer"),
            (.pihole, "pi hole"), (.adguard, "adguard"), (.unifi, "unifi"),
            (.homeassistant, "home assistant"), (.jellyfin, "jellyfin"), (.plex, "plex"), (.emby, "emby"),
            (.radarr, "radarr"), (.sonarr, "sonarr"), (.lidarr, "lidarr"), (.prowlarr, "prowlarr"),
            (.qbittorrent, "qbittorrent"), (.sabnzbd, "sabnzbd"), (.transmission, "transmission"),
            (.nzbget, "nzbget"), (.deluge, "deluge"), (.bazarr, "bazarr"), (.nzbhydra, "nzbhydra"),
            (.jackett, "jackett"), (.tdarr, "tdarr"), (.maintainerr, "maintainerr"), (.tautulli, "tautulli"),
            (.komga, "komga"), (.kavita, "kavita"), (.audiobookshelf, "audiobookshelf"),
            (.immich, "immich"), (.wizarr, "wizarr"), (.glances, "glances"), (.synology, "synology"),
            (.dockhand, "dockhand"), (.komodo, "komodo"), (.coolify, "coolify"), (.arcane, "arcane"),
            (.beszel, "beszel"), (.technitium, "technitium"), (.gluetun, "gluetun"),
            (.tracearr, "tracearr"), (.dispatcharr, "dispatcharr"), (.seerr, "seerr")
        ]
        for (kind, name) in names where title.contains(name) {
            return .integration(kind)
        }
        if title == "qui" || title.hasPrefix("qui ") { return .integration(.qui) }
        return nil
    }

    private static func service(at path: String, response: ProbeResponse) -> Service? {
        guard (200..<300).contains(response.status) else { return nil }
        let json = (try? JSONSerialization.jsonObject(with: response.data)) as? [String: Any]
        switch path {
        case "status":
            if (json?["app"] as? String)?.lowercased() == "audiobookshelf" { return .integration(.audiobookshelf) }
        case "System/Info/Public":
            let product = (json?["ProductName"] as? String)?.lowercased()
            if product == "jellyfin" { return .integration(.jellyfin) }
            if product == "emby" { return .integration(.emby) }
            let version = (json?["Version"] as? String)?.split(separator: ".").first
            if version == "10" { return .integration(.jellyfin) }
            if version == "4" { return .integration(.emby) }
        case "identity":
            if let container = json?["MediaContainer"] as? [String: Any], container["machineIdentifier"] is String {
                return .integration(.plex)
            }
            if let body = String(data: response.data, encoding: .utf8)?.lowercased(),
               body.contains("<mediacontainer"), body.contains("machineidentifier=") { return .integration(.plex) }
        case "api/status":
            if json?["Version"] is String, json?["InstanceID"] is String { return .integration(.portainer) }
        case "api/v1/claim":
            if json?["isClaimed"] is Bool { return .integration(.komga) }
        case "api/info/version":
            if let version = json?["version"] as? [String: Any], version["core"] != nil, version["ftl"] != nil {
                return .integration(.pihole)
            }
        case "api2/json/version":
            if let data = json?["data"] as? [String: Any], data["version"] is String, data["release"] != nil {
                return .integration(.proxmox)
            }
        default: break
        }
        return nil
    }

    private static func mayTryHTTP(after error: NetworkError) -> Bool {
        switch error {
        case .unreachable, .timedOut, .tlsFailure: true
        default: false
        }
    }
}
