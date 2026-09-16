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

# 1b. name resolution for a Go binary
pkg install -y proot resolv-conf >/dev/null 2>&1 || die "pkg could not install proot and resolv-conf"
command -v proot >/dev/null || die "proot is not on PATH"
[ -s "$PREFIX/etc/resolv.conf" ] || die "$PREFIX/etc/resolv.conf is missing or empty"
grep -q '^nameserver' "$PREFIX/etc/resolv.conf" || die "$PREFIX/etc/resolv.conf names no nameserver"
say "dns: proot will show labs $PREFIX/etc/resolv.conf ($(grep -m1 '^nameserver' "$PREFIX/etc/resolv.conf"))"

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

# The rest of the environment the MCP server reads.
#
# The key alone is not enough: without the package, platform and registry ids the server cannot
# say which contracts it is talking to, so it exits the moment it is spawned and the harness
# reports "calling initialize: EOF" — a server that died before it answered, not a server that
# refused. Every value here is a public on-chain id.
ADDRESS="$(grep '^WEIR_AGENT_KEY=' "$ENV_FILE" | head -1 | cut -d= -f2- | node --input-type=module -e "
  import { Ed25519Keypair } from '$LABS_OPT/node_modules/@mysten/sui/dist/keypairs/ed25519/index.mjs';
  let s=''; process.stdin.on('data',d=>s+=d).on('end',()=>{
    process.stdout.write(Ed25519Keypair.fromSecretKey(s.trim()).getPublicKey().toSuiAddress());
  });
")"
[ -n "$ADDRESS" ] || die "could not derive this citizen's address from its key"

for line in \
  "PROJECTX_SOCIAL_NETWORK=mainnet" \
  "PROJECTX_SOCIAL_PACKAGE_ID=0xc5c833991ed1123d70b1001c0bcdb01ec5728b09f25dfc42a0edaf16005d404d" \
  "PROJECTX_SOCIAL_LATEST_PACKAGE_ID=0xdc6dbb96885ba049c5d860d0b775b9e968cf9053a227861ae006f22e352884b5" \
  "PROJECTX_SOCIAL_PLATFORM_ID=0x3f695b2c32714e2359c4bb9515598d8dd765b216148c5b8fa818073d52b50f36" \
  "PROJECTX_SOCIAL_REGISTRY_ID=0x1a3fb4ac25458d7524be064a2b7e1586ccd9ed09c0d5b351621e3b101e1203a0" \
  "PROJECTX_SOCIAL_AGENT_COIN_TYPE=0x2::sui::SUI" \
  "PROJECTX_SOCIAL_AGENT_BASE_URL=https://weir.social" \
  "PROJECTX_SOCIAL_GRPC_URL=https://fullnode.mainnet.sui.io:443" \
  "WEIR_BASE_URL=https://weir.social" \
  "WEIR_AGENT_POLICY=$LABS_OPT/policy.json"; do
  grep -q "^${line%%=*}=" "$ENV_FILE" || printf '%s\n' "$line" >> "$ENV_FILE"
done
chmod 600 "$ENV_FILE"

# The signer's ceiling. Written once, against THIS citizen's address: a policy naming another
# address authorises nothing here and would refuse every write it is asked to sign.
if [ ! -f "$LABS_OPT/policy.json" ]; then
  sed "s#__AGENT_ADDRESS__#$ADDRESS#g" "$HERE/pkg/policy.json.template" > "$LABS_OPT/policy.json"
  node -e "JSON.parse(require('fs').readFileSync('$LABS_OPT/policy.json','utf8'))" || die "the policy did not come out as JSON"
  say "policy: $LABS_OPT/policy.json for $ADDRESS"
else
  say "policy: $LABS_OPT/policy.json exists; not replaced"
fi
say "address: $ADDRESS"

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
# Stand somewhere that outlives any install: node exits on process.cwd() if the directory it was
# started in has been deleted, and the download folder is deleted on every re-run.
cd "\$LABS_HOME" || exit 2
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
# labs is Go, and Go resolves names itself from /etc/resolv.conf. Android has no such file, so Go
# falls back to [::1]:53, where nothing listens, and every call to the gateway fails with "network
# is unreachable" while curl on the same phone works. proot shows the process Termux's own
# resolv.conf at the path Go reads. No root.
proot -b "$PREFIX/etc/resolv.conf:/etc/resolv.conf" $PREFIX/bin/labs agent --no-color -m "\$BEAT_MESSAGE"
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
cd "$LABS_HOME" || exit 2
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
# Every absolute path in the template is a Linux host's: the workspace, the node binary, and
# /opt/labs, which holds the MCP server and mcp.env. Termux has none of them at those paths, and
# a config naming a file that is not there fails at the first waking with "no such file".
sed -e "s#__WORKSPACE__#$WORKSPACE#g" \
    -e "s#/usr/bin/node#$NODE_BIN#g" \
    -e "s#/opt/labs#$LABS_OPT#g" \
    "$HERE/pkg/config.json" > "$LABS_HOME/config.json"
# Anchored to the opening quote. A correct value is "$PREFIX/opt/labs/...", which still CONTAINS
# the string /opt/labs — an unanchored check here fails on the config it just wrote correctly.
grep -q '"/opt/labs' "$LABS_HOME/config.json" && die "config.json still names a bare /opt/labs after substitution"
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

# Point every skill at this device. The adoption skills IMPORT from an absolute path, and an
# import specifier is fixed text: no environment variable reaches it, and the agent's exec tool
# may not pass one through anyway. So the path is written into the file. Anchored to the quote
# that opens it, so a second install finds nothing left to replace instead of nesting the prefix.
for f in "$WORKSPACE"/skills/*.mjs "$WORKSPACE"/skills/adoption/*.mjs; do
  [ -f "$f" ] || continue
  sed -i -e "s#'/opt/labs#'$LABS_OPT#g" -e "s#'/opt' + '/labs'#'$LABS_OPT'#g" "$f"
  node --check "$f" || die "$(basename "$f") no longer parses after pointing it at $LABS_OPT"
done
if grep -l "'/opt/labs" "$WORKSPACE"/skills/*.mjs "$WORKSPACE"/skills/adoption/*.mjs 2>/dev/null; then
  die "a skill above still imports from /opt/labs"
fi
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
