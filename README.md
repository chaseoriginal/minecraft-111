# minecraft-111

Minecraft server on **ore-dock-111-1** that accepts **both Java Edition and
Bedrock Edition** clients on the same world.

Portainer-managed stack. **Git is the source of truth**; Portainer owns the
deployment and polls this repository for changes.

| | |
|---|---|
| Portainer host | ore-dock-110-1 (this Portainer owns the 111-1 endpoint) |
| Endpoint | dock-111-1 (id 6), agent `tcp://10.77.111.10:9001` |
| Target host | ore-dock-111-1 (10.77.111.10, standalone Docker, not swarm) |
| Swarm | False (standalone compose stack) |
| Portainer stack id | 40 |
| Live services | `minecraft`, `minecraft-backup`, `minecraft-config-init` (one-shot) |
| Git repo | https://github.com/chaseoriginal/minecraft-111 |
| Compose file | `docker-compose.yml` |
| Auto-update poll | every 900s |

## Relationship to mc-charlescraft

This is a **separate server**, not a copy of `mc-charlescraft` (ore-dock-110-10).
It borrows that stack's configuration:

| | mc-charlescraft | minecraft-111 (this stack) |
|---|---|---|
| MOTD | Bedrock and Java Minecraft, survival multiplayer | same |
| Timezone | America/Denver | same |
| Java port | 25565/tcp | 25565/tcp |
| Bedrock port | 19132 | 19132 udp+tcp (NetherNet needs both) |
| Stats dashboard | 8804/tcp published, **never bound** | 8804/tcp, Plan actually serving |
| RCON | enabled | enabled |
| Backups | image-managed, 10 kept | separate service, 7 kept |
| Server software | Paper 26.1.2 via `05jchambers/legendary-minecraft-geyser-floodgate` | Paper 26.3 via `itzg/minecraft-server:java25` |
| Plugins | Geyser, Floodgate, ViaVersion, spark | Geyser, Floodgate, ViaVersion, ViaBackwards, LuckPerms, EssentialsX, StellarProtect, GriefPrevention, PlaceholderAPI, VaultUnlocked, Chunky, BlueMap, Plan |

The one gap in the old stack was the statistics page: `mc-charlescraft`
published port 8804 but the image never bound it, so nothing was served.
**Plan** is the plugin that provides it, and it is running here.

## Versions

| Component | Version | Why |
|---|---|---|
| Minecraft Java | **26.3** | latest **stable** release (26.4 is snapshot-only) |
| Paper | 26.3 build 249 | latest stable Paper build |
| Java runtime | **java25** | Paper 26.3 declares `java.version.minimum: 25` |
| Geyser | 2.12.1 build 1300 | declares Java 26.3 + Bedrock 26.40-26.63 support |
| Floodgate | 2.2.5 build 141 | 26.3-aware |

`api.papermc.io/v2` is sunset; use `fill.papermc.io/v3` to resolve builds.

## Connecting

| Service | Address | Port | Protocol |
|---|---|---|---|
| Java Edition | `10.77.111.10` | 25565 | TCP |
| Bedrock Edition | `10.77.111.10` | 19132 | **UDP** (gameplay) + **TCP** (signaling) |
| Plan dashboard | `10.77.111.10` | 8804 | TCP (**HTTPS** - see below) |

**Both TCP and UDP 19132 are published.** Geyser's NetherNet transport uses
TCP to find the server and UDP to play on it. Before NetherNet, forwarding UDP
was enough; now a UDP-only forward means the server does not even show up in
the Bedrock client list.

Verified live: Java server-list ping returns `Paper 26.3`, Bedrock ping returns
`version=26.63`.

### Internet exposure

For players outside the LAN the router must forward **both TCP and UDP 19132**
and TCP 25565 to `10.77.111.10`.

`bedrock.signaling.advertise-addresses` in `geyser-config.yml` is committed as:

```yaml
advertise-addresses:
  - mc.echoinggreen.net:19132
  - 216.165.142.70:19132
```

The hostname is resolved **by the server** when signaling starts (split-horizon
AD DNS gives it the LAN address), but the *name* is what is handed to clients,
so a remote Bedrock client resolves it publicly and connects to the public IP.
The literal public IP is listed as a fallback for clients whose DNS does not
split-horizon.

> **Open item - UDP 19132.** Geyser 2.12.1 in `transport: nethernet` mode binds
> **TCP 19132 only** on this host (verified: no UDP socket on `19132` in
> `/proc/net/udp`, and external UDP probes get *Connection refused*). Geyser's
> docs say players use TCP to find the server and UDP to play on it, so
> **external Bedrock gameplay will not work until UDP 19132 is forwarded and
> Geyser is given a UDP port to bind.** `webrtc-port: 0` makes Geyser use the
> Bedrock port for its UDP side; the fix is either a real `webrtc-port` value
> or `transport: both`.

## Plan dashboard: HTTPS, auth, and how to register

Plan **requires HTTPS before it enables authentication**. In Plan 5.9,
`JettyWebserver.isAuthRequired()` is:

```java
return isUsingHTTPS() && webserverConfiguration.isAuthenticationEnabled();
```

So on plain HTTP the auth routes (`/login`, `/register`, `/auth/login`,
`/auth/register`) are **never registered** and every attempt returns 404 -
regardless of `Disable_authentication: false`. This is the single most
confusing thing about Plan: the config says auth is on, and the endpoints
still do not exist.

This stack therefore serves Plan over **HTTPS** on 8804 with a self-signed
certificate:

- `cert-init` (a one-shot `eclipse-temurin:25-jdk` service) generates
  `/data/plugins/Plan/Cert.p12` with `keytool` **on the data volume at
  startup**. The private key is never committed to git and never leaves the
  host.
- `plan-config.yml` points `SSL_certificate.KeyStore_path` at that file.

Browsers will warn once about the self-signed certificate. The dashboard is
LAN-only (TCP 8804 is not forwarded externally), so this is acceptable.

### Registering an administrator

```bash
# 1. POST to the endpoint to obtain a registration code (valid 15 min)
curl -sk -X POST -H "Content-Type: application/x-www-form-urlencoded" \
  --data "user=admin&password=<password>" \
  https://10.77.111.10:8804/auth/register
# -> {"code":"fca76f9061f2","success":true}

# 2. finish it from the server console (superuser = console sender flag)
ssh ladmin@10.77.111.10 \
  'sudo -n docker exec -u 1000 minecraft mc-send-to-console "plan register --code fca76f9061f2 superuser"'
# -> Added a new user (admin) successfully!
```

Notes:
- The **first** attempt at step 2 consumes the code and fails with
  *"Registration failed, player did not have any 'plan.webgroup.{name}'
  permission"* - the `superuser` flag was missing. The code is then spent and
  you must request a new one.
- `plan register` without `--code` prints the register link.
- The console flag is `superuser`; a *player* sender instead needs the
  `plan.webgroup.<name>` permission.

Credentials are stored in `~/.hermes/secrets/minecraft-111.txt` (mode 600) and
should be moved into Keeper - see the Keeper note below.

## Whitelist: Java AND Bedrock in one file

Paper's whitelist is **on** (`white-list=true`, `enforce-whitelist=true`).
Both editions are covered by the **same** `whitelist.json`:

- Java players are approved by profile name; Paper resolves it to a UUID.
- Bedrock players are approved with Floodgate's `/fwhitelist`, which writes
  into the same `whitelist.json`.

Paper's whitelist check lives only in the *network login* path
(`PlayerList.canPlayerLogin` -> `isWhiteListedLogin`); Geyser joins through an
injected local connection instead, so **Floodgate is what gates Bedrock
players**, not Paper's login check.

### The helper script

`scripts/mc-whitelist.sh` runs server-side over the console pipe, so it works
even while the whitelist would lock you out:

```bash
./scripts/mc-whitelist.sh add <java-name|gamertag>   # approve
./scripts/mc-whitelist.sh adduuid <uuid>              # approve by UUID
./scripts/mc-whitelist.sh remove <name>               # revoke
./scripts/mc-whitelist.sh list                       # show whitelist
./scripts/mc-whitelist.sh ops / op <name> / deop <name>
./scripts/mc-whitelist.sh pending                    # refused join attempts
./scripts/mc-whitelist.sh approve-pending            # approve every logged UUID
./scripts/mc-whitelist.sh watch                      # live tail of attempts
```

**`approve-pending` is the answer to "I don't know all the names."** A player
who is refused is logged with their UUID (`UUID of player {} is {}`), so you
approve them by UUID and never have to know or type their name.

Two implementation notes, both learned the hard way:

1. The console command must be piped to the remote shell on **stdin**, not
   interpolated into the command line - `bash "whitelist list"` passes the
   command as a *filename* and silently runs nothing.
2. The fleet's SSH login banner is printed on the remote shell's **stdout**,
   before the command output, so the reply must be filtered **locally**.

### Seeding vs runtime approvals

`WHITELIST` (in the compose env) seeds names, and
`EXISTING_WHITELIST_FILE: "MERGE"` makes the itzg image merge those into the
existing `whitelist.json` instead of replacing it. **Runtime approvals are
therefore never wiped by a restart** - verified empirically (add -> restart ->
entry still present).

## Plugins

Installed into `/data/plugins` by the itzg image from the `PLUGINS` list.
Removing a line from that list removes the jar on the next restart.

| Plugin | Purpose |
|---|---|
| Geyser-Spigot | Bedrock -> Java protocol bridge (required) |
| Floodgate-Spigot | lets Bedrock players in without a Java account (required) |
| ViaVersion | lets older Java clients connect |
| ViaBackwards | lets older Java clients connect (older protocol support) |
| LuckPerms | permissions |
| EssentialsX | chat, commands, homes, warps |
| StellarProtect | block logging + rollback for grief (CoreProtect-compatible) |
| GriefPrevention | land claims |
| PlaceholderAPI | text placeholders for other plugins |
| VaultUnlocked | economy/permission API (EssentialsX needs it for chat prefixes) |
| Plan (Player Analytics) | web dashboard of server/player statistics on port 8804 |
| Chunky | world pregeneration (removes lag spikes) |
| BlueMap | web map |

Not installed: spark - not on Modrinth (Hangar/GitHub only), and Paper already
bundles spark internally.

### Version-compatibility notes (26.3)

Three plugins were swapped after a first boot proved them incompatible:

- **CoreProtect 24.1** refuses to start on 26.3 ("Minecraft 26.3 is not
  supported") and disables itself. Replaced with **StellarProtect 2.0.2**, the
  maintained CoreProtect-compatible fork.
- **Chunks 0.2** is a different plugin from **Chunky** - it is a MySQL-backed
  claim plugin, not the pregenerator, and it fails to enable without a
  database. Replaced with **Chunky 1.5.66**, the actual pregenerator.
- **BlueMap** ships separate spigot and paper builds; the spigot build logs a
  warning on Paper. Using `bluemap-5.29-paper.jar`.

EssentialsX 2.22.0 logs "You are running an unsupported server version!" but
still enables and works - it is a cosmetic complaint about the calendar-based
version numbering, not a failure.

`game_versions` on Modrinth lags badly (EssentialsX still lists 1.10-1.13).
Absence of the current version is not evidence of incompatibility - judge on
the plugin's own startup log.

`online-mode=true` is set and must stay that way. Floodgate does **not**
require disabling it; disabling it opens the Java server to cracked clients.

## Files

- `docker-compose.yml` - the deployed compose.
- `.env.example` - the variable names Portainer substitutes, values redacted.
  The real values live in the Portainer stack environment.

## Deployment gotchas learned the hard way

**`raw.githubusercontent.com` serves STALE files.** `config-init` originally
fetched `plan-config.yml` and `geyser-config.yml` with `wget` from
`raw.githubusercontent.com`. After a push, the CDN kept serving the *previous*
revision for minutes - the deploy "succeeded" and silently rolled back the
config. The fix: `config-init` now **clones the repository** (`git clone
--depth 1`), which always returns the pushed commit. The GitHub *API* was
already correct while the raw CDN was stale, which is what made it confusing.

**Never update a Portainer stack's environment via the API.** `PUT /api/stacks/{id}`
sets `IsDetachedFromGit: true` and nulls `GitConfig`, and the reattach endpoint
refuses to restore it. Delete and recreate the stack from the repository
instead. Volumes and the world survive.

**Changing a compose file changes the ConfigHash.** After a push, redeploy and
confirm the reported ConfigHash equals the commit SHA - that is the proof the
new revision is live, not just that the API returned 200.

## Volumes

| Volume | Contents |
|---|---|
| `minecraft-111_data` | world, plugins, server config, Plan SQLite DB |
| `minecraft-111_backups` | world tarballs, 7 kept |

The `backup` service tars `/data/world` into the backups volume every 5
minutes and prunes to the 7 most recent archives.

### Plan (Player Analytics) dashboard

The statistics web page lives at **http://10.77.111.10:8804/** and redirects to
`/server/Echoing Green Minecraft`. It shows online players, playtime, sessions,
TPS, memory/disk, and per-player history, and it registers extensions for
Essentials, GriefPrevention, LuckPerms, PlaceholderAPI, Vault and ViaVersion.

Plan uses SQLite by default, so no external database is needed. The Plan web
server defaults to port **8804**, which is the same port the `mc-charlescraft`
stack publishes - the two are on different hosts so there is no conflict.

Plan requires an account: the first visit asks for a registration code. Get it
from the server console with `/plan code`, or read it from the startup log.
Authentication stays ENABLED - the dashboard is reachable but not readable
without an account.

### Geyser and Plan configs are git-tracked

`geyser-config.yml` and `plan-config.yml` in this repo are the source of truth
for those plugins. The `config-init` one-shot service downloads both into the
data volume before the server starts, because Geyser and Plan only write their
`config.yml` when it is missing and the itzg image's `APPLY_EXTRA_FILES`
refuses to overwrite an existing file.

`config-init` also chowns both directories to uid 1000. Without that the
server user cannot write its own plugin directory and Plan dies on startup with
`IllegalStateException: plugins/Plan/config.yml`.

To change a setting: edit the yaml in git, push, redeploy. Never edit the file
on the host - the next start overwrites it.

## How a change is deployed

1. Edit `docker-compose.yml` and push to `main`.
2. Portainer polls the repo and redeploys automatically.

## Verifying a deployment

```bash
ssh ladmin@ore-dock-111-1 'docker ps --filter name=minecraft --format "{{.Names}}|{{.Status}}|{{.Ports}}"'
ssh ladmin@ore-dock-111-1 'docker logs minecraft 2>&1 | grep -E "Done \(|Geyser|Floodgate|ERROR"'
ssh ladmin@ore-dock-111-1 'ss -lun | grep 19132'   # Bedrock UDP listener
```

A healthy stack shows `minecraft` Up, the ports published, `Done (Xs)!` in the
log, and a Geyser/Floodgate load line.
