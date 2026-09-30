# Testing and verification evidence

This records how Petty: Homelab is verified and the result of the most recent full automated run. The fixture suite exercises each integration against response shapes from product documentation. Separately, Unraid, qBittorrent, Sonarr, Radarr, Lidarr, Prowlarr, Plex, Jellyfin, Emby, Audiobookshelf, and Komga have been connected to running services in the iPhone Air simulator. Those sessions do not verify every management action or physical-device behavior.

## Environment of the last run

| | |
|---|---|
| Date | 2026-09-29 |
| Xcode | 27.0 |
| Simulator | iPhone Air (iOS 27) |
| DerivedData | Machine-local directory outside this repository |
| Build | `build-for-testing`, zero errors, zero warnings from the project's sources |

The only build-log line matching "warning" is Xcode's `appintentsmetadataprocessor` note that App Intents metadata extraction was skipped. It isn't a compiler warning; the app doesn't use App Intents.

## Results

| Suite | How it runs | Result |
|---|---|---|
| Unit (`EnveHomelabTests`, fixture suites skipped) | `-only-testing:EnveHomelabTests` | 286 tests in 65 suites passed |
| Integration fixtures (13 suites) | `SIMULATOR_ID=<UDID> Scripts/run-integration-tests.sh` | 81 tests passed |
| Real terminal against fixture `sshd` | part of the integration script | passed |
| Unraid schema check | same run with `UNRAID_SCHEMA` (unraid/api v4.37.5) and `GRAPHQL_MODULE_DIR` | 46 of 46 documents valid |
| UI flows | one test per `xcodebuild test-without-building` invocation, run serially | All 17 flows passed after the release-readiness fixes, plus the terminal flow in the integration script |

Run the UI tests one at a time, and never while the integration script is running: they share the simulator, and parallel runs interfere with each other.

## What each layer covers

### Unit tests
- **Decoding:** documented response shapes for every integration, including loose numbers, .NET and zoneless timestamps, and pagination headers.
- **Networking and security:** TLS pinning and trust reuse; recovery routing (which fix each error offers); Keychain erase; backups never containing secrets.
- **Alerts:** transitions and rules, quiet hours (including windows that wrap past midnight and critical break-through), and test notifications staying out of the inbox.
- **Profiles:** role transitions with an injected authenticator; scoped View-only visibility, including profiles saved before visibility existed.
- **Home and persistence:** home layout normalisation and pins; damaged-file quarantine.
- **Release readiness:** redirect errors drop their query string, server error text is masked, and the destructive-command list covers container, VM, service and ZFS changes.
- **Media library audit:** log masking (keys, tokens, Bearer/Basic, `MediaBrowser Token=`), version comparison, update states from Komga, Kavita and Immich, the Maintenance section's staleness rules, plugin ordering, Tautulli delivery summaries, and Dispatcharr backup health.
- **Seerr:** decoding keeps user names only; routing defaults, including 4K server separation; the attention summary; the sample request lifecycle.
- **Tautulli:** plays per day and per type; per-user watch time and players; sample ranges and people.
- **Imports:**
  - The import plan covers new, already here, the same service under a different entry, moved addresses, normalisation, and host-scoped "not in this export" items.
  - Household and companion files keep their purpose.

### Unraid API compatibility
`Scripts/validate-unraid-documents.mjs` validates the 46 documents the client can send (queries, mutations, subscriptions and fallbacks) against a published schema:

| Schema | Valid | What fails, as expected |
|---|---|---|
| unraid/api v4.37.5 (current) | 46 / 46 | — |
| v4.29.0 | 42 / 46 | temperatures (added in 4.32), UPS queries, container restart |
| v4.10.0 | 27 / 46 | newer features; every `…Compat` fallback is valid |

The app catches the server's "Cannot query field" answer as "not supported by this server". An integration test checks this against a fixture that behaves like an older release.

### Integration fixtures (`Scripts/integration-fixture-server.mjs`)
A throwaway Node server implements the documented routes for every integration, over HTTP and TLS, and checks what the app sends. It checks required parameters, headers and body fields, and records every mutating call so tests can assert on the exact request. The media library fixtures cover:
- **Tautulli:** `get_logs` (with an info line to filter and a URL token to mask) and `get_notification_log`.
- **Dispatcharr:** backups, the schedule, and backup creation followed by status polling. Alternate tasks succeed and fail, so both outcomes are checked.
- **Komga, Audiobookshelf and Immich:** releases, the backup list and creation, version check and database backups.
- **Tracearr:** `/activity`, and a stream whose `transcodeInfo` shows a software fallback.
- **Jellyfin and Emby:** plugins, package updates, log lists and log lines.
- **Maintainerr:** "Handle Due Media Now" is performed and the fixture confirms the request.
- Kavita's update check and database backup aren't in the fixture, whose key isn't an administrator; unit tests cover them.

The automation fixtures cover:
- **Servarr:** tasks, a warning-level log (including a stray info line the app must filter), updates (installed and pending), backups, and a Backup command.
- **qBittorrent:** trackers, with a passkey in the announce URL and unknown (-1) counts, plus recheck.
- **Transmission:** `trackerStats` (working, failing, never contacted) and `torrent-verify`.

The infrastructure fixtures cover:
- **Proxmox:** node status, storage (0/1 flags, an offline store), disk health, SMART attributes (numeric values, padded ids, a failing attribute), the NVMe text report, and task logs. A token without Sys.Audit gets a refusal.
- **TrueNAS:** snapshot task states in dict and bare-string form, a replication query refused by role, and a snapshot run.
- **Portainer:** Docker inspect, with an environment secret present that must not be decoded.

The network diagnostics fixtures cover Pi-hole queries, search, messages, gravity (streamed), restart and exact-domain allow, all inside released sessions. They also cover AdGuard Home's query log (including Unicode names), host checks (rule, rewrite, not found) and filter refresh, UniFi device details, statistics and PoE power-cycle (refusing a non-PoE port), and Home Assistant's configuration check and error log (refused for a non-admin token). The Unraid GraphQL fixture covers container details, port conflicts, temperatures (critical sensor, missing history), log files and a log read, plus an older-API variant that refuses the newer fields. Earlier passes added:
- **Seerr:** user list, quota (including a permission refusal), TV seasons, request edits that keep routing, a quota-exceeded refusal on requester change, and an issue comment round trip.
- **Tautulli:** `get_users` (local and inactive users filtered out), and `get_plays_by_date` with `user_id` and any `time_range`.
- **Tautulli (per user):** `get_user_watch_time_stats` and `get_user_player_stats`.
- **Companion script:** it runs twice over the same containers, once with a changed port. The test checks that IDs stay stable and that only the changed service is offered as an address update.

### UI flows (`EnveHomelabUITests/PreviewFlowUITests.swift`)
All flows use `-isolatedStorage`, so nothing touches real data or Keychain items. Sample-integration flows add `-sampleIntegrations`.

| Test | Covers |
|---|---|
| testPreviewCommandCentreFlows | Unraid preview: dashboard, containers, VMs, notifications, confirmations |
| testAddServerValidationAndUnreachableTest | Server editor validation and an unreachable-server connection test |
| testPreviewLiveStorageArrayAndUpdates | Live storage, array controls with typed confirmation, updates |
| testServiceCheckAndSSHHostManagement | Service checks and SSH host management |
| testRealTerminalAgainstFixtureServer | Host-key review and a real PTY session against the fixture `sshd` |
| testSampleIntegrationsSearchAlertsAndViewOnlyProfile | Pi-hole, Home Assistant, UniFi, search, profiles and the Owner-to-viewer transition |
| testSetupGuideAndTrustHelp | Per-integration setup guide and Trust & Security |
| testSampleServiceDashboardsConfirmActions | Tautulli, Glances, Gluetun confirmations naming target and consequence |
| testSampleMediaServerManagement | Jellyfin session controls, restart confirmation, task errors |
| testUpcomingPinsLayoutAndErase | Pinning, Schedule (upcoming, missing, queue), Home & Tabs, Privacy & Data, Erase All Data |
| testSampleRequestsStatisticsAndImports | Seerr approval with routing, issues, Statistics, Docker host import screen |
| testLimitedViewOnlyProfileHidesOtherItems | Category-grouped visibility, limited profile, home banner, hidden items |
| testRequestEditingIssueRepliesAndPersonalStatistics | Seerr season edit with quota, issue reply, Statistics range and person |
| testPreviewDiskHistoryTemperaturesLogsAndContainerTemplates | Temperature sensors, system log reading, drive history and usage alerts, port conflicts, orphaned and templated containers |
| testArrSystemAndTorrentDiagnostics | Radarr System screen (update, recent problems, only safe tasks runnable, confirmed backup); qBittorrent tracker status and a confirmed verify |
| testInfrastructureDiagnosticsProxmoxTrueNASPortainer | Proxmox node status, storage, failing disk SMART attributes and a failed task's log; TrueNAS task errors and the run confirmation; Portainer container health |
| testMediaLibraryAuditScreens | Jellyfin plugins and a masked server log line; Tautulli notification failures and log problems; Komga's available release; Audiobookshelf backup age and the Create Backup confirmation |
| testNetworkDiagnosticsPoECycleAndHomeAssistantChecks | Pi-hole domain check, recent queries, messages and a confirmed allow; UniFi ports with a PoE power-cycle confirmation; Home Assistant configuration check and error log |

For the release-readiness pass, every UI flow ran on its own, one after another, against the final build.

## Reproducing

```bash
xcodegen generate
xcodebuild build-for-testing -project EnveHomelab.xcodeproj -scheme EnveHomelab \
  -destination "platform=iOS Simulator,id=<UDID>" \
  -derivedDataPath build/DerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages

# Unit tests
xcodebuild test-without-building -project EnveHomelab.xcodeproj -scheme EnveHomelab \
  -destination "platform=iOS Simulator,id=<UDID>" \
  -derivedDataPath build/DerivedData -only-testing:EnveHomelabTests

# Integration fixtures and the real terminal flow
SIMULATOR_ID=<UDID> Scripts/run-integration-tests.sh

# Each UI flow on its own
xcodebuild test-without-building ... -only-testing:EnveHomelabUITests/PreviewFlowUITests/<testName>
```

On Xcode 27 `xcodebuild` sometimes keeps running after it has printed the results. If the log already shows `Test run with …` or the final `Test Case … passed/failed` line, it's safe to stop the process.
