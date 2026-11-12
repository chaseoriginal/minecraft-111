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
| Portainer stack id | 39 |
| Live services | `minecraft`, `minecraft-backup`, `minecraft-config-init` (one-shot) |
| Git repo | https://github.com/chaseoriginal/minecraft-111 |
| Compose file | `docker-compose.yml` |
| Auto-update poll | every 900s |

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

| Edition | Address | Port | Protocol |
|---|---|---|---|
| Java Edition | `10.77.111.10` | 25565 | TCP |
| Bedrock Edition | `10.77.111.10` | 19132 | **UDP** (gameplay) + **TCP** (signaling) |

**Both TCP and UDP 19132 are published.** Geyser's NetherNet transport uses
TCP to find the server and UDP to play on it. Before NetherNet, forwarding UDP
was enough; now a UDP-only forward means the server does not even show up in
the Bedrock client list.

Verified live: Java server-list ping returns `Paper 26.3`, Bedrock ping returns
`version=26.63`.

### Internet exposure

For players outside the LAN the router must forward **both TCP and UDP 19132**
and TCP 25565 to `10.77.111.10`, and `bedrock.signaling.advertise-addresses`
in `geyser-config.yml` must name the public address
(`<public-ip>:19132`). The committed value is the LAN address, which is correct
for internal play only.

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

## Volumes

| Volume | Contents |
|---|---|
| `minecraft-111_data` | world, plugins, server config |
| `minecraft-111_backups` | world tarballs, 7 kept |

The `backup` service tars `/data/world` into the backups volume every 5
minutes and prunes to the 7 most recent archives.

### Geyser config is git-tracked

`geyser-config.yml` in this repo is the source of truth for Geyser. The
`config-init` one-shot service downloads it into the data volume before the
server starts, because Geyser only writes `config.yml` when it is missing and
the itzg image's `APPLY_EXTRA_FILES` refuses to overwrite an existing file.

To change a Geyser setting: edit `geyser-config.yml`, push, redeploy. Never
edit the file on the host - the next start overwrites it.

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
