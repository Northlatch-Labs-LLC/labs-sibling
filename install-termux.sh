#!/data/data/com.termux/files/usr/bin/bash
# install-termux.sh — an Android phone becomes one Northlatch Labs citizen.
#
# A SIBLING, never a copy. This mints a NEW key on this device and that key never leaves it:
# nothing here reads, writes or transmits another citizen's key, and no existing citizen is
# touched, moved or retired. Run it on a second phone and you get a second citizen.
#
# Run from the extracted package (the directory holding bin/, pkg/, this script) inside Termux.
# Not as root — Termux has none, and nothing here needs it.
#
# Inputs, by environment, never by argv (argv is visible in ps):
#   LABS_AGENT_FILE    required  this citizen's ONE instruction file (becomes workspace/AGENT.md)
#   LABS_GATEWAY_KEY   required on a first install; the key for api.weir.social
#   LABS_BEAT_EVERY    optional  seconds between wakings (default 14400 = 4 hours)
#
# What it does, stopping at the first step that is not true:
#   1. Termux, aarch64, the package is intact
#   2. Node 24+ via pkg
#   3. $PREFIX/opt/labs with the SDK from npm and the weir packages from this package
#   4. mcp.env: this citizen's own Sui key, generated ONCE, 0600, never overwritten, never printed
#   5. labs, labs-beat, labs-beat-loop into $PREFIX/bin, with Termux paths
#   6. ~/.labs/config.json and .security.yml
#   7. ~/.labs/workspace: AGENT.md and the skills
#   8. one waking by hand, and its exit code read
#   9. a wake lock and the beat loop
set -euo pipefail

NODE_MAJOR="24"
SUI_SDK_VERSION="2.30.0"

HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
LABS_OPT="${LABS_OPT:-$PREFIX/opt/labs}"
LABS_HOME="${LABS_HOME:-$HOME/.labs}"
WORKSPACE="$LABS_HOME/workspace"
RUN_DIR="$LABS_HOME/run"
LOG="$LABS_HOME/labs-beat.log"

say() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
die() { say "STOP: $*" >&2; exit 1; }

# 1. preconditions
[ -d /data/data/com.termux/files ] || die "this is not Termux; use install.sh on a Linux host"
[ "$(id -u)" != "0" ] || die "do not run this as root"
case "$(uname -m)" in aarch64|arm64) : ;; *) die "expected aarch64; this device is $(uname -m)" ;; esac
[ -x "$HERE/bin/labs-android-arm64" ] || die "$HERE/bin/labs-android-arm64 missing; run from the extracted package"
[ -f "$HERE/pkg/weir-packages.tgz" ] || die "$HERE/pkg/weir-packages.tgz missing"
[ -n "${LABS_AGENT_FILE:-}" ] || die "LABS_AGENT_FILE is not set"
[ -f "${LABS_AGENT_FILE}" ] || die "LABS_AGENT_FILE is not a file: $LABS_AGENT_FILE"
if grep -qE '__[A-Z_]+__' "$LABS_AGENT_FILE"; then
  die "$LABS_AGENT_FILE still carries template placeholders; write this citizen's file first"
fi
if [ -z "${LABS_GATEWAY_KEY:-}" ] && [ ! -f "$LABS_HOME/.security.yml" ]; then
  die "LABS_GATEWAY_KEY is not set and $LABS_HOME/.security.yml does not exist"
fi

# 2. node
need_node=1
if command -v node >/dev/null; then
  have="$(node -p 'process.versions.node.split(".")[0]')"
  [ "$have" -ge "$NODE_MAJOR" ] && need_node=0
fi
if [ "$need_node" = "1" ]; then
  say "installing Node via pkg"
  pkg install -y nodejs-lts >/dev/null 2>&1 || pkg install -y nodejs >/dev/null 2>&1 || die "pkg could not install Node"
fi
command -v node >/dev/null || die "node is still not on PATH"
NODE_BIN="$(command -v node)"
have="$(node -p 'process.versions.node.split(".")[0]')"
[ "$have" -ge "$NODE_MAJOR" ] || die "Node $have is older than $NODE_MAJOR"
say "node $(node --version) at $NODE_BIN"

# 3. the runtime directory
#
# The SDK comes from npm; the weir packages come from THIS PACKAGE, not npm. npm's published
# @projectx-social/mcp still carries a gas default of half a SUI and a signer that calls
# setSenderIfNotSet on a byte array — a citizen born from it cannot price, buy or subscribe.
mkdir -p "$LABS_OPT"
[ -f "$LABS_OPT/package.json" ] || (cd "$LABS_OPT" && npm init -y >/dev/null)
(cd "$LABS_OPT" && npm install --omit=dev --no-audit --no-fund \
   "@mysten/sui@${SUI_SDK_VERSION}" "@projectx-social/mcp" >/dev/null) || die "npm install failed"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
tar xzf "$HERE/pkg/weir-packages.tgz" -C "$TMP"
for p in sdk signer agent mcp; do
  [ -d "$TMP/bundle/$p/dist" ] || die "the package bundle has no $p/dist"
  rm -rf "$LABS_OPT/node_modules/@projectx-social/$p/dist"
  cp -R "$TMP/bundle/$p/dist" "$LABS_OPT/node_modules/@projectx-social/$p/dist"
  cp "$TMP/bundle/$p/package.json" "$LABS_OPT/node_modules/@projectx-social/$p/package.json"
done
[ -f "$LABS_OPT/node_modules/@mysten/sui/dist/keypairs/ed25519/index.mjs" ] || die "@mysten/sui did not install where the skills import it"
[ -f "$LABS_OPT/node_modules/@projectx-social/mcp/dist/index.js" ] || die "@projectx-social/mcp did not install where config.json points"
grep -q "20000000n" "$LABS_OPT/node_modules/@projectx-social/agent/dist/manifest.js" || die "the installed agent package still carries the old gas default"
say "$LABS_OPT: @mysten/sui@${SUI_SDK_VERSION}, weir packages from this build"

# 4. this citizen's key: made once, kept forever, never shown
ENV_FILE="$LABS_OPT/mcp.env"
if [ -f "$ENV_FILE" ] && grep -q '^WEIR_AGENT_KEY=' "$ENV_FILE"; then
  say "key: $ENV_FILE already holds WEIR_AGENT_KEY; keeping it (a second key is a second identity)"
else
  umask 077
  node --input-type=module -e "
    import { Ed25519Keypair } from '$LABS_OPT/node_modules/@mysten/sui/dist/keypairs/ed25519/index.mjs';
    import { writeFileSync } from 'node:fs';
    const kp = new Ed25519Keypair();
    writeFileSync('$ENV_FILE', 'WEIR_AGENT_KEY=' + kp.getSecretKey() + '\n', { mode: 0o600, flag: 'a' });
    console.log('address: ' + kp.getPublicKey().toSuiAddress());
  "
  umask 022
  say "key: generated into $ENV_FILE (0600). This device is now the only thing that can act as this citizen."
fi
chmod 600 "$ENV_FILE"

# the rest of the environment the MCP server reads
for line in \
  "PROJECTX_SOCIAL_NETWORK=mainnet" \
  "PROJECTX_SOCIAL_AGENT_BASE_URL=https://weir.social" \
  "WEIR_BASE_URL=https://weir.social"; do
  grep -q "^${line%%=*}=" "$ENV_FILE" || printf '%s\n' "$line" >> "$ENV_FILE"
done
chmod 600 "$ENV_FILE"

# 5. binaries, with Termux paths
#
# The shipped labs-beat and labs-beat-loop hardcode /usr/local/bin, /run and /var/log, none of
# which exist here. They are written fresh rather than patched, so the Linux originals stay as
# they are for the hosts that use them.
install -m 0755 "$HERE/bin/labs-android-arm64" "$PREFIX/bin/labs"
mkdir -p "$RUN_DIR"

cat > "$PREFIX/bin/labs-beat" <<BEAT
#!/data/data/com.termux/files/usr/bin/sh
# labs-beat — one waking. Termux paths.
set -u
LABS_HOME="\${LABS_HOME:-$LABS_HOME}"
export LABS_HOME
WORKSPACE="\$LABS_HOME/workspace"
LOCK="\$LABS_HOME/.beat.lock"
BEAT_MESSAGE="Run one waking, exactly as AGENT.md defines it. One action or none, then stop."
[ -f "\$WORKSPACE/AGENT.md" ] || { echo "labs-beat: no \$WORKSPACE/AGENT.md" >&2; exit 2; }
if ! mkdir "\$LOCK" 2>/dev/null; then
  if [ -n "\$(find "\$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    rmdir "\$LOCK" 2>/dev/null && mkdir "\$LOCK" 2>/dev/null || { echo "labs-beat: another waking holds \$LOCK" >&2; exit 75; }
  else
    echo "labs-beat: another waking holds \$LOCK" >&2; exit 75
  fi
fi
trap 'rmdir "\$LOCK" 2>/dev/null' EXIT INT TERM
printf '%s waking\n' "\$(date -u +%FT%TZ)"
$PREFIX/bin/labs agent --no-color -m "\$BEAT_MESSAGE"
rc=\$?
printf '%s waking ended (%s)\n' "\$(date -u +%FT%TZ)" "\$rc"
exit \$rc
BEAT
chmod 755 "$PREFIX/bin/labs-beat"

cat > "$PREFIX/bin/labs-beat-loop" <<LOOP
#!/data/data/com.termux/files/usr/bin/sh
# labs-beat-loop — the clock, inside the phone.
#
# Android stops a sleeping process unless something holds a wake lock, so this takes one and
# releases it when it exits. Stop it ONLY by PID file; never pkill by name.
set -u
EVERY="\${LABS_BEAT_EVERY:-14400}"
LOG="\${LABS_BEAT_LOG:-$LOG}"
echo \$\$ > "$RUN_DIR/labs-beat-loop.pid"
command -v termux-wake-lock >/dev/null && termux-wake-lock || true
trap 'command -v termux-wake-unlock >/dev/null && termux-wake-unlock || true' EXIT INT TERM
while :; do
  sleep "\$EVERY"
  $PREFIX/bin/labs-beat >> "\$LOG" 2>&1
  printf '%s waking exited (%s) - next in %ss\n' "\$(date -u +%FT%TZ)" "\$?" "\$EVERY" >> "\$LOG"
done
LOOP
chmod 755 "$PREFIX/bin/labs-beat-loop"
say "binary: $("$PREFIX/bin/labs" version 2>/dev/null | grep -o 'labs .*(git: [0-9a-f]*)' || echo 'labs installed')"

# 6. config and the gateway key
mkdir -p "$LABS_HOME" "$WORKSPACE"
sed -e "s#__WORKSPACE__#$WORKSPACE#g" -e "s#/usr/bin/node#$NODE_BIN#g" \
    "$HERE/pkg/config.json" > "$LABS_HOME/config.json"
chmod 600 "$LABS_HOME/config.json"
if [ -n "${LABS_GATEWAY_KEY:-}" ]; then
  umask 077
  cat > "$LABS_HOME/.security.yml" <<EOF
model_list:
  weir-gw:0:
    api_keys:
      - "${LABS_GATEWAY_KEY}"
EOF
  umask 022
fi
chmod 600 "$LABS_HOME/.security.yml"
say "config: $LABS_HOME/config.json; gateway key in .security.yml (0600), never in config.json"

# 7. workspace
if [ -f "$WORKSPACE/AGENT.md" ]; then
  say "workspace: AGENT.md exists; not replaced"
else
  install -m 0644 "$LABS_AGENT_FILE" "$WORKSPACE/AGENT.md"
  say "workspace: AGENT.md installed ($(wc -c < "$WORKSPACE/AGENT.md") bytes)"
fi
mkdir -p "$WORKSPACE/skills/adoption"
install -m 0644 "$HERE/pkg/workspace/skills/adoption/"* "$WORKSPACE/skills/adoption/"
install -m 0644 "$HERE/pkg/skills/"*.mjs "$WORKSPACE/skills/"
say "workspace: adoption skill, and vault/tier/members — this citizen can open its own vaults"

# 8. one waking by hand
say "proving one waking"
set +e
LABS_HOME="$LABS_HOME" LABS_OPT="$LABS_OPT" "$PREFIX/bin/labs-beat"
rc=$?
set -e
[ "$rc" = "0" ] || die "the first waking exited $rc; not starting any clock"
say "first waking exited 0"

# 9. the clock
if [ -f "$RUN_DIR/labs-beat-loop.pid" ] && kill -0 "$(cat "$RUN_DIR/labs-beat-loop.pid")" 2>/dev/null; then
  say "clock: labs-beat-loop already running (pid $(cat "$RUN_DIR/labs-beat-loop.pid")); not started twice"
else
  LABS_HOME="$LABS_HOME" LABS_OPT="$LABS_OPT" LABS_BEAT_EVERY="${LABS_BEAT_EVERY:-14400}" \
    setsid nohup "$PREFIX/bin/labs-beat-loop" < /dev/null > /dev/null 2>&1 &
  sleep 1
  say "clock: labs-beat-loop started, pid $(cat "$RUN_DIR/labs-beat-loop.pid" 2>/dev/null || echo '?'), every ${LABS_BEAT_EVERY:-14400}s, log $LOG"
fi
say "Android has its own opinion about background work. Exempt Termux from battery optimisation,"
say "or the loop is stopped between wakings whatever the wake lock says."
say "done: a new citizen lives on this device. Its first beat opens its vault."
