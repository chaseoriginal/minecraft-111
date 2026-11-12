#!/usr/bin/env bash
# Approve / revoke players on the minecraft-111 server.
#
#   ./mc-whitelist.sh add <java-name>        approve a Java Edition player
#   ./mc-whitelist.sh add <bedrock-tag>      approve a Bedrock Edition player
#   ./mc-whitelist.sh adduuid <uuid>        approve by UUID (either edition)
#   ./mc-whitelist.sh remove <name>          revoke a player
#   ./mc-whitelist.sh list                   show the whitelist
#   ./mc-whitelist.sh ops                    show operators
#   ./mc-whitelist.sh op <name>             grant operator (also bypasses the whitelist)
#   ./mc-whitelist.sh deop <name>            revoke operator
#   ./mc-whitelist.sh pending                show recent blocked join attempts
#   ./mc-whitelist.sh watch                  tail join attempts live
#
# ALL of this runs on the server over the console pipe, so you never need to
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

set -euo pipefail

HOST="${MC_HOST:-10.77.111.10}"
CONTAINER="${MC_CONTAINER:-minecraft}"
SSH_USER="${MC_SSH_USER:-ladmin}"

# Run a server console command and echo the server's reply.
console() {
  ssh -o BatchMode=yes "${SSH_USER}@${HOST}" \
    "sudo -n docker exec -u 1000 ${CONTAINER} mc-send-to-console \"\$1\" >/dev/null 2>&1; sleep 3; \
     sudo -n docker logs --since 8s ${CONTAINER} 2>&1 | grep -viE '^\[mc-image-helper\]|Registered ext|Prepared spawn|Starting remote control'" \
    bash "$1" 2>/dev/null | tail -6
}

usage() {
  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

cmd="${1:-}"
[ -n "$cmd" ] || usage

case "$cmd" in
  add)
    [ $# -eq 2 ] || usage
    target="$2"
    echo "Approving '${target}'..."
    # Java profile name -> resolved to a UUID by the server.
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
  watch)
    ssh -o BatchMode=yes "${SSH_USER}@${HOST}" \
      "sudo -n docker logs -f ${CONTAINER} 2>&1 | \
       grep --line-buffered -iE 'UUID of player|not white-listed|Game profile not found|Unable to find user in our cache'" || true
    ;;
  *)
    usage
    ;;
esac
