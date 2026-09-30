#!/bin/zsh
# Runs protocol integration tests against local fixtures: an unprivileged sshd on a loopback port
# and a graphql-transport-ws server. Nothing is installed or left running; all state lives in a temp dir.
set -euo pipefail

ROOT="${0:A:h:h}"
SIMULATOR_ID="${SIMULATOR_ID:?Set SIMULATOR_ID to an iOS simulator UDID (xcrun simctl list devices)}"
DERIVED_DATA="${DERIVED_DATA:-$ROOT/build/DerivedData}"
PACKAGES="${PACKAGES:-$ROOT/build/SourcePackages}"
SSH_PORT="${SSH_PORT:-22422}"
WS_PORT="${WS_PORT:-4719}"
PROVIDER_PORT="${PROVIDER_PORT:-4720}"
PROVIDER_TLS_PORT="${PROVIDER_TLS_PORT:-4721}"

# Fixtures from an interrupted earlier run would hold the ports; stop them first.
pkill -f "sshd -D -f /tmp/enve-homelab-it" 2>/dev/null || true
pkill -f "sshd -f /tmp/enve-homelab-it" 2>/dev/null || true
pkill -f "Scripts/graphql-ws-fixture-server.mjs" 2>/dev/null || true
pkill -f "Scripts/integration-fixture-server.mjs" 2>/dev/null || true

WORK="$(mktemp -d /tmp/enve-homelab-it.XXXXXX)"
cleanup() {
  [[ -n "${SSHD_PID:-}" ]] && kill "$SSHD_PID" 2>/dev/null || true
  [[ -n "${WS_PID:-}" ]] && kill "$WS_PID" 2>/dev/null || true
  [[ -n "${PROVIDER_PID:-}" ]] && kill "$PROVIDER_PID" 2>/dev/null || true
}
trap cleanup EXIT

ssh-keygen -q -t ed25519 -N "" -f "$WORK/host_ed25519"
ssh-keygen -q -t ed25519 -N "" -C "enve-homelab-it" -f "$WORK/client_ed25519"
ssh-keygen -q -t ed25519 -N "" -C "enve-homelab-it-wrong" -f "$WORK/wrong_ed25519"
cp "$WORK/client_ed25519.pub" "$WORK/authorized_keys"
chmod 600 "$WORK/authorized_keys"

cat > "$WORK/sshd_config" <<CONFIG
ListenAddress 127.0.0.1
Port $SSH_PORT
HostKey $WORK/host_ed25519
PidFile $WORK/sshd.pid
AuthorizedKeysFile $WORK/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PermitTTY yes
AllowUsers $(whoami)
CONFIG

/usr/sbin/sshd -D -f "$WORK/sshd_config" -E "$WORK/sshd.log" &
SSHD_PID=$!
node "$ROOT/Scripts/graphql-ws-fixture-server.mjs" "$WS_PORT" fixture-key > "$WORK/ws.log" 2>&1 &
WS_PID=$!

openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -pkeyopt ec_param_enc:named_curve -nodes -days 2 -subj "/CN=127.0.0.1" \
  -addext "subjectAltName=IP:127.0.0.1" -keyout "$WORK/tls.key" -out "$WORK/tls.pem" 2>/dev/null
TLS_FINGERPRINT="$(openssl x509 -in "$WORK/tls.pem" -noout -fingerprint -sha256 | cut -d= -f2)"
node "$ROOT/Scripts/integration-fixture-server.mjs" "$PROVIDER_PORT" "$PROVIDER_TLS_PORT" "$WORK/tls.pem" "$WORK/tls.key" > "$WORK/providers.log" 2>&1 &
PROVIDER_PID=$!

python3 "$ROOT/Scripts/enve-companion-export.py" --host 192.168.1.20 --include-checks \
  --input "$ROOT/Scripts/fixtures/docker-ps.jsonl" -o "$WORK/companion.json" > /dev/null
# A second run over the same containers, with one port changed, checks that re-runs are recognised.
sed 's/0.0.0.0:7878->7878/0.0.0.0:7879->7878/' "$ROOT/Scripts/fixtures/docker-ps.jsonl" > "$WORK/docker-ps-rerun.jsonl"
python3 "$ROOT/Scripts/enve-companion-export.py" --host 192.168.1.20 --include-checks \
  --input "$WORK/docker-ps-rerun.jsonl" -o "$WORK/companion-rerun.json" > /dev/null

print -r -- "$SSH_PORT" > "$WORK/ssh_port"
whoami > "$WORK/ssh_user"
ssh-keygen -lf "$WORK/host_ed25519.pub" | awk '{print $2}' > "$WORK/host_fingerprint"
for port in "$SSH_PORT" "$WS_PORT" "$PROVIDER_PORT" "$PROVIDER_TLS_PORT"; do
  for _ in {1..50}; do nc -z 127.0.0.1 "$port" 2>/dev/null && break; sleep 0.1; done
  nc -z 127.0.0.1 "$port" || { echo "Fixture on port $port didn't start" >&2; exit 1; }
done

# ONLY="EnveHomelabTests/ProviderIntegrationTests" narrows the run while iterating.
if [[ -n "${ONLY:-}" ]]; then
  ONLY_TESTING=("-only-testing:$ONLY")
else
  ONLY_TESTING=(
    -only-testing:EnveHomelabTests/SSHIntegrationTests
    -only-testing:EnveHomelabTests/GraphQLSubscriptionIntegrationTests
    -only-testing:EnveHomelabTests/ProviderIntegrationTests
    -only-testing:EnveHomelabTests/ServiceIntegrationTests
    -only-testing:EnveHomelabTests/PlatformIntegrationTests
    -only-testing:EnveHomelabTests/MediaManagementIntegrationTests
    -only-testing:EnveHomelabTests/RequestsIntegrationTests
    -only-testing:EnveHomelabTests/UnraidDocumentTests
    -only-testing:EnveHomelabTests/UnraidIntegrationTests
    -only-testing:EnveHomelabTests/NetworkDiagnosticsIntegrationTests
    -only-testing:EnveHomelabTests/InfrastructureDiagnosticsIntegrationTests
    -only-testing:EnveHomelabTests/AutomationDiagnosticsIntegrationTests
    -only-testing:EnveHomelabTests/MediaLibraryAuditIntegrationTests
    -only-testing:EnveHomelabUITests/PreviewFlowUITests/testRealTerminalAgainstFixtureServer
  )
fi

TEST_RUNNER_INTEGRATION_DIR="$WORK" \
TEST_RUNNER_GRAPHQL_WS_URL="http://127.0.0.1:$WS_PORT" \
TEST_RUNNER_PROVIDER_HTTP_URL="http://127.0.0.1:$PROVIDER_PORT" \
TEST_RUNNER_PROVIDER_TLS_URL="https://127.0.0.1:$PROVIDER_TLS_PORT" \
TEST_RUNNER_PROVIDER_TLS_FINGERPRINT="$TLS_FINGERPRINT" \
TEST_RUNNER_COMPANION_EXPORT="$WORK/companion.json" \
TEST_RUNNER_COMPANION_RERUN="$WORK/companion-rerun.json" \
TEST_RUNNER_UNRAID_DOCUMENTS="$WORK/unraid-documents.json" \
xcodebuild -project "$ROOT/EnveHomelab.xcodeproj" -scheme EnveHomelab \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath "$DERIVED_DATA" -clonedSourcePackagesDirPath "$PACKAGES" \
  "${ONLY_TESTING[@]}" \
  test

# Optional: check every Unraid GraphQL document against a published schema, e.g.
# UNRAID_SCHEMA=generated-schema.graphql (from github.com/unraid/api) GRAPHQL_MODULE_DIR=<dir with node_modules/graphql>
if [[ -n "${UNRAID_SCHEMA:-}" && -n "${GRAPHQL_MODULE_DIR:-}" && -f "$WORK/unraid-documents.json" ]]; then
  node "$ROOT/Scripts/validate-unraid-documents.mjs" "$UNRAID_SCHEMA" "$WORK/unraid-documents.json" "$GRAPHQL_MODULE_DIR"
fi
