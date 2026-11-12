#!/usr/bin/env bash
# Approve / revoke players on the minecraft-111 server.
#
#   ./mc-whitelist.sh add <name>        approve a player (Java name or Xbox gamertag)
#   ./mc-whitelist.sh adduuid <uuid>    approve by UUID (either edition)
#   ./mc-whitelist.sh remove <name>     revoke a player
#   ./mc-whitelist.sh list              show the whitelist
#   ./mc-whitelist.sh ops               show operators
#   ./mc-whitelist.sh op <name>         grant operator (also bypasses the whitelist)
#   ./mc-whitelist.sh deop <name>       revoke operator
#   ./mc-whitelist.sh pending           show recent blocked join attempts
#   ./mc-whitelist.sh watch             tail join attempts live
#   ./mc-whitelist.sh approve-pending   approve every blocked attempt in the log
#
# Everything here runs server-side over the console pipe, so you never need to
# be in-game to approve someone. The console is reachable even when the
# whitelist would otherwise lock you out.
#
# Java Edition : pass the Java profile name (NOT the Xbox gamertag).
#                 The server resolves it to a UUID via PlayerDB/Mojang.
# Bedrock      : pass the Xbox gamertag WITHOUT the Floodgate "." prefix.
#                 Floodgate looks the XUID up via the GeyserMC API, which only
#                 knows accounts that have already connected to a Geyser server.
#                 If that lookup fails, use `adduuid` with the Floodgate UUID
#                 (the UUID the server logged for that player).
#
# Unknown names: you do NOT need to know a name in advance. A player who tries
# to connect and is refused is logged with their UUID - run `pending` to see it,
# then `adduuid <uuid>` to approve them.

set -euo pipefail

HOST="${MC_HOST:-10.77.111.10}"
CONTAINER="${MC_CONTAINER:-minecraft}"
SSH_USER="${MC_SSH_USER:-ladmin}"

# Run a server console command and print what the server said back.
#
# The command is piped to the REMOTE shell on stdin (not interpolated into the
# command line) so spaces and quotes in it survive intact. The reply is
# filtered LOCALLY: the fleet's SSH login banner is printed on the remote
# shell's stdout before the command output, so it cannot be filtered remotely.
console() {
  local cmd="$1"
  printf '%s\n' "$cmd" | ssh -o BatchMode=yes "${SSH_USER}@${HOST}" \
    'read -r CMD
     sudo -n docker exec -u 1000 '"${CONTAINER}"' mc-send-to-console "$CMD" >/dev/null 2>&1
     sleep 3
     sudo -n docker logs --since 12s '"${CONTAINER}"' 2>&1' 2>/dev/null \
    | grep -E '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}' \
    | grep -viE 'Prepared spawn|Registered ext|Starting remote control|Loading libraries|Starting minecraft server' \
    | tail -8
}

usage() {
  sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

cmd="${1:-}"
[ -n "$cmd" ] || usage

case "$cmd" in
  add)
    [ $# -eq 2 ] || usage
    target="$2"
    echo "Approving '${target}'..."
    # Java profile name -> resolved to a UUID by the server (PlayerDB/Mojang).
    console "whitelist add ${target}" || true
    # Xbox gamertag -> resolved to the Floodgate UUID by Floodgate.
    console "fwhitelist add ${target}" || true
    echo
    echo "--- whitelist now ---"
    console "whitelist list" || true
    ;;
  adduuid)
    [ $# -eq 2 ] || usage
    console "whitelist add ${2}" || true
    echo "--- whitelist now ---"
    console "whitelist list" || true
    ;;
  remove)
    [ $# -eq 2 ] || usage
    console "whitelist remove $2" || true
    console "fwhitelist remove $2" || true
    ;;
  list)
    console "whitelist list" || true
    ;;
  ops)
    console "op" || true
    ;;
  op)
    [ $# -eq 2 ] || usage
    console "op $2" || true
    echo "Note: operators bypass the whitelist entirely."
    ;;
  deop)
    [ $# -eq 2 ] || usage
    console "deop $2" || true
    ;;
  pending)
    # Players who tried to connect and were refused. Paper logs the UUID it
    # resolved for the attempt; for Bedrock the name arrives prefixed with "."
    # by Floodgate.
    echo "Recent blocked join attempts (last 24h):"
    ssh -o BatchMode=yes "${SSH_USER}@${HOST}" \
      "sudo -n docker logs --since 24h ${CONTAINER} 2>&1 | \
       grep -iE 'UUID of player|not white-listed|white-listed on this server|Game profile not found|Unable to find user in our cache' | tail -40" || true
    echo
    echo "Tip: a Bedrock player shows as '.Gamertag'. Strip the dot and use:"
    echo "  ./mc-whitelist.sh add Gamertag"
    echo "If Floodgate cannot resolve the tag (player has never joined any"
    echo "Geyser server), copy the UUID from the log and use:"
    echo "  ./mc-whitelist.sh adduuid <uuid>"
    ;;
  approve-pending)
    # Approve every UUID the server logged for a refused join attempt.
    uuids=$(ssh -o BatchMode=yes "${SSH_USER}@${HOST}" \
      "sudo -n docker logs --since 24h ${CONTAINER} 2>&1 | \
       grep -oiE 'UUID of player .* is [0-9a-fA-F-]{36}' | grep -oE '[0-9a-fA-F-]{36}' | sort -u" || true)
    if [ -z "$uuids" ]; then
      echo "No blocked join attempts found in the last 24h."
      exit 0
    fi
    echo "$uuids" | while read -r u; do
      [ -n "$u" ] || continue
      echo "--- approving $u"
      console "whitelist add $u" || true
    done
    echo
    echo "--- whitelist now ---"
    console "whitelist list" || true
    ;;
  watch)
    ssh -o BatchMode=yes "${SSH_USER}@${HOST}" \
      "sudo -n docker logs -f ${CONTAINER} 2>&1 | \
       grep --line-buffered -iE 'UUID of player|not white-listed|Game profile not found|Unable to find user in our cache'" || true
    ;;
  *)
    usage
    ;;
esac
