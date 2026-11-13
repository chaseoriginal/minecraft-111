#!/usr/bin/env bash
# Approve / revoke players on a Minecraft server (Paper + Geyser/Floodgate).
#
#   ./mc-whitelist.sh add <name>        approve a player (Java name or Xbox gamertag)
#   ./mc-whitelist.sh adduuid <uuid>    approve a Java player whose UUID you know
#   ./mc-whitelist.sh remove <name>     revoke a player
#   ./mc-whitelist.sh list              show the whitelist
#   ./mc-whitelist.sh ops               show operators (read from ops.json)
#   ./mc-whitelist.sh op <name>         grant operator to a JAVA player
#   ./mc-whitelist.sh opbedrock <tag>   grant operator to a BEDROCK player
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
#
# VERIFIED BEHAVIOUR ON Paper 26.3 + Geyser 2.12.1 + Floodgate 2.2.5:
#
#   * `/whitelist add <name>`      works for a Java profile name.
#   * `/whitelist add <uuid>`      REFUSED - "That player does not exist".
#                                  Paper resolves the argument as a NAME only.
#                                  Use the profile name, or let this script
#                                  recover the name from the server log.
#   * `/fwhitelist add <gamertag>` works ONLY for an account that has already
#                                  connected to a Geyser server. A player who
#                                  has NEVER joined fails with "Unable to find
#                                  user in our cache" - they must attempt to
#                                  connect once first (the attempt is refused,
#                                  but it registers their Xbox account).
#   * `/fwhitelist add <uuid>`     works for a Floodgate UUID.
#   * `/op <name>`                 works for a Java profile name.
#   * `/op <gamertag>`             REFUSED - "That player does not exist".
#   * `/op` (no argument)         REFUSED - "Unknown or incomplete command".
#                                  Read /data/ops.json instead.
#   * `/fop`                       DOES NOT EXIST in Floodgate 2.2.5. Floodgate
#                                  registers only `fwhitelist`. A Bedrock
#                                  operator status must therefore come from
#                                  ops.json, which Paper reads at STARTUP -
#                                  so it needs a restart to take effect.
#                                  `opbedrock` does the whole job: resolve the
#                                  Floodgate UUID, add it to the git-tracked
#                                  ops seed, push, redeploy and restart.
#
# THE NEW-PLAYER LOOP (you do not need to know any name in advance):
#
#   1. The player tries to connect and is refused.
#   2. Run `./mc-whitelist.sh pending` - it lists every refused attempt with
#      the name and the UUID the server resolved.
#   3. Run `./mc-whitelist.sh approve-pending` to approve them all at once,
#      or `./mc-whitelist.sh add <name>` for one of them.
#   4. For a BEDROCK player who is completely new, their first (refused)
#      attempt is what puts them in Floodgate's cache, so `add <gamertag>`
#      only succeeds on the SECOND try - i.e. after one refused attempt.

set -euo pipefail

HOST="${MC_HOST:-10.77.111.10}"
CONTAINER="${MC_CONTAINER:-minecraft}"
SSH_USER="${MC_SSH_USER:-ladmin}"
REPO="${MC_REPO:-/home/ladmin/minecraft-111}"
PTR_HOST="${MC_PTR_HOST:-10.77.110.10}"
PTR_STACK="${MC_PTR_STACK:-41}"
PTR_ENDPOINT="${MC_PTR_ENDPOINT:-6}"

# The server's real refusal wording is "You are not whitelisted on this
# server!" - NO hyphen. Matching "not white-listed" finds NOTHING (0 of 10
# real events in the log), which silently makes pending/approve-pending blind.
REFUSED_RE='not whitelisted|UUID of player|Unable to find user in our cache'

# Run a server console command and print what the server said back.
#
# The command is piped to the REMOTE shell on stdin (not interpolated into
# the command line) so spaces and quotes in it survive intact. The reply is
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

# Read a JSON file out of the running container.
container_json() {
  ssh -o BatchMode=yes "${SSH_USER}@${HOST}" \
    "sudo -n docker exec ${CONTAINER} cat '$1'" 2>/dev/null
}

# All refused-join lines from the log.
refused_lines() {
  ssh -o BatchMode=yes "${SSH_USER}@${HOST}" \
    "sudo -n docker logs --since 24h ${CONTAINER} 2>&1 | grep -iE '${REFUSED_RE}' | tail -60" 2>/dev/null || true
}

# Recover the Java profile name the server logged for a UUID.
# The login listener logs "UUID of player <name> is <uuid>".
name_for_uuid() {
  local uuid="$1"
  ssh -o BatchMode=yes "${SSH_USER}@${HOST}" \
    "sudo -n docker logs --since 72h ${CONTAINER} 2>&1 \
     | grep -oiE 'UUID of player [^ ]+ is ${uuid}' \
     | sed -E 's/UUID of player (.*) is .*/\1/' | tail -1" 2>/dev/null || true
}

# Resolve a Bedrock gamertag to its Floodgate UUID by whitelisting it and
# reading back whitelist.json. Floodgate stores it as
# 00000000-0000-0000-0009-01<hex xuid>.
floodgate_uuid_for_tag() {
  local tag="$1"
  console "fwhitelist add ${tag}" >/dev/null 2>&1 || true
  container_json /data/whitelist.json \
    | python3 -c "
import json,sys
tag=sys.argv[1].lower()
for e in json.load(sys.stdin):
    n=(e.get('name') or '').lower()
    if n in (tag, '.'+tag) and e.get('uuid','').startswith('00000000-0000-0000-0009'):
        print(e['uuid']); break
" "$tag" 2>/dev/null || true
}

# Portainer access is over an SSH tunnel to 127.0.0.1:9443 on the Portainer
# host. NEVER use PUT /api/stacks/{id} on a git-backed stack - it detaches
# git. The safe routes are the git redeploy and the container restart.
portainer_tunnel() {
  local lp="$1"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ExitOnForwardFailure=yes \
      -N -f -L "${lp}:127.0.0.1:9443" "${SSH_USER}@${PTR_HOST}" 2>/dev/null
}

portainer_curl() {
  local lp="$1" method="$2" path="$3" data="${4:-}"
  local key
  key="$(cat "${HOME}/.hermes/secrets/portainer_api_key")"
  local args=(-sk -m 60 -X "$method" -H "X-API-KEY: ${key}")
  [ -n "$data" ] && args+=(-H 'Content-Type: application/json' --data-binary "$data")
  curl "${args[@]}" "https://127.0.0.1:${lp}${path}" -w '\nHTTP %{http_code}\n'
}

usage() {
  sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
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
    uuid="$2"
    # Paper refuses a bare UUID on /whitelist add, so recover the profile
    # name from the login log and approve by name.
    name="$(name_for_uuid "$uuid")"
    if [ -n "$name" ]; then
      echo "Recovered Java profile name '${name}' for ${uuid}"
      console "whitelist add ${name}" || true
    else
      echo "No name found in the log for ${uuid}."
      echo "Paper's /whitelist add only accepts a NAME, not a UUID."
      echo "If this is a Bedrock player, use: fwhitelist add <uuid>"
      console "fwhitelist add ${uuid}" || true
    fi
    echo
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
    # `/op` with no argument is not a command on Paper 26.3 - read the file.
    container_json /data/ops.json || true
    ;;
  op)
    [ $# -eq 2 ] || usage
    console "op $2" || true
    echo "Note: operators bypass the whitelist entirely."
    ;;
  opbedrock)
    [ $# -eq 2 ] || usage
    tag="$2"
    echo "Resolving Floodgate UUID for Bedrock gamertag '${tag}'..."
    fuuid="$(floodgate_uuid_for_tag "$tag")"
    if [ -z "$fuuid" ]; then
      echo "Could not resolve '${tag}'."
      echo "The player must have connected at least once so Floodgate knows"
      echo "the account. Check the gamertag spelling and try again."
      exit 1
    fi
    echo "Floodgate UUID: ${fuuid}"
    echo "Adding to ${REPO}/ops-seed.json and restarting the server..."
    python3 - "$REPO/ops-seed.json" "$fuuid" ".${tag}" <<'PYEOF'
import json, sys
path, uuid, name = sys.argv[1], sys.argv[2], sys.argv[3]
ops = json.load(open(path))
if not any(o.get("uuid") == uuid for o in ops):
    ops.append({"uuid": uuid, "name": name, "level": 4, "bypassesPlayerLimit": False})
    json.dump(ops, open(path, "w"), indent=2)
    open(path, "a").write("\n")
    print(f"seed updated: {name} {uuid}")
else:
    print(f"already in seed: {name} {uuid}")
PYEOF
    cd "$REPO"
    git add ops-seed.json
    git -c user.name='Chase' -c user.email='chase@echoinggreen.net' \
        commit -m "Grant ${tag} operator rights (Bedrock)" >/dev/null || true
    git push origin main >/dev/null 2>&1 || echo "push failed - run git push manually"
    echo "Redeploying stack ${PTR_STACK} from git, then restarting the server..."
    LP=19443
    if portainer_tunnel "$LP"; then
      portainer_curl "$LP" PUT \
        "/api/stacks/${PTR_STACK}/git/redeploy?endpointId=${PTR_ENDPOINT}" '{}' | tail -2
      # Restart the container so Paper reloads ops.json from disk.
      CID=$(curl -sk -m 25 -G -H "X-API-KEY: $(cat "${HOME}/.hermes/secrets/portainer_api_key")" \
        --data-urlencode 'all=1' \
        --data-urlencode "filters={\"label\":[\"com.docker.compose.project=minecraft-111\",\"com.docker.compose.service=minecraft\"]}" \
        "https://127.0.0.1:${LP}/api/endpoints/${PTR_ENDPOINT}/docker/containers/json" \
        | python3 -c "import json,sys;d=json.load(sys.stdin);print(d[0]['Id'] if d else '')" 2>/dev/null || true)
      if [ -n "$CID" ]; then
        portainer_curl "$LP" POST \
          "/api/endpoints/${PTR_ENDPOINT}/docker/containers/${CID}/restart?t=40" | tail -1
      fi
      pkill -f "127.0.0.1:${LP}:127.0.0.1:9443" 2>/dev/null || true
    else
      echo "Could not reach Portainer - restart the server manually for the op to load."
    fi
    echo "Waiting for the server to restart and reload ops.json..."
    sleep 60
    echo
    echo "--- ops.json now ---"
    container_json /data/ops.json || true
    ;;
  deop)
    [ $# -eq 2 ] || usage
    console "deop $2" || true
    ;;
  pending)
    echo "Blocked join attempts in the last 24h."
    echo
    echo "JAVA - Paper logs the resolved name and UUID:"
    refused_lines | grep -iE 'UUID of player' | sort -u | sed 's/^/  /'
    echo
    echo "BEDROCK - Geyser logs the gamertag (their first refused attempt also"
    echo "registers the account with Floodgate, which is what makes the"
    echo "gamertag resolvable afterwards):"
    refused_lines | grep -iE '\[Geyser-Spigot\].*not whitelisted' \
      | sed -E 's/.*\[Geyser-Spigot\] ([^ ]+) has disconnected.*/  \1/' | sort -u
    echo
    echo "To approve them all:   ./mc-whitelist.sh approve-pending"
    echo "To approve one:        ./mc-whitelist.sh add <name>"
    echo "To make them operator: ./mc-whitelist.sh op <name>            (Java)"
    echo "                        ./mc-whitelist.sh opbedrock <gamertag>   (Bedrock)"
    ;;
  approve-pending)
    # Approve every refused attempt. Java players are approved by NAME
    # (Paper refuses a bare UUID); Bedrock players by gamertag.
    java_names="$(refused_lines | grep -oiE 'UUID of player [^ ]+ is [0-9a-fA-F-]{36}' \
                  | sed -E 's/UUID of player ([^ ]+) is .*/\1/' | sort -u \
                  | grep -v '^\.')"
    bedrock_tags="$(refused_lines | grep -iE '\[Geyser-Spigot\].*not whitelisted' \
                  | sed -E 's/.*\[Geyser-Spigot\] ([^ ]+) has disconnected.*/\1/' \
                  | sort -u | grep -v '^\.')"

    if [ -z "$java_names" ] && [ -z "$bedrock_tags" ]; then
      echo "No blocked join attempts found in the last 24h."
      exit 0
    fi

    if [ -n "$java_names" ]; then
      echo "$java_names" | while read -r name; do
        [ -n "$name" ] || continue
        echo "--- approving Java player '$name'"
        console "whitelist add $name" || true
      done
    fi

    if [ -n "$bedrock_tags" ]; then
      echo "$bedrock_tags" | while read -r tag; do
        [ -n "$tag" ] || continue
        echo "--- approving Bedrock player '$tag'"
        console "fwhitelist add $tag" || true
      done
    fi

    echo
    echo "--- whitelist now ---"
    console "whitelist list" || true
    ;;
  watch)
    ssh -o BatchMode=yes "${SSH_USER}@${HOST}" \
      "sudo -n docker logs -f ${CONTAINER} 2>&1 | \
       grep --line-buffered -iE '${REFUSED_RE}'" || true
    ;;
  *)
    usage
    ;;
esac
