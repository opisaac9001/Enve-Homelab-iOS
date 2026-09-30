# Release notes

Petty: Homelab is free and open source, with no accounts, tracking or paid tiers. Everything below talks only to servers you add, and credentials stay in this device's Keychain.

## 0.1 (unreleased)

### Release-readiness fixes
- **Privacy:**
  - Server logs are masked (keys, tokens, passwords, Bearer and Basic credentials) everywhere they're shown: Unraid system and container logs, Portainer, Proxmox task logs, the Home Assistant error log, and *arr warnings. The raw log screens are now Owner-only.
  - Error messages no longer include the query string of a redirect address, and server error text is masked. Before, an API key sent in a URL (Tautulli, NZBHydra2, Jackett) could reach notifications, ntfy and the widget.
  - Household and companion files no longer carry trusted certificate fingerprints or SSH host keys; each certificate is reviewed on the receiving device.
  - The widget file and exported files now use the same file protection as the rest of the app's data.
- **View-only profiles:** notification rules, ntfy and quiet hours, service check editing and certificate trust, SSH keys, server reordering, the empty home screen's add buttons, connection editing from error screens, Unraid container and VM controls, and the container update check are now Owner-only. Search no longer shows alerts from hidden items.
- **Safer actions:**
  - Dispatcharr, Tautulli and NZBHydra2 backups, Kavita's Scan All Libraries, Synology VM power on and Pause All on download clients now ask first.
  - TrueNAS snapshot runs (retention can delete snapshots) and Plex Clean Bundles use destructive styling.
  - Saved SSH commands now warn about more commands: docker stop/restart/pause, compose down/stop/restart, virsh shutdown/reboot, rc.d and service stops, and zfs set.
  - An action that runs on tap now keeps its error on screen instead of reloading over it. Row actions can't be sent twice while one is running.
- **Accessibility and setup:**
  - Face ID now has its usage description; without it, switching to an Owner profile couldn't use Face ID.
  - Privacy manifests for the app and widget.
  - The version comes from the project settings (0.1, build 1).
  - The tab bar scales with Dynamic Type.
  - The plays chart has a VoiceOver summary.
  - Rows that contain buttons (device sign-out, request actions, Home Assistant controls, PoE power cycle) no longer merge those buttons into one VoiceOver element.
  - Discovery explains when Local Network access is blocked instead of spinning forever.
- **Documentation:** the README's capability table now states exactly which actions run without a confirmation, and the in-app setup guides list every action each integration offers.

### Media library
- **Maintenance for Komga, Kavita, Audiobookshelf, Immich and Dispatcharr:** whether an update is available, and the latest backup with its age. A backup more than 14 days old, or none at all, is flagged.
- **New backups, each with a confirmation:**
  - Kavita: back up the database.
  - Audiobookshelf: create a backup.
  - Dispatcharr: create a backup. The app now waits for Dispatcharr's backup task and reports a failure. Earlier builds reported success as soon as the task was queued.
- **Tautulli:** recent warnings and errors from its own log, and which notification agents are failing to deliver.
- **Jellyfin and Emby:**
  - Installed plugins, with failed or disabled ones first. Emby also shows plugin updates and uses its package API for server updates.
  - Owner profiles can read server logs: the latest 300 lines, newest first, with a warnings-only filter and search.
- **Tracearr:** streams that fell back from hardware to software transcoding, or are falling behind. The week's playback mix and peak concurrent streams.
- **Masking:** keys, tokens, passwords and credentials in every log line shown are masked before display.
- **Not offered, on purpose:** restoring or deleting backups, Plex item refreshes and log bundles, Kavita's log download, Audiobookshelf's listener log, and Maintainerr's single-rule runs and deletion routes. Jellystat and Streamystats are still not integrations. The README lists every service's limits, including what's unverified.

### Media automation and downloads
- **Radarr, Sonarr, Lidarr and Prowlarr System screen:**
  - Scheduled tasks with their last and next run.
  - The latest warnings and errors.
  - A pending update with its changelog.
  - The backup list.
  - Run the Backup, Housekeeping or health-check task now, each with a confirmation.
- **qBittorrent and Transmission:** tap a torrent to see each tracker's status, seeds, peers and error. Only host names are shown, because announce URLs can contain a private passkey. You can also verify a torrent's data after a disk problem or a move.
- **Not offered, on purpose:** searches, grabs, imports, application updates, backup restores, reannouncing, tracker edits and bulk verification.

### Infrastructure
- **Proxmox node detail:**
  - Load, memory, root filesystem, kernel, Proxmox version and boot mode.
  - Storage usage, with enabled-but-offline stores called out.
  - Each disk's SMART health, and its full attribute table or NVMe report, with failing and early-warning attributes marked.
  - Failed tasks open their log.
- **TrueNAS data protection:** periodic snapshot and replication tasks with their last result and error. Run a snapshot task now, with a confirmation that explains its retention.
- **Portainer container health:** health-check results and failing streak, restart count and policy, out-of-memory kills and exit code. Environment variables are never read.
- **Not offered, on purpose:** node reboots, guest deletion and migration, snapshot rollback, TrueNAS SMART tests (removed from the public API in 25.10), replication runs, pruning and removal. The README lists each product's boundaries, including why Dozzle, Scrutiny and UGREEN remain unsupported.

### Network and smart home
- **Pi-hole and AdGuard Home diagnostics:**
  - Check any domain to see whether it's blocked and which list or rule decides it.
  - The latest 50 queries, for Owner profiles only.
  - Pi-hole's own diagnosis messages.
- **DNS maintenance, each with a confirmation:**
  - Pi-hole: update blocklists, restart the resolver, and allow one exact domain.
  - AdGuard Home: refresh filter lists.
- **UniFi device detail:**
  - Ports with link speed and PoE state, and radios with channel, width and retry rates.
  - CPU, memory, load, uptime and uplink throughput.
  - Power-cycle a single PoE port, with a confirmation that names the port and device.
- **Home Assistant:** check configuration.yaml without applying it, and read the error log.
- **Not offered, on purpose:**
  - Flushing logs, and rewriting AdGuard's custom rules (the only way it allows a domain).
  - UniFi guest authorisation, device adoption, firewall, network and Wi-Fi changes.
  - Home Assistant restarts.
  - Tailscale device and key changes, Cloudflare tunnel and DNS changes, and CrowdSec decisions.
  - Settings changes on every service.
  - The README lists each one.

### Unraid Command Centre
- Drive details now show an on-device history of error counts and temperatures, with a chart and "new errors since" tracking. The Unraid API reports only current counters and an overall SMART pass/unknown.
- Disk usage alerts use the server's utilisation thresholds; temperature health uses Unraid's documented defaults. This fixes earlier builds, which read the utilisation thresholds as temperatures.
- Temperature sensors with the server's recent history (Unraid API 4.32+).
- Read-only system log viewer with line counts and filtering.
- Container template details (API 4.29+):
  - The template file, and any orphaned or rebuild-ready state.
  - LAN addresses, writable-layer and log sizes, and autostart position and delay.
  - Project, support and registry links.
- Port conflicts between containers are shown on the Docker screen.
- Every Unraid query and mutation is validated against the published Unraid API schema.
- **Not offered, on purpose:** clearing disk statistics (its server-side scope is unclear), autostart changes (they rewrite the whole list), container removal, bulk updates, disk mounting and assignment, and key changes.

### Requests (Seerr, Overseerr, Jellyseerr)
- Manage requests other people have made: approve, optionally choosing the Radarr or Sonarr server, quality profile and root folder first. You can also decline, retry failed requests and delete requests.
- Edit a pending request's requester and, for series, its seasons. Seerr applies its own quota and season rules, and the routing already on the request is kept.
- See each requester's quota (read-only).
- Resolve, reopen and reply to reported issues, and read their conversation.
- Waiting requests and open issues surface as needing attention, so notification rules can alert on them.
- There's no searching, browsing or creating requests.

### Schedule and statistics
- **Schedule:** upcoming releases, missing monitored items and download queues from Radarr, Sonarr and Lidarr, in one place. Unmonitored items can be shown.
- **Statistics:** Tautulli plays per day for 7, 30 or 90 days or a year, with top shows, movies, users and platforms. Pick a person to see their plays, watch time and players.
- **Library totals** from Jellyfin and Emby; **request totals** from Seerr.

### Household, profiles and privacy
- View-only profiles can be limited to chosen integrations and service checks, chosen by category. Hidden items leave home, search, the Schedule, Statistics, alerts, widgets and deep links.
- Home shows which View-only profile is active and links to switching back.
- Share with Household makes a file with only the items you pick and no credentials. Importing it can switch the device to a View-only profile limited to those items.
- Privacy & Data lists what's stored and where, and Erase All Data removes every file, Keychain item, widget copy and delivered notification.

### Docker host import
- Import from Docker Host explains the three steps: save the bundled script, run it on the host, pick its output.
- Re-running the script is safe. Services keep the same IDs, so the review shows what's already set up, offers port changes as optional address updates, and names services the export no longer lists without removing them.

### Reliability
- Error states offer the fix that matches the failure: Review Certificate, Edit Connection or Diagnose. Failed sources in the Schedule and Statistics link to them.
- Offline detection pauses checks and refreshes and never raises alerts for the device's own lost connection.
- Quiet hours and test notifications for alerts.

### Known limits
See **Known boundaries** in the README. The main ones:
- **Real hardware:** no integration has yet been verified against its real product; everything is tested against fixtures built from each product's official documentation.
- **Seerr quotas:** they can't be edited, because the only documented route also rewrites the user's personal details.
- **Seerr issue comments:** they can't be edited or deleted.
- **Background monitoring:** there's none beyond iOS's own background refresh, and no push service.
