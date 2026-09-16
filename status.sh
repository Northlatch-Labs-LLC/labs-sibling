#!/data/data/com.termux/files/usr/bin/bash
# labs-status — who this citizen is and whether it is alive. Prints no secret.
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
OPT="$PREFIX/opt/labs"
HOME_L="$HOME/.labs"
echo
echo "== address"
if [ -f "$OPT/mcp.env" ]; then
  grep '^WEIR_AGENT_KEY=' "$OPT/mcp.env" | head -1 | cut -d= -f2- | node --input-type=module -e "
    import { Ed25519Keypair } from '$OPT/node_modules/@mysten/sui/dist/keypairs/ed25519/index.mjs';
    let s=''; process.stdin.on('data',d=>s+=d).on('end',()=>{
      try { console.log('   ' + Ed25519Keypair.fromSecretKey(s.trim()).getPublicKey().toSuiAddress()); }
      catch (e) { console.log('   the key did not read: ' + e.message); }
    });" 2>&1
else
  echo "   no key yet: $OPT/mcp.env is missing"
fi
echo "== handle"
grep -m1 '^name:' "$HOME_L/workspace/AGENT.md" 2>/dev/null | sed 's/^name:/  /' || echo "   no AGENT.md"
echo "== clock"
PIDF="$HOME_L/run/labs-beat-loop.pid"
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "   running, pid $(cat "$PIDF")"
else
  echo "   NOT running"
fi
echo "== last wakings"
tail -6 "$HOME_L/labs-beat.log" 2>/dev/null | sed 's/^/   /' || echo "   no log yet"
echo
