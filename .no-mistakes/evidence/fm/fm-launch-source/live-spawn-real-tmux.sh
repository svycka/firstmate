#!/usr/bin/env bash
# Live driver: run a real bin/fm-spawn.sh (secondmate, codex harness) against a
# REAL tmux server on a private socket. The pane shell is deliberately slow to
# start (sleep before exec bash) so the typed launch text queues in the tty's
# canonical line buffer, the condition issue #4559 describes.
# Usage: live-spawn-real-tmux.sh <repo-root> <label> [startup-delay-seconds]
set -u
ROOT=$1; LABEL=$2; DELAY=${3:-4}
# PANE_CMD: the pane shell. Default: busy for DELAY seconds before bash starts.
# busyread mode: the pane consumes and runs the first typed line (export GOTMPDIR)
# in canonical mode, then stays busy for DELAY seconds, like a shell still
# finishing startup work after reading its first command.
if [ "${MODE:-sleep}" = busyread ]; then PANE_CMD="IFS= read -r l; eval \"\$l\"; sleep $DELAY; exec /bin/bash --norc --noprofile"; else PANE_CMD="sleep $DELAY; exec /bin/bash --norc --noprofile"; fi
REAL_TMUX=$(command -v tmux)
W=$(mktemp -d /tmp/fm-live-4559.XXXXXX); W=$(cd -P "$W" && pwd -P)
SOCK="fm-live-4559-$$"
ID="lv$$"
cleanup() { "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1; rm -rf "$W" "/tmp/fm-$ID"; }
trap cleanup EXIT
FB="$W/fakebin"; mkdir -p "$FB"
cat > "$FB/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" -f /dev/null "\$@"
SH
cat > "$FB/codex" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$W/codex-argv"
printf 'argc=%s\n' "\$#" >> "$W/codex-argv"
printf 'FAKE-CODEX-STARTED\n❯ \n'
exec sleep 600
SH
chmod +x "$FB/tmux" "$FB/codex"
export PATH="$FB:$PATH"
unset TMUX HERDR_ENV NO_MISTAKES_GATE  # isolated test fleet, not the gate agent
export FM_BACKEND=tmux FM_GATE_REFUSE_BYPASS=1
PAD=$(printf "long-secondmate-home-path-segment-%.0s" 1 2 3 4 5 6); HOME_DIR="$W/home"; SUB="$W/$PAD/$PAD/sub"; mkdir -p "$W/$PAD/$PAD"
mkdir -p "$HOME_DIR/projects" "$HOME_DIR/data" "$HOME_DIR/state"
git init -q "$HOME_DIR/projects/alpha" && git -C "$HOME_DIR/projects/alpha" -c user.name=t -c user.email=t@e commit -q --allow-empty -m init
git init -q --bare "$W/alpha.git"; git -C "$HOME_DIR/projects/alpha" remote add origin "$W/alpha.git"; git -C "$HOME_DIR/projects/alpha" push -q origin HEAD 2>/dev/null
echo '- alpha [direct-PR] - alpha project (added 2026-06-22)' > "$HOME_DIR/data/projects.md"
FM_HOME="$HOME_DIR" FM_SECONDMATE_CHARTER='live 4559 charter' "$ROOT/bin/fm-brief.sh" "$ID" --secondmate alpha >/dev/null || { echo "brief failed"; exit 2; }
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-home-seed.sh" "$ID" "$SUB" alpha >/dev/null || { echo "seed failed"; exit 2; }
tmux new-session -d -s firstmate -x 220 -y 60 "$PANE_CMD"
tmux set-option -g default-command "$PANE_CMD"
# PRE: pre-plant /tmp/fm-<id> before spawn: world (0777 dir), symlink (to a dir
# another path controls), owned755 (own dir, too-open mode).
case "${PRE:-}" in
  world) mkdir "/tmp/fm-$ID"; chmod 777 "/tmp/fm-$ID"; echo "pre-planted: $(stat -f '%Sp' /tmp/fm-$ID) /tmp/fm-$ID" ;;
  symlink) mkdir "$W/attacker"; chmod 777 "$W/attacker"; ln -s "$W/attacker" "/tmp/fm-$ID"; echo "pre-planted: symlink /tmp/fm-$ID -> $W/attacker" ;;
  owned755) mkdir "/tmp/fm-$ID"; chmod 755 "/tmp/fm-$ID"; echo "pre-planted: $(stat -f '%Sp' /tmp/fm-$ID) /tmp/fm-$ID" ;;
esac
echo "== [$LABEL] fm-spawn.sh $ID <subhome> codex --secondmate (pane mode=${MODE:-sleep}, busy ${DELAY}s)"
start=$(date +%s)
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-spawn.sh" "$ID" "$SUB" codex --secondmate > "$W/spawn.out" 2>&1
rc=$?
echo "spawn rc=$rc after $(( $(date +%s) - start ))s"; tail -5 "$W/spawn.out" | sed 's/^/  spawn: /'
i=0; while [ $i -lt 150 ] && [ ! -s "$W/codex-argv" ]; do sleep 0.1; i=$((i+1)); done
if [ -f "/tmp/fm-$ID/launch.sh" ]; then
  echo "staged file: $(stat -f '%Sp %Su' "/tmp/fm-$ID/launch.sh") size=$(wc -c < "/tmp/fm-$ID/launch.sh") bytes; task root: $(stat -f '%Sp' "/tmp/fm-$ID")"
else
  echo "staged file: none (launch typed directly)"
fi
grep -o 'FM_HOME=[^ ]* [^;]*codex' "$HOME_DIR/state/$ID.meta" >/dev/null 2>&1
echo "--- pane capture (window fm-$ID) ---"
tmux capture-pane -p -J -t "firstmate:fm-$ID" -S -40 | sed '/^$/d' | cut -c1-300 | tail -15
echo "--- result ---"
if [ -s "$W/codex-argv" ]; then echo "AGENT STARTED: fake codex ran with $(tail -1 "$W/codex-argv"); argv bytes=$(wc -c < "$W/codex-argv")"; else echo "AGENT DID NOT START"; fi
echo "pending command-line bytes in pane (last line of joined capture): $(tmux capture-pane -p -J -t "firstmate:fm-$ID" -S -40 | sed '/^$/d' | tail -1 | wc -c)"
echo "pane foreground: $(tmux display-message -p -t "firstmate:fm-$ID" '#{pane_current_command}' 2>&1)"
[ "${PRE:-}" = symlink ] && echo "attacker dir contents: [$(ls -A "$W/attacker")]"
if [ "${TEARDOWN:-0}" = 1 ]; then
  echo "--- teardown ---"
  FM_HOME="$HOME_DIR" "$ROOT/bin/fm-teardown.sh" "$ID" --force > "$W/td.out" 2>&1; echo "teardown rc=$?"; tail -3 "$W/td.out" | cut -c1-300 | sed 's/^/  teardown: /'
  if [ -e "/tmp/fm-$ID" ]; then echo "task temp root STILL PRESENT: $(ls -la /tmp/fm-$ID)"; else echo "task temp root /tmp/fm-$ID removed (launch.sh gone)"; fi
fi
