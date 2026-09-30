import Foundation

enum IntegrationClient: Sendable {
    case arr(any ArrService)
    case download(any DownloadClientService)
    case media(any MediaServerService)
    case proxmox(any ProxmoxService)
    case portainer(any PortainerService)
    case truenas(any TrueNASService)
    case dnsFilter(any DNSFilterService)
    case unifi(any UniFiService)
    case tailscale(any TailscaleService)
    case cloudflare(any CloudflareService)
    case homeAssistant(any HomeAssistantService)
    case dashboard(any DashboardService)
    case requests(any RequestService)

    var service: any IntegrationService {
        switch self {
        case .arr(let service): service
        case .download(let service): service
        case .media(let service): service
        case .proxmox(let service): service
        case .portainer(let service): service
        case .truenas(let service): service
        case .dnsFilter(let service): service
        case .unifi(let service): service
        case .tailscale(let service): service
        case .cloudflare(let service): service
        case .homeAssistant(let service): service
        case .dashboard(let service): service
        case .requests(let service): service
        }
    }
}

enum IntegrationConnector {
    static func client(for instance: IntegrationInstance, secret: String?) throws -> IntegrationClient {
        let pin = instance.pinnedCertificateSHA256
        let url = instance.url
        func required() throws -> String {
            guard let secret, !secret.isEmpty else { throw NetworkError.missingCredentials }
            return secret
        }
        switch instance.kind {
        case .radarr, .sonarr, .lidarr, .prowlarr:
            return .arr(ArrClient(kind: instance.kind, url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .qbittorrent:
            return .download(QBittorrentClient(url: url, username: instance.identifier, password: secret, pinnedFingerprint: pin))
        case .transmission:
            return .download(TransmissionClient(url: url, username: instance.identifier, password: secret, pinnedFingerprint: pin))
        case .sabnzbd:
            return .download(SABnzbdClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .jellyfin, .emby:
            return .media(MediaBrowserClient(kind: instance.kind, url: url, apiKey: try required(), deviceID: instance.id, pinnedFingerprint: pin))
        case .plex:
            return .media(PlexClient(url: url, token: try required(), clientID: instance.id, pinnedFingerprint: pin))
        case .proxmox:
            guard let tokenID = instance.identifier?.nilIfEmpty else { throw NetworkError.missingCredentials }
            return .proxmox(ProxmoxClient(url: url, tokenID: tokenID, secret: try required(), pinnedFingerprint: pin))
        case .portainer:
            return .portainer(PortainerClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .truenas:
            return .truenas(TrueNASClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .pihole:
            return .dnsFilter(PiholeClient(url: url, password: try required(), pinnedFingerprint: pin))
        case .adguard:
            return .dnsFilter(AdGuardHomeClient(url: url, username: instance.identifier, password: secret, pinnedFingerprint: pin))
        case .unifi:
            return .unifi(UniFiClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .tailscale:
            return .tailscale(TailscaleClient(token: try required()))
        case .cloudflare:
            guard let accountID = instance.identifier?.nilIfEmpty else { throw NetworkError.missingCredentials }
            return .cloudflare(CloudflareClient(accountID: accountID, token: try required()))
        case .homeassistant:
            return .homeAssistant(HomeAssistantClient(url: url, token: try required(), pinnedFingerprint: pin))
        case .nzbget:
            return .download(NZBGetClient(url: url, username: instance.identifier, password: secret, pinnedFingerprint: pin))
        case .deluge:
            return .download(DelugeClient(url: url, password: try required(), pinnedFingerprint: pin))
        case .bazarr:
            return .dashboard(BazarrClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .nzbhydra:
            return .dashboard(NZBHydraClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .jackett:
            return .dashboard(JackettClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .tdarr:
            return .dashboard(TdarrClient(url: url, apiKey: secret, pinnedFingerprint: pin))
        case .maintainerr:
            return .dashboard(MaintainerrClient(url: url, username: instance.identifier, password: secret, pinnedFingerprint: pin))
        case .tautulli:
            return .dashboard(TautulliClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .komga:
            return .dashboard(KomgaClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .kavita:
            return .dashboard(KavitaClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .audiobookshelf:
            return .dashboard(AudiobookshelfClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .immich:
            return .dashboard(ImmichClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .wizarr:
            return .dashboard(WizarrClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .glances:
            return .dashboard(GlancesClient(url: url, username: instance.identifier, password: secret, pinnedFingerprint: pin))
        case .crowdsec:
            return .dashboard(CrowdSecClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .synology:
            guard let account = instance.identifier?.nilIfEmpty else { throw NetworkError.missingCredentials }
            return .dashboard(SynologyClient(url: url, account: account, password: try required(), pinnedFingerprint: pin))
        case .dockhand:
            return .dashboard(DockhandClient(url: url, token: try required(), pinnedFingerprint: pin))
        case .komodo:
            guard let key = instance.identifier?.nilIfEmpty else { throw NetworkError.missingCredentials }
            return .dashboard(KomodoClient(url: url, apiKey: key, apiSecret: try required(), pinnedFingerprint: pin))
        case .coolify:
            return .dashboard(CoolifyClient(url: url, token: try required(), pinnedFingerprint: pin))
        case .arcane:
            return .dashboard(ArcaneClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .beszel:
            guard let email = instance.identifier?.nilIfEmpty else { throw NetworkError.missingCredentials }
            return .dashboard(BeszelClient(url: url, email: email, password: try required(), pinnedFingerprint: pin))
        case .technitium:
            return .dnsFilter(TechnitiumClient(url: url, token: try required(), pinnedFingerprint: pin))
        case .controld:
            return .dashboard(ControlDClient(token: try required()))
        case .nextdns:
            guard let profile = instance.identifier?.nilIfEmpty else { throw NetworkError.missingCredentials }
            return .dashboard(NextDNSClient(profileID: profile, apiKey: try required()))
        case .gluetun:
            return .dashboard(GluetunClient(url: url, username: instance.identifier, secret: secret, pinnedFingerprint: pin))
        case .qui:
            return .download(QuiClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .tracearr:
            return .dashboard(TracearrClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .dispatcharr:
            return .dashboard(DispatcharrClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        case .seerr:
            return .requests(SeerrClient(url: url, apiKey: try required(), pinnedFingerprint: pin))
        }
    }

    static func sample(for kind: IntegrationKind) -> IntegrationClient {
        switch kind {
        case .radarr, .sonarr, .lidarr, .prowlarr: .arr(SampleArrService(kind: kind))
        case .qbittorrent, .transmission, .sabnzbd, .nzbget, .deluge, .qui: .download(SampleDownloadClient(kind: kind))
        case .jellyfin, .emby, .plex: .media(SampleMediaServer(kind: kind))
        case .proxmox: .proxmox(SampleProxmox())
        case .portainer: .portainer(SamplePortainer())
        case .truenas: .truenas(SampleTrueNAS())
        case .pihole, .adguard, .technitium: .dnsFilter(SampleDNSFilter(kind: kind))
        case .unifi: .unifi(SampleUniFi())
        case .tailscale: .tailscale(SampleTailscale())
        case .cloudflare: .cloudflare(SampleCloudflare())
        case .homeassistant: .homeAssistant(SampleHomeAssistant())
        case .bazarr: .dashboard(SampleBazarr())
        case .nzbhydra: .dashboard(SampleNZBHydra())
        case .jackett: .dashboard(SampleJackett())
        case .tdarr: .dashboard(SampleTdarr())
        case .maintainerr: .dashboard(SampleMaintainerr())
        case .tautulli: .dashboard(SampleTautulli())
        case .komga: .dashboard(SampleKomga())
        case .kavita: .dashboard(SampleKavita())
        case .audiobookshelf: .dashboard(SampleAudiobookshelf())
        case .immich: .dashboard(SampleImmich())
        case .wizarr: .dashboard(SampleWizarr())
        case .glances: .dashboard(SampleGlances())
        case .crowdsec: .dashboard(SampleCrowdSec())
        case .synology: .dashboard(SampleSynology())
        case .dockhand: .dashboard(SampleDockhand())
        case .komodo: .dashboard(SampleKomodo())
        case .coolify: .dashboard(SampleCoolify())
        case .arcane: .dashboard(SampleArcane())
        case .beszel: .dashboard(SampleBeszel())
        case .controld: .dashboard(SampleControlD())
        case .nextdns: .dashboard(SampleNextDNS())
        case .gluetun: .dashboard(SampleGluetun())
        case .tracearr: .dashboard(SampleTracearr())
        case .dispatcharr: .dashboard(SampleDispatcharr())
        case .seerr: .requests(SampleSeerr())
        }
    }

    static func sampleInstance(for kind: IntegrationKind) -> IntegrationInstance {
        IntegrationInstance(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", IntegrationKind.allCases.firstIndex(of: kind)!))!,
            kind: kind,
            name: "Sample \(kind.displayName)",
            url: URL(string: kind.exampleAddress)!,
            isSample: true
        )
    }
}
