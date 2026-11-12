#!/usr/bin/env bash
# Approve or revoke players on the minecraft-111 server.
#
#   ./mc-whitelist.sh add <name-or-gamertag>   approve a player
#   ./mc-whitelist.sh remove <name>            revoke a player
#   ./mc-whitelist.sh list                     show the whitelist
#   ./mc-whitelist.sh pending                  show unapproved join attempts
#   ./mc-whitelist.sh watch                    tail join attempts live
#
# Java players: pass their Java Edition profile name.
# Bedrock players: pass their Xbox gamertag (WITHOUT the Floodgate "." prefix).
#   The script detects which is which: if the name has never joined a Geyser
#   server it cannot resolve the gamertag, so use `pending` to look up the
#   Floodgate UUID that the server logged for them.
#
# Everything runs on the server over RCON, so the operator never needs to be
# in-game to approve someone.

set -euo pipefail

HOST="${MC_HOST:-10.77.111.10}"
CONTAINER="${MC_CONTAINER:-minecraft}"
SSH_USER="${MC_SSH_USER:-ladmin}"

rcon() {
  ssh -o BatchMode=yes "${SSH_USER}@${HOST}" \
    "sudo -n docker exec -u 1000 ${CONTAINER} mc-send-to-console \"\$1\"" bash "$1"
}

usage() {
  sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

cmd="${1:-}"
[ -n "$cmd" ] || usage

case "$cmd" in
  add)
    [ $# -eq 2 ] || usage
    target="$2"
    # Bedrock names need the Floodgate prefix on the Java side. Floodgate
    # exposes /fwhitelist which resolves the gamertag via the GeyserMC API.
    echo "Approving '${target}'..."
    rcon "whitelist add ${target}" || true
    rcon "fwhitelist add ${target}" || true
    echo "--- current whitelist ---"
    rcon "whitelist list" || true
    ;;
  remove)
    [ $# -eq 2 ] || usage
    rcon "whitelist remove $2" || true
    rcon "fwhitelist remove $2" || true
    ;;
  list)
    rcon "whitelist list" || true
    ;;
  pending)
    # Players who tried to join while not whitelisted. Paper logs the
    # Bedrock/Floodgate UUID of the attempt; the gamertag is prefixed with "."
    # by Floodgate, so strip it to get the Xbox gamertag for /fwhitelist.
    echo "Recent join attempts by players who are not whitelisted:"
    ssh -o BatchMode=yes "${SSH_USER}@${HOST}" \
      "sudo -n docker logs --since 24h ${CONTAINER} 2>&1 | \
       grep -iE 'UUID of player|not white-listed|Game profile not found' | tail -40" || true
    echo
    echo "Tip: a Bedrock player appears as '.Gamertag' in the log."
    echo "Use:  ./mc-whitelist.sh add Gamertag"
    ;;
  watch)
    ssh -o BatchMode=yes "${SSH_USER}@${HOST}" \
      "sudo -n docker logs -f ${CONTAINER} 2>&1 | \
       grep --line-buffered -iE 'UUID of player|not white-listed|Game profile not found'" || true
    ;;
  *)
    usage
    ;;
esac
