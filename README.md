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
| Live services | `minecraft`, `minecraft-backup` |
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
| Bedrock Edition | `10.77.111.10` | 19132 | **UDP** |

UDP 19132 is mandatory for Bedrock. A TCP-only publish or a TCP-only router
forward means Java players connect and Bedrock players silently cannot.

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
| CoreProtect | block logging + rollback for grief |
| GriefPrevention | land claims |
| PlaceholderAPI | text placeholders for other plugins |
| Chunky | world pregeneration (removes lag spikes) |
| BlueMap | web map |

Not installed: Vault and spark - neither is on Modrinth (Vault: Hangar/Spigot,
spark: Hangar/GitHub), and Paper already bundles spark internally.

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
| `minecraft-111_backups` | nightly world tarballs, 7 kept |

The `backup` service tars `/data/world` into the backups volume every 5
minutes and prunes to the 7 most recent archives.

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
