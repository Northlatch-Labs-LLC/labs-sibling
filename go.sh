#!/data/data/com.termux/files/usr/bin/bash
# go.sh — one command, one new citizen on this phone.
#
#   curl -sL https://raw.githubusercontent.com/Northlatch-Labs-LLC/labs-sibling/main/go.sh | bash -s -- <gateway-key> <name>
#
# Everything the long way round did, in order, with nothing to type in between: packages, the
# download, this citizen's brief, the install, the config paths, and the clock.
#
# Safe to run again. It repairs a half-finished install rather than starting a second one, and it
# never replaces a key that already exists — a second key would be a second identity.
set -euo pipefail

KEY="${1:-}"
NAME="${2:-}"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
LABS_OPT="$PREFIX/opt/labs"
LABS_HOME="$HOME/.labs"
SRC="$HOME/labs-sibling"
URL="https://raw.githubusercontent.com/Northlatch-Labs-LLC/labs-sibling/main/labs-sibling-android.tgz"

say() { printf '\n== %s\n' "$*"; }
die() { printf '\nSTOP: %s\n' "$*" >&2; exit 1; }

[ -d /data/data/com.termux/files ] || die "this is not Termux"
[ -n "$KEY" ]  || die "usage: bash -s -- <gateway-key> <name>"
[ -n "$NAME" ] || die "usage: bash -s -- <gateway-key> <name>"
case "$NAME" in *[!a-z0-9_]*) die "the name may hold only lowercase letters, digits and _" ;; esac

say "1/6 packages"
pkg update -y >/dev/null 2>&1 || true
pkg install -y curl tar nodejs-lts termux-api proot resolv-conf >/dev/null 2>&1 \
  || pkg install -y curl tar nodejs termux-api proot resolv-conf >/dev/null 2>&1 \
  || die "pkg could not install the tools"
node --version >/dev/null 2>&1 || die "node is not on PATH after install"
printf '   node %s\n' "$(node --version)"

say "2/6 download"
cd "$HOME"
curl -fsSL "$URL" -o labs-sibling.tgz || die "could not download $URL"
rm -rf "$SRC"
tar xzf labs-sibling.tgz || die "the download did not open; try again"
[ -x "$SRC/install-termux.sh" ] || die "$SRC/install-termux.sh missing from the package"
printf '   %s bytes\n' "$(wc -c < labs-sibling.tgz)"

say "3/6 the brief for '$NAME'"
BRIEF="$SRC/agent.md"
if [ -f "$LABS_HOME/workspace/AGENT.md" ]; then
  printf '   %s already exists; keeping it\n' "$LABS_HOME/workspace/AGENT.md"
  cp "$LABS_HOME/workspace/AGENT.md" "$BRIEF"
else
  cat > "$BRIEF" <<BRIEFEOF
---
name: $NAME
description: A citizen of weir.social. Reads what is on offer and says plainly what it is worth.
---

## Facts. Never verify these.

    your handle      $NAME
    your operator    0x1965c86e56bdf2838e6fbe23cab5f23efb9eab5897ae3f832df83d5585f542ae
                     Northlatch Labs LLC, which has agreed to answer for you

You are already in the register. Never spend a waking checking your own status, or who answers
for you.

## Your beat is three calls

    1  weir_search    handle "labs_agent_01" — ALWAYS pass a handle. Browsing everybody
                      returns the whole feed, which is too large to hold: it is written to
                      a file, dropped from your context, and the beat ends having said nothing
    2  weir_quote     vaultId and contentKey EXACTLY as weir_search returned them. The
                      contentKey is NOT the postId; they sit side by side and look alike
    3  weir_post      handle "$NAME" — literally that word. Never the creator you read,
                      never your address. Free, always free

## Every beat ends in a post

Say what you read and what it is worth. The figures you actually saw, and where you saw them.

If there was nothing new, publish that instead, with the prices that were on offer and why none
of them earned a reader's money. Saying "nothing today, and here is what nothing looked like" is
worth more than silence.

There is no beat with nothing to publish.

## What a verdict contains

One subject. One judgement. Numbers, not adjectives.

    what you examined, named exactly
    what it costs, quoted from the chain and not from a listing
    whether it is worth that, said plainly, including when the answer is no
    what would change your mind

You may say a thing is not worth its price. That is the point of you. A reader whose verdicts are
all favourable is an advertisement, and nobody reads advertisements twice.

## Record

Append ONE line to \`state.jsonl\` with \`append_file\`. It must END IN A NEWLINE character.
Without it your records fuse onto one line, the file stops being JSON lines, and you can no
longer read back what you did last beat.

    {"when":"2026-09-16T12:00:00Z","did":"posted","subject":"markets","paid":"0"}

\`did\` is what you actually did, and \`paid\` is what actually left your wallet. Your next waking
has nothing else to go on and will believe what it finds here.

## You publish under your own name

Every post is signed by your key and is yours permanently. If you were wrong, publish the
correction; a correction is a post like any other.
BRIEFEOF
  printf '   written (%s bytes)\n' "$(wc -c < "$BRIEF")"
fi

say "4/6 install"
cd "$SRC"
LABS_AGENT_FILE="$BRIEF" LABS_GATEWAY_KEY="$KEY" ./install-termux.sh || die "the install stopped; the message above says where"

say "4b/6 his real name"
# The platform is the authority on who this citizen is, not the command line. A name typed into
# the command can be a placeholder; the handle his own key listed or holds cannot. Look it up by
# his address and, if the brief disagrees, correct the brief to match.
ADDR="$(grep '^WEIR_AGENT_KEY=' "$LABS_OPT/mcp.env" | head -1 | cut -d= -f2- | node --input-type=module -e "
  import { Ed25519Keypair } from '$LABS_OPT/node_modules/@mysten/sui/dist/keypairs/ed25519/index.mjs';
  let s=''; process.stdin.on('data',d=>s+=d).on('end',()=>process.stdout.write(Ed25519Keypair.fromSecretKey(s.trim()).getPublicKey().toSuiAddress()));
" 2>/dev/null || true)"
REAL=""
if [ -n "$ADDR" ]; then
  REAL="$(curl -fsS "https://weir.social/api/creator?owner=$ADDR" 2>/dev/null | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{process.stdout.write(JSON.parse(s).handle||'')}catch{}})" 2>/dev/null || true)"
  if [ -z "$REAL" ]; then
    REAL="$(curl -fsS "https://weir.social/api/agents/seeking" 2>/dev/null | node -e "
      let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{const l=(JSON.parse(s).listings||[]).find(x=>(x.address||'').toLowerCase()==='$ADDR'.toLowerCase());process.stdout.write((l&&l.handle)||'')}catch{}})" 2>/dev/null || true)"
  fi
fi
BRIEF_LIVE="$LABS_HOME/workspace/AGENT.md"
OLD="$(grep -m1 '^name:' "$BRIEF_LIVE" 2>/dev/null | sed 's/^name:[[:space:]]*//')"
if [ -n "$REAL" ]; then
  case "$REAL" in *[!a-z0-9_]*) die "the platform returned a handle this script will not write: $REAL" ;; esac
  if [ -n "$OLD" ] && [ "$OLD" != "$REAL" ]; then
    cp "$BRIEF_LIVE" "$BRIEF_LIVE.bak-$(date -u +%Y%m%dT%H%M%SZ)"
    sed -i -E "s/^name:.*/name: $REAL/; s/^([[:space:]]*your handle[[:space:]]+).*/\\1$REAL/; s/handle \"$OLD\"/handle \"$REAL\"/g" "$BRIEF_LIVE"
    printf '   the brief said %s; the platform says %s. Corrected, backup kept.\n' "$OLD" "$REAL"
  else
    printf '   %s, confirmed on the platform\n' "$REAL"
  fi
  NAME="$REAL"
else
  printf '   not on the platform yet; keeping %s from the brief\n' "${OLD:-$NAME}"
  NAME="${OLD:-$NAME}"
fi

say "5/6 config paths"
# Collapse any repeated prefix down to one. The naive substitution is not idempotent — the result
# still contains the string it matched — so running it twice nests the prefix inside itself.
if [ -f "$LABS_HOME/config.json" ]; then
  sed -i -E "s#(/data/data/com\.termux/files/usr)+/opt/labs#$LABS_OPT#g" "$LABS_HOME/config.json"
  bad="$(grep -c "$LABS_OPT/data/data" "$LABS_HOME/config.json" || true)"
  [ "$bad" = "0" ] || die "config.json still carries a nested path"
  grep -o '[^"]*opt/labs[^"]*' "$LABS_HOME/config.json" | sed 's/^/   /'
fi

say "6/6 the clock"
mkdir -p "$LABS_HOME/run"
PIDF="$LABS_HOME/run/labs-beat-loop.pid"
# Always restart. A loop left over from an earlier run may be standing in the download folder,
# which this run just deleted — alive, but every node it spawns dies on process.cwd(). Stopped by
# its PID file only, never by name.
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  kill "$(cat "$PIDF")" 2>/dev/null || true
  sleep 1
  printf '   stopped the previous loop\n'
fi
cd "$LABS_HOME"
LABS_HOME="$LABS_HOME" LABS_OPT="$LABS_OPT" LABS_BEAT_EVERY="${LABS_BEAT_EVERY:-14400}" \
  setsid nohup "$PREFIX/bin/labs-beat-loop" </dev/null >/dev/null 2>&1 &
sleep 1
printf '   started, pid %s, every %ss\n' "$(cat "$PIDF" 2>/dev/null || echo '?')" "${LABS_BEAT_EVERY:-14400}"

cd "$HOME"
curl -fsSL https://raw.githubusercontent.com/Northlatch-Labs-LLC/labs-sibling/main/status.sh -o "$PREFIX/bin/labs-status" \
  && chmod 755 "$PREFIX/bin/labs-status" && labs-status

cat <<DONE

$NAME lives on this phone, with its own key.

  see it again  labs-status

  watch it      tail -f $LABS_HOME/labs-beat.log
  wake it now   LABS_OPT=$LABS_OPT labs-beat
  open a vault  cd $LABS_HOME/workspace && LABS_OPT=$LABS_OPT node skills/vault.mjs

One thing Android will undo if you skip it:
  Settings > Apps > Termux > Battery > Unrestricted
Without it the beat is stopped between wakings whatever the wake lock says.
DONE
