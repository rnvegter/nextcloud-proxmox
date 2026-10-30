# nextcloud-proxmox

The standard Nextcloud Docker stack for an Ubuntu VM (Proxmox), configured from one `.env` file. User files live on a NAS over NFS, and restic sends nightly backups to a Hetzner Storage Box. From the internet it is reached at `https://nextcloud.dockerapp.org` through a Caddy reverse proxy on another machine.

```
Visitor ─▶ FritzBox ─▶ UniFi ─▶ Caddy proxy (192.168.0.201, HTTPS) ─▶ VM :8080 ─▶ nextcloud ─▶ Postgres / Redis / cron
                                                                         │
                                                                  QNAP (NFS) ◀───────┘      restic ─▶ Hetzner Storage Box
```

| Container | Image | Job |
| --- | --- | --- |
| `nextcloud` | `nextcloud` (Apache) | The web app, published on port 8080 |
| `db` | `postgres` | Database |
| `redis` | `redis` | Cache and file locking |
| `cron` | `nextcloud` | Background jobs every 5 minutes |

## Files

| Path | Goes to | Purpose |
| --- | --- | --- |
| `docker-compose.yml`, `env.example` | `/home/nextcloud/nextcloud-proxmox/` | The stack |
| `systemd/docker.service.d/nas.conf` | `/etc/systemd/system/docker.service.d/` | Docker waits for the NAS mount |
| `scripts/nextcloud-backup.sh` | `/usr/local/sbin/` (mode 700) | Nightly backup job |
| `scripts/restic.env.example` | `/root/.restic.env` | restic repository settings |
| `scripts/ssh-config.example` | append to `/root/.ssh/config` | Storage Box SSH alias |
| `systemd/nextcloud-backup.{service,timer}` | `/etc/systemd/system/` | Backup schedule, 03:00 nightly |

## Quick start

```bash
# As your admin user: Docker (from Docker's apt repo) and the nextcloud user
sudo adduser --disabled-password --gecos "" nextcloud
sudo usermod -aG docker nextcloud

# As nextcloud: get the stack, configure, start
sudo -iu nextcloud
git clone https://github.com/rnvegter/nextcloud-proxmox ~/nextcloud-proxmox
mkdir -p ~/nextcloud-data          # mount the NAS here first (see the manual)
cd ~/nextcloud-proxmox
cp env.example .env && chmod 600 .env && nano .env
docker compose up -d
```

Then open `http://192.168.0.202:8080` (LAN) or `https://nextcloud.dockerapp.org` (internet, via Caddy).

## Documentation

- [docs/MANUAL.md](docs/MANUAL.md): full setup, NAS share, first settings, backups, updates and troubleshooting.
- [docs/CADDY-PROXY.md](docs/CADDY-PROXY.md): publishing Nextcloud through the Caddy proxy, including port forwarding through the FritzBox and the UniFi gateway.

## Secrets

`.env`, `/root/.restic.env` and `/root/.restic-pass` are never committed (see `.gitignore`). Keep the restic password in your password manager: without it the backups cannot be decrypted.
