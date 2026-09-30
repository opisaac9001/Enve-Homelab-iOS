#!/usr/bin/env python3
"""Petty: Homelab companion export.

Run on a Docker host to list its containers as Petty: Homelab integrations and service
checks, written in the app's backup format. Import it from Add > Import from Docker Host
(or Settings > Backup & Sharing > Import a File), choose what to add, then enter each API key.
Nothing already set up is replaced.

Privacy: this reads only `docker ps` (names, images, published ports). It never reads
environment variables, volumes, logs or secrets, never opens a network connection,
and writes only the file you name. Python 3.8+ standard library only.

    python3 petty-companion-export.py --host 192.168.1.20 -o petty-homelab.json
"""

import argparse
import datetime
import ipaddress
import json
import re
import subprocess
import sys
import uuid

# Repository name (matched against the end of the image's repository path) -> (integration kind, container port, scheme).
KNOWN_IMAGES = [
    ("portainer/portainer", "portainer", 9443, "https"),
    ("pihole/pihole", "pihole", 80, "http"),
    ("adguard/adguardhome", "adguard", 3000, "http"),
    ("homeassistant/home-assistant", "homeassistant", 8123, "http"),
    ("home-assistant/home-assistant", "homeassistant", 8123, "http"),
    ("jellyfin/jellyfin", "jellyfin", 8096, "http"),
    ("plexinc/pms-docker", "plex", 32400, "http"),
    ("plex", "plex", 32400, "http"),
    ("emby/embyserver", "emby", 8096, "http"),
    ("radarr", "radarr", 7878, "http"),
    ("sonarr", "sonarr", 8989, "http"),
    ("lidarr", "lidarr", 8686, "http"),
    ("prowlarr", "prowlarr", 9696, "http"),
    ("qbittorrent", "qbittorrent", 8080, "http"),
    ("sabnzbd", "sabnzbd", 8080, "http"),
    ("transmission", "transmission", 9091, "http"),
    ("nzbget", "nzbget", 6789, "http"),
    ("deluge", "deluge", 8112, "http"),
    ("bazarr", "bazarr", 6767, "http"),
    ("nzbhydra2", "nzbhydra", 5076, "http"),
    ("jackett", "jackett", 9117, "http"),
    ("haveagitgat/tdarr", "tdarr", 8266, "http"),
    ("maintainerr", "maintainerr", 6246, "http"),
    ("tautulli", "tautulli", 8181, "http"),
    ("gotson/komga", "komga", 25600, "http"),
    ("kavita", "kavita", 5000, "http"),
    ("advplyr/audiobookshelf", "audiobookshelf", 80, "http"),
    ("immich-app/immich-server", "immich", 2283, "http"),
    ("wizarrrr/wizarr", "wizarr", 5690, "http"),
    ("nicolargo/glances", "glances", 61208, "http"),
    ("crowdsecurity/crowdsec", "crowdsec", 8080, "http"),
    ("technitium/dns-server", "technitium", 5380, "http"),
    ("qmcgaw/gluetun", "gluetun", 8000, "http"),
    ("autobrr/qui", "qui", 7476, "http"),
    ("henrygd/beszel", "beszel", 8090, "http"),
    ("seerr-team/seerr", "seerr", 5055, "http"),
    ("fallenbagel/jellyseerr", "seerr", 5055, "http"),
    ("sctx/overseerr", "seerr", 5055, "http"),
    ("overseerr", "seerr", 5055, "http"),
]

# Containers whose web UI is worth an HTTP health check when no integration applies.
WEB_PORTS = {80, 443, 3000, 5000, 8000, 8080, 8081, 8443, 8888, 9000}

PORT_PATTERN = re.compile(r"(?:(?P<ip>[\d.]+|\[?[0-9a-f:]*\]?):)?(?P<host>\d+)->(?P<container>\d+)/tcp")


def published_ports(ports_field):
    """Maps container port -> host port from `docker ps` output such as '0.0.0.0:7878->7878/tcp'."""
    mapping = {}
    for match in PORT_PATTERN.finditer(ports_field or ""):
        mapping.setdefault(int(match.group("container")), int(match.group("host")))
    return mapping


def repository(image):
    """'lscr.io/linuxserver/radarr:5.2@sha256:…' -> 'lscr.io/linuxserver/radarr'."""
    path = image.lower().split("@")[0]
    head, _, last = path.rpartition("/")
    return f"{head}/{last.split(':')[0]}" if head else last.split(":")[0]


def classify(image):
    repo = repository(image)
    for name, kind, port, scheme in KNOWN_IMAGES:
        if repo == name or repo.endswith("/" + name):
            return kind, port, scheme
    return None


def display_name(container_name, kind=None):
    name = container_name.lstrip("/")
    return name if kind is None else name.replace("-", " ").replace("_", " ").title()


def format_host(host):
    try:
        return f"[{host}]" if ipaddress.ip_address(host).version == 6 else host
    except ValueError:
        return host


# IDs are derived from the host, kind and container name so a re-run lists the same services with the same IDs,
# and the app can tell what's already set up (or has moved to a new port) instead of adding duplicates.
ID_NAMESPACE = uuid.UUID("6f1c2a52-3c1e-4d5e-9d4a-0e7b8c9a1f20")


def stable_id(host, kind, name):
    return str(uuid.uuid5(ID_NAMESPACE, f"{host.lower()}|{kind}|{name}")).upper()


def build_backup(containers, host, include_checks):
    integrations, checks, skipped = [], [], []
    for container in containers:
        name = container.get("Names", "").split(",")[0]
        image = container.get("Image", "")
        ports = published_ports(container.get("Ports", ""))
        match = classify(image)
        if match:
            kind, container_port, scheme = match
            # Host networking publishes nothing, so the container port is the host port.
            host_port = ports.get(container_port, container_port if not ports else None)
            if host_port is None:
                skipped.append(f"{name}: {kind} port {container_port} isn't published")
                continue
            integrations.append({
                "id": stable_id(host, kind, name),
                "kind": kind,
                "name": display_name(name, kind),
                "url": f"{scheme}://{format_host(host)}:{host_port}",
                "isEnabled": True,
                "isSample": False,
            })
        elif include_checks:
            web = sorted(port for port in ports if port in WEB_PORTS)
            if not web:
                continue
            scheme = "https" if web[0] in (443, 8443) else "http"
            checks.append({
                "id": stable_id(host, "check", name),
                "name": display_name(name),
                "url": f"{scheme}://{format_host(host)}:{ports[web[0]]}",
                "acceptedStatus": "successOrRedirect",
                "intervalSeconds": 60,
                "timeoutSeconds": 10,
            })
    backup = {
        "format": 1,
        "purpose": "companion",
        "exportedAt": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "servers": [],
        "integrations": integrations,
        "serviceChecks": checks,
        "sshHosts": [],
        "notificationRules": [],
    }
    return backup, skipped


def read_containers(path):
    if path:
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
    else:
        result = subprocess.run(["docker", "ps", "--format", "{{json .}}"], capture_output=True, text=True, check=True)
        lines = result.stdout.splitlines()
    return [json.loads(line) for line in lines if line.strip()]


def main():
    parser = argparse.ArgumentParser(description="Export this Docker host's services for Petty: Homelab.")
    parser.add_argument("--host", required=True, help="address the phone uses to reach this host, e.g. 192.168.1.20 or tower.local")
    parser.add_argument("-o", "--output", required=True, help="file to write")
    parser.add_argument("--include-checks", action="store_true", help="also add HTTP health checks for other containers with web ports")
    parser.add_argument("--input", help="read `docker ps --format '{{json .}}'` output from a file instead of running docker")
    args = parser.parse_args()

    if re.search(r"[/@?#\s]", args.host):
        parser.error("--host must be a bare host name or IP address")
    try:
        containers = read_containers(args.input)
    except (OSError, subprocess.CalledProcessError) as error:
        sys.exit(f"Couldn't list containers: {error}")

    backup, skipped = build_backup(containers, args.host, args.include_checks)
    with open(args.output, "w", encoding="utf-8") as handle:
        json.dump(backup, handle, indent=2)
    print(f"Wrote {len(backup['integrations'])} integrations and {len(backup['serviceChecks'])} service checks to {args.output}.")
    for line in skipped:
        print(f"Skipped {line}")
    print("No credentials were read or written. Add API keys in Petty: Homelab after importing the file.")


if __name__ == "__main__":
    main()
