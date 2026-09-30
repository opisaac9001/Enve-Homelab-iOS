import Foundation
import Network
import Observation

/// Service types discovered with Bonjour (mDNS). Only services that advertise themselves are found; nothing is scanned or probed.
enum DiscoverableService: String, CaseIterable, Sendable {
    case ssh = "_ssh._tcp"
    case homeAssistant = "_home-assistant._tcp"
    case http = "_http._tcp"
    case https = "_https._tcp"

    var title: String {
        switch self {
        case .ssh: "SSH"
        case .homeAssistant: "Home Assistant"
        case .http: "Web (HTTP)"
        case .https: "Web (HTTPS)"
        }
    }

    var systemImage: String {
        switch self {
        case .ssh: "terminal"
        case .homeAssistant: "house"
        case .http, .https: "globe"
        }
    }

    var suggestion: String {
        switch self {
        case .ssh: "Add as SSH host"
        case .homeAssistant: "Add Home Assistant"
        case .http, .https: "Add service check"
        }
    }
}

struct DiscoveredService: Sendable, Hashable, Identifiable {
    var name: String
    var type: DiscoverableService
    var host: String
    var port: Int

    var id: String { "\(type.rawValue)|\(name)" }

    var url: URL? {
        let scheme = type == .https ? "https" : "http"
        let bracketed = host.contains(":") ? "[\(host)]" : host
        return URL(string: "\(scheme)://\(bracketed):\(port)")
    }

    /// Strips interface scopes (`fe80::1%en0`) and the trailing dot from mDNS host names.
    static func cleanHost(_ raw: String) -> String {
        var host = raw
        if let percent = host.firstIndex(of: "%") { host = String(host[..<percent]) }
        if host.hasSuffix(".") { host.removeLast() }
        return host
    }
}

@MainActor
@Observable
final class LocalDiscovery {
    private(set) var services: [DiscoveredService] = []
    private(set) var isRunning = false
    private(set) var failure: String?
    @ObservationIgnored private var browsers: [NWBrowser] = []
    @ObservationIgnored private var resolving: Set<String> = []

    func start() {
        stop()
        services = []
        failure = nil
        isRunning = true
        for type in DiscoverableService.allCases {
            let browser = NWBrowser(for: .bonjour(type: type.rawValue, domain: "local."), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let names = results.compactMap { result -> (String, NWEndpoint)? in
                    if case .service(let name, _, _, _) = result.endpoint { return (name, result.endpoint) }
                    return nil
                }
                Task { @MainActor in
                    for (name, endpoint) in names { self?.resolve(name: name, type: type, endpoint: endpoint) }
                }
            }
            browser.stateUpdateHandler = { [weak self] state in
                switch state {
                case .failed(let error):
                    Task { @MainActor in self?.failure = "Discovery failed: \(error.localizedDescription). Allow Local Network access in Settings › Privacy." }
                // A denied Local Network permission leaves the browser waiting rather than failed.
                case .waiting(let error):
                    Task { @MainActor in self?.failure = "Discovery is waiting: \(error.localizedDescription). Check that this device is on Wi-Fi and that Local Network access is allowed in Settings › Privacy." }
                case .ready:
                    Task { @MainActor in self?.failure = nil }
                default:
                    break
                }
            }
            browser.start(queue: .main)
            browsers.append(browser)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers = []
        isRunning = false
    }

    /// Resolves a service to a host and port by opening, then immediately closing, a TCP connection.
    private func resolve(name: String, type: DiscoverableService, endpoint: NWEndpoint) {
        let key = "\(type.rawValue)|\(name)"
        guard !resolving.contains(key), !services.contains(where: { $0.id == key }) else { return }
        resolving.insert(key)
        let connection = NWConnection(to: endpoint, using: .tcp)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if case .hostPort(let host, let port)? = connection.currentPath?.remoteEndpoint {
                    let hostText = DiscoveredService.cleanHost("\(host)")
                    let found = DiscoveredService(name: name, type: type, host: hostText, port: Int(port.rawValue))
                    Task { @MainActor in
                        self?.services.append(found)
                        self?.services.sort { ($0.type.rawValue, $0.name) < ($1.type.rawValue, $1.name) }
                    }
                }
                connection.cancel()
            case .failed, .cancelled:
                Task { @MainActor in _ = self?.resolving.remove(key) }
            default:
                break
            }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { connection.cancel() }
    }
}
