# Device test checklist

Use this for the first install on a physical iPhone. Everything so far has been verified on the iPhone Air simulator against local fixtures only. Tick each item, and note anything that differs from the README.

## Before building
- [ ] `xcodegen generate` from the repository root.
- [ ] Xcode › Signing: team `9TT6DBK8W3`, automatic signing, for both **EnveHomelab** and **EnveHomelabWidgets**. App Groups need a paid developer membership; a free personal team can't provision `group.com.isaaclamb.EnveHomelab`.
- [ ] Both App IDs have the App Group capability with `group.com.isaaclamb.EnveHomelab`.
- [ ] iPhone: Developer Mode on, developer certificate trusted after the first install.
- [ ] Build a **Debug** configuration to the device. The `-isolatedStorage` test switch only exists in Debug and isn't passed when you launch from the home screen.

## First launch
- [ ] The empty home screen appears; "Explore with Sample Data" works without any network access.
- [ ] Add › Discover on Network: the Local Network prompt appears. Allow it and services appear. If you deny it, the screen explains how to allow it instead of spinning forever.
- [ ] Notifications prompt: allow it, then Settings › Notifications › Send Test Notification.
- [ ] Settings › Privacy & Data lists what's stored.

## Unraid (primary flow)
- [ ] Add the server on its LAN address. For a self-signed certificate, the fingerprint review screen appears; compare the fingerprint with Unraid's certificate before trusting it.
- [ ] Dashboard, Storage (array, parity, drives, temperatures), Docker, VMs and Notifications load with real values.
- [ ] Container detail: logs load and follow; Share Logs output shows `[redacted]` where a key would be.
- [ ] Run one low-impact confirmed action (for example restart a non-critical container). The confirmation names the container and the server.
- [ ] Don't test array stop, VM force stop or container update on a server in use unless you mean to; they're typed-name confirmations.
- [ ] Add a remote endpoint (for example over a VPN) and check that endpoint selection switches when you leave Wi-Fi.

## Each integration you use
- [ ] Its setup guide (editor › How to connect …) matches what you had to do on the real product.
- [ ] Editor › Diagnose passes before saving.
- [ ] The dashboard shows real values, and any refused admin section says why rather than showing nothing.
- [ ] One confirmed action where it's safe to try. Note any server error text.

## Security and privacy
- [ ] Settings › Profiles: turn on "Require Face ID or passcode". The Face ID prompt shows the app's reason text.
- [ ] Switch to a View-only profile. Check there are no add or edit controls, Notifications is gone from Settings, log screens say "Logs Are for Owner Profiles", and container and VM controls are hidden. Switch back to Owner with Face ID.
- [ ] Share with Household: the exported file contains no keys (open it in Files). Importing it on a second device asks for certificate review again.
- [ ] Settings › Backup: the exported backup contains no keys.
- [ ] Lock-screen notifications show only the source name and the health detail.

## Background and widget
- [ ] Add the Home Screen widget after the app has run once. It shows names and health only, and tapping opens the matching screen.
- [ ] Leave Background App Refresh on and check a few hours later that alerts arrived (iOS decides when; there's no push service).
- [ ] Turn on Airplane Mode: home shows the offline banner and no alerts fire for the lost connection.

## SSH terminal
- [ ] Host-key review on first connection; a changed key is refused.
- [ ] Generate an Ed25519 key, install the public key on the host, and connect with it.
- [ ] A saved command such as `docker restart <name>` asks for confirmation; `uptime` runs directly.

## Accessibility
- [ ] VoiceOver: home, an integration dashboard and a confirmation sheet read sensibly. Buttons inside rows (Sign Out Device, Power Cycle, Home Assistant controls) can be reached on their own.
- [ ] Largest Dynamic Type: the tab bar and dashboards remain usable.

## Record for the report
- Product versions tested, anything that failed, and any server error text. Remove keys from screenshots before sharing them.
