import Foundation

enum IntegrationCategory: String, CaseIterable, Identifiable, Sendable {
    case infrastructure
    case network
    case smartHome
    case media
    case automation
    case monitoring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .infrastructure: "Infrastructure"
        case .network: "Network & DNS"
        case .smartHome: "Smart Home"
        case .media: "Media"
        case .automation: "Automation & Downloads"
        case .monitoring: "Monitoring & Security"
        }
    }

    var systemImage: String {
        switch self {
        case .infrastructure: "cpu"
        case .network: "network"
        case .smartHome: "house"
        case .media: "play.rectangle.on.rectangle"
        case .automation: "arrow.down.circle"
        case .monitoring: "waveform.path.ecg"
        }
    }
}

/// How an integration authenticates; drives the editor's fields and the Keychain secret.
enum CredentialStyle: Sendable, Equatable {
    /// A single secret: API key or access token.
    case secret(label: String)
    /// An identifier stored in the profile plus a secret, e.g. a Proxmox token ID and its value.
    case identifierAndSecret(identifierLabel: String, identifierPrompt: String, secretLabel: String)
    /// Username and password; `optional` when the service can be configured without authentication.
    case usernamePassword(optional: Bool)
    /// An API key the service only asks for when its authentication is turned on.
    case optionalSecret(label: String)

    /// Whether a restored integration can work before the user re-enters a secret.
    var worksWithoutSecret: Bool {
        switch self {
        case .usernamePassword(let optional): optional
        case .optionalSecret: true
        case .secret, .identifierAndSecret: false
        }
    }
}

enum IntegrationKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case proxmox, truenas, portainer
    case pihole, adguard, unifi, tailscale, cloudflare
    case homeassistant
    case jellyfin, plex, emby
    case radarr, sonarr, lidarr, prowlarr, qbittorrent, sabnzbd, transmission
    case nzbget, deluge, bazarr, nzbhydra, jackett, tdarr, maintainerr
    case tautulli, komga, kavita, audiobookshelf, immich, wizarr
    case glances, crowdsec
    case synology, dockhand, komodo, coolify, arcane, beszel
    case technitium, controld, nextdns, gluetun
    case qui, tracearr, dispatcharr
    case seerr

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .proxmox: "Proxmox VE"
        case .truenas: "TrueNAS"
        case .portainer: "Portainer"
        case .pihole: "Pi-hole"
        case .adguard: "AdGuard Home"
        case .unifi: "UniFi Network"
        case .tailscale: "Tailscale"
        case .cloudflare: "Cloudflare"
        case .homeassistant: "Home Assistant"
        case .jellyfin: "Jellyfin"
        case .plex: "Plex"
        case .emby: "Emby"
        case .radarr: "Radarr"
        case .sonarr: "Sonarr"
        case .lidarr: "Lidarr"
        case .prowlarr: "Prowlarr"
        case .qbittorrent: "qBittorrent"
        case .sabnzbd: "SABnzbd"
        case .transmission: "Transmission"
        case .nzbget: "NZBGet"
        case .deluge: "Deluge"
        case .bazarr: "Bazarr"
        case .nzbhydra: "NZBHydra2"
        case .jackett: "Jackett"
        case .tdarr: "Tdarr"
        case .maintainerr: "Maintainerr"
        case .tautulli: "Tautulli"
        case .komga: "Komga"
        case .kavita: "Kavita"
        case .audiobookshelf: "Audiobookshelf"
        case .immich: "Immich"
        case .wizarr: "Wizarr"
        case .glances: "Glances"
        case .crowdsec: "CrowdSec"
        case .synology: "Synology DSM"
        case .dockhand: "Dockhand"
        case .komodo: "Komodo"
        case .coolify: "Coolify"
        case .arcane: "Arcane"
        case .beszel: "Beszel"
        case .technitium: "Technitium DNS"
        case .controld: "Control D"
        case .nextdns: "NextDNS"
        case .gluetun: "Gluetun"
        case .qui: "qui"
        case .tracearr: "Tracearr"
        case .dispatcharr: "Dispatcharr"
        case .seerr: "Seerr / Overseerr"
        }
    }

    var category: IntegrationCategory {
        switch self {
        case .proxmox, .truenas, .portainer, .synology, .dockhand, .komodo, .coolify, .arcane: .infrastructure
        case .pihole, .adguard, .unifi, .tailscale, .cloudflare, .technitium, .controld, .nextdns, .gluetun: .network
        case .homeassistant: .smartHome
        case .jellyfin, .plex, .emby, .tautulli, .komga, .kavita, .audiobookshelf, .immich, .wizarr, .tracearr, .dispatcharr, .seerr: .media
        case .radarr, .sonarr, .lidarr, .prowlarr, .qbittorrent, .sabnzbd, .transmission,
             .nzbget, .deluge, .bazarr, .nzbhydra, .jackett, .tdarr, .maintainerr, .qui: .automation
        case .glances, .crowdsec, .beszel: .monitoring
        }
    }

    var systemImage: String {
        switch self {
        case .proxmox: "server.rack"
        case .truenas: "externaldrive.connected.to.line.below"
        case .portainer: "shippingbox.circle"
        case .pihole, .adguard: "shield.lefthalf.filled"
        case .unifi: "wifi.router"
        case .tailscale: "point.3.connected.trianglepath.dotted"
        case .cloudflare: "cloud"
        case .homeassistant: "house"
        case .jellyfin, .emby: "play.tv"
        case .plex: "play.circle"
        case .radarr: "film"
        case .sonarr: "tv"
        case .lidarr: "music.note.list"
        case .prowlarr: "magnifyingglass.circle"
        case .qbittorrent, .transmission: "arrow.down.to.line.circle"
        case .sabnzbd, .nzbget: "tray.and.arrow.down"
        case .deluge: "arrow.down.to.line.circle"
        case .bazarr: "captions.bubble"
        case .nzbhydra, .jackett: "magnifyingglass.circle"
        case .tdarr: "film.stack"
        case .maintainerr: "wand.and.rays"
        case .tautulli: "chart.bar.xaxis"
        case .komga, .kavita: "books.vertical"
        case .audiobookshelf: "headphones"
        case .immich: "photo.on.rectangle"
        case .wizarr: "envelope.open"
        case .glances: "gauge.with.dots.needle.67percent"
        case .crowdsec: "shield.lefthalf.filled.badge.checkmark"
        case .synology: "externaldrive.connected.to.line.below"
        case .dockhand, .arcane: "shippingbox"
        case .komodo, .coolify: "square.stack.3d.up"
        case .beszel: "chart.xyaxis.line"
        case .technitium, .controld, .nextdns: "shield.lefthalf.filled"
        case .gluetun: "lock.shield"
        case .qui: "arrow.down.to.line.circle"
        case .tracearr: "person.2.badge.gearshape"
        case .dispatcharr: "dot.radiowaves.left.and.right"
        case .seerr: "tray.and.arrow.down"
        }
    }

    var summary: String {
        switch self {
        case .proxmox: "Nodes, virtual machines, containers and tasks"
        case .truenas: "Pools, disks, datasets, alerts and jobs"
        case .portainer: "Environments, containers, stacks and logs"
        case .pihole, .adguard: "DNS queries, blocking rate and protection"
        case .unifi: "Sites, devices and clients"
        case .tailscale: "Devices, connectivity and key expiry"
        case .cloudflare: "Tunnel health and zones"
        case .homeassistant: "Areas, entities and safe controls"
        case .jellyfin, .emby: "Libraries, sessions and playback control"
        case .plex: "Libraries, sessions and transcodes"
        case .radarr, .sonarr, .lidarr: "Health, download queue and disk space"
        case .prowlarr: "Health and indexer status"
        case .qbittorrent, .transmission: "Torrent queue and transfer rates"
        case .sabnzbd, .nzbget: "Usenet queue and download speed"
        case .deluge: "Torrent queue and transfer rates"
        case .bazarr: "Missing subtitles, providers and tasks"
        case .nzbhydra: "Indexer status and recent grabs"
        case .jackett: "Configured indexers and indexer tests"
        case .tdarr: "Nodes, busy workers and queues"
        case .maintainerr: "Collections, due media and rule runs"
        case .tautulli: "Plex streams, bandwidth and history"
        case .komga, .kavita: "Libraries, scans and unreadable files"
        case .audiobookshelf: "Listening sessions, libraries and scans"
        case .immich: "Storage, statistics and job queues"
        case .wizarr: "Invitations, users and access expiry"
        case .glances: "CPU, memory, disks, sensors and containers"
        case .crowdsec: "Active ban and captcha decisions"
        case .synology: "Virtual machines and Download Station"
        case .dockhand, .arcane: "Containers and stacks across environments"
        case .komodo: "Servers, stacks, deployments and alerts"
        case .coolify: "Applications, services, databases and deployments"
        case .beszel: "Systems, containers and triggered alerts"
        case .technitium: "DNS queries, blocking and timed pauses"
        case .controld: "Profiles, endpoints and timed pauses"
        case .nextdns: "Queries, blocked domains and devices"
        case .gluetun: "VPN tunnel, exit IP and forwarded port"
        case .qui: "Torrents across qBittorrent instances"
        case .tracearr: "Streams, rule violations and servers"
        case .dispatcharr: "Channel activity, source health and errors"
        case .seerr: "Request approvals, routing and reported issues"
        }
    }

    var exampleAddress: String {
        switch self {
        case .proxmox: "https://pve.local:8006"
        case .truenas: "https://truenas.local"
        case .portainer: "https://portainer.local:9443"
        case .pihole: "http://pi.hole"
        case .adguard: "http://adguard.local:3000"
        case .unifi: "https://192.168.1.1"
        case .tailscale: "https://api.tailscale.com"
        case .cloudflare: "https://api.cloudflare.com"
        case .homeassistant: "http://homeassistant.local:8123"
        case .jellyfin: "http://jellyfin.local:8096"
        case .plex: "http://plex.local:32400"
        case .emby: "http://emby.local:8096"
        case .radarr: "http://radarr.local:7878"
        case .sonarr: "http://sonarr.local:8989"
        case .lidarr: "http://lidarr.local:8686"
        case .prowlarr: "http://prowlarr.local:9696"
        case .qbittorrent: "http://qbittorrent.local:8080"
        case .sabnzbd: "http://sabnzbd.local:8080"
        case .transmission: "http://transmission.local:9091"
        case .nzbget: "http://nzbget.local:6789"
        case .deluge: "http://deluge.local:8112"
        case .bazarr: "http://bazarr.local:6767"
        case .nzbhydra: "http://nzbhydra.local:5076"
        case .jackett: "http://jackett.local:9117"
        case .tdarr: "http://tdarr.local:8266"
        case .maintainerr: "http://maintainerr.local:6246"
        case .tautulli: "http://tautulli.local:8181"
        case .komga: "http://komga.local:25600"
        case .kavita: "http://kavita.local:5000"
        case .audiobookshelf: "http://audiobookshelf.local:13378"
        case .immich: "http://immich.local:2283"
        case .wizarr: "http://wizarr.local:5690"
        case .glances: "http://glances.local:61208"
        case .crowdsec: "http://crowdsec.local:8080"
        case .synology: "https://diskstation.local:5001"
        case .dockhand: "http://dockhand.local:3000"
        case .komodo: "https://komodo.local:9120"
        case .coolify: "https://coolify.local:8000"
        case .arcane: "http://arcane.local:3552"
        case .beszel: "http://beszel.local:8090"
        case .technitium: "http://technitium.local:5380"
        case .controld: "https://api.controld.com"
        case .nextdns: "https://api.nextdns.io"
        case .gluetun: "http://gluetun.local:8000"
        case .qui: "http://qui.local:7476"
        case .tracearr: "http://tracearr.local:3000"
        case .dispatcharr: "http://dispatcharr.local:9191"
        case .seerr: "http://seerr.local:5055"
        }
    }

    var credentialStyle: CredentialStyle {
        switch self {
        case .proxmox:
            .identifierAndSecret(identifierLabel: "Token ID", identifierPrompt: "user@pam!homelab", secretLabel: "Token secret")
        case .plex: .secret(label: "Plex token")
        case .pihole: .secret(label: "Password or app password")
        case .adguard: .usernamePassword(optional: true)
        case .homeassistant: .secret(label: "Long-lived access token")
        case .tailscale: .secret(label: "API access token")
        case .cloudflare: .identifierAndSecret(identifierLabel: "Account ID", identifierPrompt: "Cloudflare account ID", secretLabel: "API token")
        case .qbittorrent: .usernamePassword(optional: true)
        case .transmission, .nzbget, .glances, .maintainerr: .usernamePassword(optional: true)
        case .deluge: .secret(label: "Web UI password")
        case .kavita: .secret(label: "Auth key")
        case .crowdsec: .secret(label: "Bouncer API key")
        case .tdarr: .optionalSecret(label: "API key (only if auth is on)")
        case .synology, .beszel: .usernamePassword(optional: false)
        case .gluetun: .usernamePassword(optional: true)
        case .komodo: .identifierAndSecret(identifierLabel: "API key", identifierPrompt: "API key (K_…_K)", secretLabel: "API secret")
        case .nextdns: .identifierAndSecret(identifierLabel: "Profile ID", identifierPrompt: "Profile ID (e.g. abc123)", secretLabel: "API key")
        case .dockhand, .coolify, .technitium, .controld: .secret(label: "API token")
        case .tracearr: .secret(label: "Public API key")
        default: .secret(label: "API key")
        }
    }

    var credentialHelp: String {
        switch self {
        case .proxmox: "Datacenter › Permissions › API Tokens. Monitoring needs PVEAuditor; power actions need VM.PowerMgmt. If privilege separation is on, grant the token its own role."
        case .truenas: "Credentials › Users › API Keys (or the account menu › API Keys). TrueNAS revokes keys sent over plain HTTP, so HTTPS is required."
        case .portainer: "My account › Access tokens. The token acts with your user's permissions."
        case .pihole: "Pi-hole v6: Settings › Web interface / API › App password (recommended), or the web password. Each refresh opens and then closes an API session."
        case .adguard: "The AdGuard Home web username and password, if authentication is configured."
        case .unifi: "UniFi Network › Settings › Control Plane › Integrations › Create API Key. Use the console's local address."
        case .tailscale: "Tailscale admin console › Settings › Keys › Generate access token. The app only reads devices."
        case .cloudflare: "My Profile › API Tokens › Create Token with Account › Cloudflare Tunnel › Read (and optionally Zone › Zone › Read). The account ID is on the account home page."
        case .homeassistant: "Your profile › Security › Long-lived access tokens. Controls act with that user's permissions."
        case .jellyfin: "Dashboard › API Keys."
        case .emby: "Server dashboard › Advanced › API Keys."
        case .plex: "Use the X-Plex-Token of the server owner's account (Plex support: “Finding an authentication token”)."
        case .radarr, .sonarr, .lidarr, .prowlarr: "Settings › General › Security › API Key."
        case .qbittorrent: "Web UI username and password. Leave blank if the server bypasses authentication for this network."
        case .sabnzbd: "Config › General › Security › API Key (the full key, not the NZB key)."
        case .transmission: "RPC username and password, if authentication is enabled."
        case .nzbget: "The ControlUsername and ControlPassword from Settings › Security (or the restricted user). Leave blank if no password is set."
        case .deluge: "The Deluge web UI password (the default is “deluge”)."
        case .bazarr: "Settings › General › Security › API Key."
        case .nzbhydra: "Config › Main › API key. For indexer status, also turn on Config › Auth › “Allow stats access via API”."
        case .jackett: "The API key shown at the top of the Jackett dashboard."
        case .tdarr: "Only needed when Tdarr runs with auth=true: Tools › API Keys."
        case .maintainerr: "Maintainerr has no login of its own. Enter credentials only if a reverse proxy in front of it asks for basic authentication."
        case .tautulli: "Settings › Web Interface › API: enable the API and copy the key."
        case .komga: "Account settings › API keys (Komga 1.20 or later). A key made by an admin can scan libraries."
        case .kavita: "User settings › Auth Keys. An admin's key adds statistics, reading activity and scans."
        case .audiobookshelf: "Settings › API Keys (Audiobookshelf 2.26 or later). Bind the key to an admin user for sessions and scans."
        case .immich: "Account Settings › API Keys. Give it server.about, server.storage, server.statistics, job.read and job.create (or all); job and statistics access also needs an admin."
        case .wizarr: "Settings › API Keys › Create (Wizarr 2025.8.3 or later)."
        case .glances: "Only if Glances runs with --password. The default username is “glances”."
        case .crowdsec: "Create a dedicated key with “cscli bouncers add petty-homelab” on the CrowdSec host. Don't reuse a firewall bouncer's key."
        case .synology: "A DSM account without two-factor sign-in. Create one just for this app with access to Download Station and Virtual Machine Manager only."
        case .dockhand: "Profile › API tokens › Generate token (Dockhand 1.0.25 or later, with authentication turned on)."
        case .komodo: "Settings › API keys. For least privilege, ask an admin to create a Service User with Read and Execute on the resources you want."
        case .coolify: "Security › API Tokens with the Read and Deploy permissions (tick Deploy first, then Read). Turn on the API in Settings › Advanced."
        case .arcane: "Settings › API Keys. A scoped key limited to the environments and actions you need is safest."
        case .beszel: "The email and password of a Beszel user. A read-only user is enough unless you want to pause monitoring."
        case .technitium: "Administration › Sessions › Create Token (or /api/user/createToken). Use a dedicated user with only the permissions you need."
        case .controld: "Control D dashboard › Preferences › API › create a token. A Read token is enough to monitor; pausing profiles needs Write."
        case .nextdns: "The API key from the bottom of my.nextdns.io/account and the profile ID from your profile's address. The key controls your whole NextDNS account."
        case .gluetun: "Only if Gluetun's control server has a role for you. For an API-key role, leave the username blank and enter the key as the password."
        case .qui: "Settings › API Keys › create a key. It has the same access as your qui account."
        case .tracearr: "Settings › General › Public API key (owner account only). Regenerating it in Tracearr disconnects this app."
        case .dispatcharr: "Your user menu › API key (Dispatcharr 0.28 or later). The key's user must be an admin to read status."
        case .seerr: "Settings › General › API Key. The key acts as the owner account."
        }
    }

    /// How often an open provider screen refreshes; matched to how fast each service's data changes and what polling costs it.
    var refreshInterval: Duration {
        switch self {
        case .glances, .nzbget, .deluge, .qui: .seconds(5)
        case .tautulli, .tdarr, .gluetun, .beszel, .tracearr, .dockhand, .arcane: .seconds(10)
        case .audiobookshelf, .immich, .komodo, .coolify, .synology, .dispatcharr: .seconds(15)
        case .bazarr, .komga, .kavita, .crowdsec, .technitium, .seerr: .seconds(30)
        case .nzbhydra, .wizarr, .maintainerr, .nextdns, .controld: .seconds(60)
        case .jackett: .seconds(300)
        default: .seconds(15)
        }
    }

    /// Integrations whose queue appears on the combined Activity screen.
    var hasTransferQueue: Bool {
        switch self {
        case .radarr, .sonarr, .lidarr, .qbittorrent, .sabnzbd, .transmission, .nzbget, .deluge, .qui: true
        default: false
        }
    }

    /// TrueNAS revokes API keys used over an unencrypted connection.
    var requiresHTTPS: Bool { self == .truenas || fixedBaseURL != nil }

    /// Cloud APIs have one address; the editor doesn't ask for it.
    var fixedBaseURL: URL? {
        switch self {
        case .tailscale: URL(string: "https://api.tailscale.com")
        case .cloudflare: URL(string: "https://api.cloudflare.com")
        case .nextdns: NextDNSClient.baseURL
        case .controld: ControlDClient.baseURL
        default: nil
        }
    }
}
