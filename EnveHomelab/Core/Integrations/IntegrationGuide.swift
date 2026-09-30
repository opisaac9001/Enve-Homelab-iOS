import Foundation

/// What a user needs to connect an integration, and exactly what the app will do with it.
struct IntegrationGuide: Sendable {
    var steps: [String]
    var permissions: String
    var address: String
    var reads: String
    var actions: [String]
}

extension IntegrationKind {
    var guide: IntegrationGuide {
        switch self {
        case .proxmox:
            IntegrationGuide(
                steps: ["In Proxmox, open Datacenter › Permissions › API Tokens and choose Add.", "Pick the user, name the token, and copy the token secret — it's shown once.", "Enter the full token ID (user@realm!name) and the secret here."],
                permissions: "PVEAuditor on / for monitoring. Add VM.PowerMgmt where you want power actions. With privilege separation on, the token needs its own permissions.",
                address: "https://<host>:8006. A self-signed certificate is normal; review its fingerprint when asked.",
                reads: "Version, nodes, guests and recent cluster tasks; per node its status, storage and disk SMART health (needs Sys.Audit, included in PVEAuditor); the log of a failed task.",
                actions: ["Start, shut down, reboot, suspend and resume guests", "Stop and reset (you type the guest's name)"]
            )
        case .truenas:
            IntegrationGuide(
                steps: ["In TrueNAS, open your account menu › API Keys (or Credentials › Users) and add a key.", "Copy the key; it's shown once."],
                permissions: "The key acts as its user. A read-only admin can monitor; scrubs and alert changes need write access.",
                address: "https://<host>. HTTPS is required: TrueNAS revokes API keys sent over plain HTTP.",
                reads: "System info, pools, disks, alerts, datasets, recent jobs, and the state of periodic snapshot and replication tasks (SNAPSHOT_TASK_READ and REPLICATION_TASK_READ roles).",
                actions: ["Start, pause and stop scrubs", "Dismiss and restore alerts", "Run a periodic snapshot task now (confirmed; needs SNAPSHOT_TASK_WRITE)"]
            )
        case .portainer:
            IntegrationGuide(
                steps: ["In Portainer, open My account › Access tokens › Add access token.", "Copy the token (it starts with ptr_)."],
                permissions: "The token has your user's access. Environments you can't manage in Portainer can't be managed here either.",
                address: "https://<host>:9443 (or http://<host>:9000).",
                reads: "Environments, containers, stacks, container logs, and each container's health checks, restart count and last exit (never its environment variables).",
                actions: ["Start, stop and restart containers", "Start and stop stacks"]
            )
        case .pihole:
            IntegrationGuide(
                steps: ["In Pi-hole v6, open Settings › Web interface / API.", "Create an app password (recommended) and copy it."],
                permissions: "An app password has full API access; keep it only on devices you trust.",
                address: "http(s)://<pi-hole host>. Pi-hole v5 isn't supported (its API was replaced in v6).",
                reads: "Query totals, blocked share, cache, active clients, blocklist size and blocking state; domain checks, diagnosis messages and, for Owner profiles, the latest 50 queries.",
                actions: ["Pause blocking for a set time or until resumed", "Turn blocking back on", "Update blocklists (confirmed)", "Restart the DNS resolver (confirmed)", "Allow one exact domain (confirmed)"]
            )
        case .adguard:
            IntegrationGuide(
                steps: ["Use the username and password you sign in to AdGuard Home with.", "Leave them blank if authentication isn't configured."],
                permissions: "The account's full access.",
                address: "http(s)://<host>:<web port> (often 3000 or 80).",
                reads: "Query totals, blocked counts, average processing time and protection state; host checks and, for Owner profiles, the latest 50 queries.",
                actions: ["Pause protection for a set time or until resumed", "Turn protection back on", "Refresh filter lists (confirmed)"]
            )
        case .unifi:
            IntegrationGuide(
                steps: ["In UniFi Network, open Settings › Control Plane › Integrations.", "Create an API key and copy it."],
                permissions: "Integration API keys use the official Network API; classic controller logins aren't used.",
                address: "https://<console IP>. Consoles use a self-signed certificate; review its fingerprint.",
                reads: "Sites, devices (state and firmware updates), connected clients, and per device its ports, PoE state, radios and latest statistics.",
                actions: ["Restart a device (you type the name for gateways)", "Power-cycle one PoE port (confirmed)"]
            )
        case .tailscale:
            IntegrationGuide(
                steps: ["In the Tailscale admin console, open Settings › Keys.", "Generate an API access token and copy it."],
                permissions: "Access tokens expire after the period you choose. The app only reads devices.",
                address: "Fixed: api.tailscale.com.",
                reads: "Devices, whether they're connected, key expiry and available client updates.",
                actions: []
            )
        case .cloudflare:
            IntegrationGuide(
                steps: ["In Cloudflare, open My Profile › API Tokens › Create Token.", "Grant Account › Cloudflare Tunnel › Read (and optionally Zone › Zone › Read).", "Copy the token and your account ID from the account home page."],
                permissions: "Read-only permissions are enough and recommended.",
                address: "Fixed: api.cloudflare.com.",
                reads: "Token status, tunnel health and edge connections, and zones if permitted.",
                actions: []
            )
        case .homeassistant:
            IntegrationGuide(
                steps: ["In Home Assistant, open your profile › Security.", "Create a long-lived access token and copy it."],
                permissions: "The token acts as your user. Consider a dedicated non-admin user.",
                address: "http(s)://<host>:8123.",
                reads: "Areas, entities and their states, a configuration check that applies nothing, and the error log (administrator tokens).",
                actions: ["Toggle lights, switches, fans and input booleans", "Activate scenes", "Run scripts and automations (confirmed)", "Open and close covers (confirmed)", "Locks, alarms and climate stay read-only"]
            )
        case .jellyfin, .emby:
            IntegrationGuide(
                steps: ["In the \(displayName) dashboard, open API Keys (Emby: Advanced › Security) and add a key.", "Copy the key."],
                permissions: "API keys have administrator access.",
                address: self == .jellyfin ? "http(s)://<host>:8096." : "http(s)://<host>:8096 (the app adds /emby).",
                reads: "Server info, playing sessions and transcodes, libraries, scheduled tasks, devices, users, the activity log, recently added, a chosen user's continue-watching list, plugins and their updates, and, for Owner profiles, server logs with keys and tokens masked.",
                actions: ["Pause, resume and stop playback on clients that allow remote control", "Send a message and switch audio or subtitle tracks on clients that support it", "Scan a library or all libraries", "Run or stop a scheduled task", "Sign out a device", "Restart the server, when it allows it"]
            )
        case .plex:
            IntegrationGuide(
                steps: ["Sign in to the Plex web app as the server owner.", "Follow Plex's support article “Finding an authentication token / X-Plex-Token” and copy the token."],
                permissions: "The owner's token has full server access.",
                address: "http(s)://<host>:32400.",
                reads: "Server info and available update, playing sessions and transcodes, libraries, Butler tasks, background activities, watch history, recently added and continue watching.",
                actions: ["Stop a stream (servers with Plex Pass only)", "Scan a library or all libraries", "Refresh a library's metadata or analyze it", "Empty a library's trash (you type the name)", "Run or stop a Butler task, and cancel an activity", "Optimize the database, clean bundles and check for updates"]
            )
        case .radarr, .sonarr, .lidarr, .prowlarr:
            IntegrationGuide(
                steps: ["In \(displayName), open Settings › General › Security.", "Copy the API key."],
                permissions: "The API key has full access to \(displayName).",
                address: "http(s)://<host>:<port>, including any URL base you configured (for example /\(rawValue)).",
                reads: (self == .prowlarr ? "Status, health and indexers" : "Status, health, the download queue and disk space") + "; scheduled tasks, recent warnings and errors, a pending update and the backup list.",
                actions: (self == .prowlarr ? ["Test all indexers"] : ["RSS Sync and Refresh Downloads", "Remove items from the queue, optionally from the download client and blocklist"])
                    + ["Run the backup, housekeeping or health-check task now (confirmed)"]
            )
        case .qbittorrent:
            IntegrationGuide(
                steps: ["Enable the Web UI in qBittorrent (Tools › Options › Web UI).", "Use its username and password, or leave them blank if this network bypasses authentication."],
                permissions: "Full Web UI access. Repeated failed logins make qBittorrent temporarily ban the device.",
                address: "http(s)://<host>:8080.",
                reads: "Version, transfer rates, torrents, and each torrent's tracker status (host names only).",
                actions: ["Pause and resume torrents", "Remove torrents; deleting their data requires typing the name", "Verify a torrent's data on disk (confirmed)"]
            )
        case .sabnzbd:
            IntegrationGuide(
                steps: ["In SABnzbd, open Config › General › Security.", "Copy the API key (not the NZB key)."],
                permissions: "The full API key.",
                address: "http(s)://<host>:8080.",
                reads: "Queue, speed and version.",
                actions: ["Pause and resume jobs or the whole queue", "Delete jobs; deleting files requires typing the name"]
            )
        case .transmission:
            IntegrationGuide(
                steps: ["Enable remote access in Transmission.", "Enter the RPC username and password if authentication is on."],
                permissions: "Full RPC access.",
                address: "http(s)://<host>:9091 (the app adds /transmission/rpc).",
                reads: "Version, transfer rates, torrents, and each torrent's tracker status (host names only).",
                actions: ["Pause and resume torrents", "Remove torrents; deleting their data requires typing the name", "Verify a torrent's data on disk (confirmed)"]
            )
        case .nzbget:
            IntegrationGuide(
                steps: ["In NZBGet, open Settings › Security.", "Use the ControlUsername and ControlPassword, or the RestrictedUsername and RestrictedPassword."],
                permissions: "The restricted user can do everything this app does. The Add user can't read the queue.",
                address: "http(s)://<host>:6789.",
                reads: "Version, download rate, paused state and the queue, including post-processing progress.",
                actions: ["Pause and resume items or the whole download queue", "Remove items to history keeping their files, or delete their downloaded files (you type the start of the name)"]
            )
        case .deluge:
            IntegrationGuide(
                steps: ["Enable Deluge's web UI (deluge-web) and note its password.", "Make sure the web UI is connected to your daemon (Connection Manager)."],
                permissions: "The web UI password gives full control. If the web UI isn't connected, the app connects it to the first online daemon in its host list, as the web UI does itself.",
                address: "http(s)://<host>:8112.",
                reads: "Daemon version, transfer rates, session pause state and torrents.",
                actions: ["Pause and resume torrents or the whole session", "Remove torrents; deleting their data requires typing the name"]
            )
        case .bazarr:
            IntegrationGuide(
                steps: ["In Bazarr, open Settings › General › Security.", "Copy the API key."],
                permissions: "The API key has full access to Bazarr.",
                address: "http(s)://<host>:6767, including any URL base. Bazarr 1.4 or later.",
                reads: "Version, health, missing subtitles, provider throttling and scheduled tasks.",
                actions: ["Search for missing subtitles (all series, all movies, one episode language or one movie)", "Run a scheduled task now", "Reset throttled providers"]
            )
        case .nzbhydra:
            IntegrationGuide(
                steps: ["In NZBHydra2, open Config › Main and copy the API key.", "For indexer status, turn on Config › Auth › “Allow stats access via API”."],
                permissions: "The API key. NZBHydra2 deliberately doesn't let API clients change or re-enable indexers.",
                address: "http(s)://<host>:5076, including any URL base.",
                reads: "Version and indexer status (enabled, backing off, disabled, API and download limits). Version 9 and later also shows recent grabs.",
                actions: ["Create a backup (version 9 and later)"]
            )
        case .jackett:
            IntegrationGuide(
                steps: ["Open the Jackett dashboard.", "Copy the API key from the top of the page."],
                permissions: "The API key only reaches Jackett's Torznab API. Jackett's version and per-indexer errors need its web login, which the app doesn't use.",
                address: "http(s)://<host>:9117.",
                reads: "Configured indexers with their type and language.",
                actions: ["Test an indexer with an empty search, like Jackett's Test button"]
            )
        case .tdarr:
            IntegrationGuide(
                steps: ["Use the Tdarr server address (port 8266 by default).", "If Tdarr runs with auth=true, create a key in Tools › API Keys."],
                permissions: "With auth off, anyone who can reach the server can control it; keep it on a trusted network.",
                address: "http(s)://<host>:8266.",
                reads: "Nodes, which workers are busy and on what file, and queued items per worker type.",
                actions: ["Pause and resume a node"]
            )
        case .maintainerr:
            IntegrationGuide(
                steps: ["Use Maintainerr's address. It has no API key or login of its own.", "If you've put it behind a reverse proxy with basic authentication, enter those credentials."],
                permissions: "Maintainerr trusts anyone who can reach it, including for actions that delete media. Keep it off the internet or behind an authenticating proxy.",
                address: "http(s)://<host>:6246. Maintainerr 3.20 or later.",
                reads: "Version, database health, collections with their actions and waiting periods, and how many items are due.",
                actions: ["Run all rules now, or stop a rule run", "Handle due media now (can delete files; you type a confirmation)"]
            )
        case .tautulli:
            IntegrationGuide(
                steps: ["In Tautulli, open Settings › Web Interface › API.", "Turn on the API and copy the key."],
                permissions: "The API key has full access to Tautulli.",
                address: "http(s)://<host>:8181, including any HTTP root.",
                reads: "Plex connectivity, streams with direct play or transcode details, bandwidth, recent history, libraries, recent warnings and errors from Tautulli's log (keys masked) and failed notification deliveries.",
                actions: ["Stop a stream (Plex allows this only with Plex Pass)", "Refresh the libraries and users lists", "Back up Tautulli's database"]
            )
        case .komga:
            IntegrationGuide(
                steps: ["In Komga, open your account settings › API keys.", "Create a key and copy it; it's shown once."],
                permissions: "The key acts as your user. An admin's key also shows the server version and allows scans and maintenance. Komga 1.20 or later.",
                address: "http(s)://<host>:25600, including any context path.",
                reads: "Libraries, series and book counts, unreadable books, recently added books and, for admins, whether a newer Komga release is out.",
                actions: ["Scan or deep-scan a library", "Analyze a library's books, or one book again", "Empty a library's trash (you type the name)", "Cancel queued tasks"]
            )
        case .kavita:
            IntegrationGuide(
                steps: ["In Kavita, open User settings › Auth Keys.", "Create a key and copy it."],
                permissions: "The key acts as its user. With an admin's key you also see statistics, reading activity, unreadable files and scheduled jobs, and can scan.",
                address: "http(s)://<host>:5000.",
                reads: "Libraries, recently added series and, for admins, server statistics, active readers, file errors, jobs and available updates.",
                actions: ["Scan a library or all libraries", "Full rescan of a library", "Back up the database"]
            )
        case .audiobookshelf:
            IntegrationGuide(
                steps: ["In Audiobookshelf, open Settings › API Keys (version 2.26 or later).", "Create a key bound to an admin user and copy it."],
                permissions: "The key acts as the user it's bound to. Listening sessions and scans need an admin.",
                address: "http(s)://<host>:13378, including any sub-path.",
                reads: "Version, libraries with totals, running tasks, missing or invalid items, recent additions and, for admins, who's listening and the backup list.",
                actions: ["Scan or force-rescan a library", "Remove missing or invalid items (you type the library name)", "Create a backup"]
            )
        case .immich:
            IntegrationGuide(
                steps: ["In Immich, open Account Settings › API Keys.", "Create a key with server.about, server.storage, server.statistics, job.read and job.create, or all permissions."],
                permissions: "Statistics and job queues also require the key's owner to be an admin.",
                address: "http(s)://<host>:2283 (the app adds /api). Immich 1.113 or later.",
                reads: "Version and the latest release, storage use, photo and video counts, usage per user, job queues and, on Immich 2.5 or later, database backups.",
                actions: ["Pause and resume a queue", "Process missing items", "Clear failed jobs", "Empty a queue's waiting jobs"]
            )
        case .wizarr:
            IntegrationGuide(
                steps: ["In Wizarr, open Settings › API Keys.", "Create a key and copy it; it's shown once."],
                permissions: "The key has full API access. Every request is recorded as the key's last use.",
                address: "http(s)://<host>:5690. Wizarr 2025.8.3 or later.",
                reads: "User and invitation counts, invitations, users with access expiry and connected media servers.",
                actions: ["Delete an invitation", "Extend a user's access by 30 days", "Remove a user from their media server (you type the name)"]
            )
        case .glances:
            IntegrationGuide(
                steps: ["Run Glances in web server mode (glances -w), version 4 or later.", "If you started it with --password, enter the username (default “glances”) and password."],
                permissions: "Without --password, anyone who can reach port 61208 can read this host's stats.",
                address: "http(s)://<host>:61208, including any URL prefix.",
                reads: "CPU, memory, swap, load, file systems, sensors, containers and Glances' own alerts, judged by Glances' configured thresholds.",
                actions: ["Clear finished warnings or all alerts"]
            )
        case .synology:
            IntegrationGuide(
                steps: ["In DSM, create a user for this app (Control Panel › User & Group) without two-factor sign-in.", "Give it access to Download Station and Virtual Machine Manager only.", "Enter that account here."],
                permissions: "Synology documents third-party APIs only for sign-in, Download Station and Virtual Machine Manager. System health, storage, reboot and Container Manager use DSM's private web API and aren't available.",
                address: "https://<nas>:5001. DSM uses a self-signed certificate by default; review its fingerprint.",
                reads: "Virtual machines and their state, VMM host resources, and Download Station tasks and speed.",
                actions: ["Power on, shut down, or force power off (you type the name) a virtual machine", "Pause, resume or remove download tasks"]
            )
        case .dockhand:
            IntegrationGuide(
                steps: ["Turn on authentication in Dockhand (Settings › Authentication).", "Open your profile › API tokens › Generate token and copy it; it's shown once."],
                permissions: "Tokens have their user's full access. Without authentication turned on, Dockhand's API is open to anyone on the network.",
                address: "http(s)://<host>:3000. Dockhand 1.0.25 or later.",
                reads: "Environments, containers with health and restart counts, and compose stacks.",
                actions: ["Start, restart and stop containers and stacks"]
            )
        case .komodo:
            IntegrationGuide(
                steps: ["In Komodo, open Settings › API keys and create a key.", "Copy both the key and the secret; the secret is shown once."],
                permissions: "A key acts as its user. For least privilege, have an admin create a Service User with Read, plus Execute on the stacks and deployments you want to control.",
                address: "http(s)://<host>:9120.",
                reads: "Servers and their stats, stacks, deployments, image updates and unresolved alerts.",
                actions: ["Start, restart and stop stacks and deployments (the app waits for Komodo to report the result)"]
            )
        case .coolify:
            IntegrationGuide(
                steps: ["In Coolify, turn on Settings › Advanced › API access.", "Open Security › API Tokens and create a token with Deploy and Read (tick Deploy first).", "Copy the whole token, including the number and | at the start."],
                permissions: "Read and Deploy is enough; never grant root or write. Deploy tokens only work for team admins and owners.",
                address: "https://<coolify host>, the address of the Coolify dashboard.",
                reads: "Servers, applications, services, databases and deployments in progress.",
                actions: ["Start, restart and stop resources (stop keeps volumes and networks)", "Redeploy an application", "Cancel a deployment"]
            )
        case .arcane:
            IntegrationGuide(
                steps: ["In Arcane, open Settings › API Keys.", "Create a scoped key with list, start, stop and restart on the environments you want, and copy it."],
                permissions: "Scoped keys can be limited per environment; environments the key can't reach are shown as unavailable.",
                address: "http(s)://<host>:3552.",
                reads: "Environments, compose projects and containers with health.",
                actions: ["Start, restart and stop containers", "Start, restart and bring down compose projects"]
            )
        case .beszel:
            IntegrationGuide(
                steps: ["In Beszel, create a user for this app (a read-only role is enough to monitor).", "Enter its email and password."],
                permissions: "Beszel has no API keys; the app signs in as this user. Hubs that require a one-time code or have password sign-in turned off aren't supported.",
                address: "http(s)://<hub>:8090.",
                reads: "Systems with CPU, memory, disk, load and temperature, triggered alerts and container health.",
                actions: ["Pause and resume monitoring a system (not for read-only users)"]
            )
        case .technitium:
            IntegrationGuide(
                steps: ["In Technitium, create a user with Dashboard view and Settings modify permissions.", "Sign in as that user and create an API token (Administration › Sessions, or /api/user/createToken)."],
                permissions: "Tokens have their user's permissions. Version 15.5.1 or later is recommended for its security fixes.",
                address: "http(s)://<host>:5380.",
                reads: "Queries, blocked and cached counts, clients and blocking state for the last day.",
                actions: ["Pause blocking for a set time or until turned back on", "Turn blocking back on"]
            )
        case .controld:
            IntegrationGuide(
                steps: ["In the Control D dashboard, open Preferences › API.", "Create a token. Read is enough to monitor; pausing profiles needs Write.", "Don't restrict the token to an IP address if you use the app away from home."],
                permissions: "Control D's API reports profiles and endpoints but not query statistics, and doesn't say whether a profile is paused.",
                address: "The app uses api.controld.com.",
                reads: "Profiles, and endpoints with their status and profile.",
                actions: ["Pause a profile for one hour", "Resume filtering on a profile"]
            )
        case .nextdns:
            IntegrationGuide(
                steps: ["Copy your API key from the bottom of my.nextdns.io/account.", "Copy the profile ID from your profile's address (my.nextdns.io/<profile ID>/setup)."],
                permissions: "The API key controls your whole NextDNS account. NextDNS labels its API beta and offers no way to pause filtering.",
                address: "The app uses api.nextdns.io.",
                reads: "Queries and blocked share for the last 24 hours, most-blocked domains, block reasons and devices.",
                actions: ["Allow a blocked domain (adds it to the profile's allowlist)"]
            )
        case .gluetun:
            IntegrationGuide(
                steps: ["Publish Gluetun's control server port (8000) on your LAN.", "Recent Gluetun versions need a role in /gluetun/auth/config.toml; give it the vpn, publicip, portforward, dns and updater routes."],
                permissions: "Roles can use no auth, a username and password, or an API key. The control server has no TLS; keep it on your LAN or behind an HTTPS proxy.",
                address: "http://<docker host>:8000.",
                reads: "VPN, DNS and updater status, public exit IP and location, and forwarded ports.",
                actions: ["Stop, start or reconnect the VPN (stopping cuts internet for containers using it)", "Update the VPN server list"]
            )
        case .qui:
            IntegrationGuide(
                steps: ["In qui, open Settings › API Keys and create a key.", "Copy it; it's shown once."],
                permissions: "A key has the same access as your qui account, including deleting torrents and data.",
                address: "http(s)://<host>:7476, including any base URL.",
                reads: "Torrents and transfer rates across every connected qBittorrent instance.",
                actions: ["Pause and resume torrents", "Remove torrents; deleting their data requires typing the name"]
            )
        case .tracearr:
            IntegrationGuide(
                steps: ["Sign in to Tracearr as the owner.", "Open Settings › General and copy the public API key (it starts with trr_pub_)."],
                permissions: "The key can end streams. Regenerating it in Tracearr disconnects the app. Tracearr 1.4.6 or later.",
                address: "http(s)://<host>:3000, including any base path.",
                reads: "Media server status, active streams with transcode details and software fallbacks, plays today, the week's playback mix and peak streams, and unacknowledged rule violations.",
                actions: ["Stop a stream"]
            )
        case .seerr:
            IntegrationGuide(
                steps: ["In Seerr (or Overseerr or Jellyseerr), open Settings › General.", "Copy the API Key."],
                permissions: "Seerr's API key always acts as the owner account; there's no read-only key. Regenerating it in Seerr disconnects this app. User email addresses and media-server tokens in Seerr's responses are never read or stored.",
                address: "http(s)://<host>:5055, including any URL base.",
                reads: "Request and issue counts, requests with their status and availability, the Radarr and Sonarr servers Seerr sends approved requests to, open or resolved issues, the user list (names only) and each requester's quota. Titles of requested items are looked up by ID; the app never searches or browses.",
                actions: ["Approve a pending request, optionally choosing its Radarr or Sonarr server, quality profile and root folder", "Decline a pending request", "Edit a pending request's requester and, for series, its seasons", "Retry a failed request", "Delete a request", "Resolve or reopen an issue", "Reply to an issue (posted as the owner account)"]
            )
        case .dispatcharr:
            IntegrationGuide(
                steps: ["In Dispatcharr, open your user menu and generate an API key (Dispatcharr 0.28 or later).", "The key's user must be an admin."],
                permissions: "Generating a new key replaces the old one. The app reads only operational status; it never reads channel lists, stream addresses or provider logins.",
                address: "http(s)://<host>:9191.",
                reads: "Active channel and viewer counts, on-demand sessions, playlist and guide source health, errors from the last day, and backup files with the backup schedule.",
                actions: ["Create a backup"]
            )
        case .crowdsec:
            IntegrationGuide(
                steps: ["On the CrowdSec host, run: cscli bouncers add petty-homelab", "Copy the key it prints.", "Make the Local API reachable from this device (it listens on 127.0.0.1:8080 by default)."],
                permissions: "Bouncer keys can only read decisions. Use a dedicated key: sharing a firewall bouncer's key can confuse its updates.",
                address: "http(s)://<host>:8080.",
                reads: "Local API health and active decisions made by your CrowdSec instance and cscli, grouped by scenario.",
                actions: []
            )
        }
    }
}
