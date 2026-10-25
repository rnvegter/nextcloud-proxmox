# nextcloud-proxmox

Nextcloud on an Ubuntu VM (Proxmox) behind Caddy, published through a Cloudflare domain, with user files on a NAS over NFS and nightly restic backups to a Hetzner Storage Box.

```
Visitor ─▶ Cloudflare ─▶ (A) router :443  ─┐
                       └▶ (B) cloudflared ─┴▶ Caddy ─▶ Nextcloud ─▶ Postgres / Redis / cron
                                                          │
                                         NAS (NFS) ◀──────┘     restic ─▶ Hetzner Storage Box
```

- **Caddy** gets Let's Encrypt certificates via the Cloudflare DNS API (DNS-01); no port 80.
- **Exposure:** option A = port forward 443 + proxied A record; option B = Cloudflare Tunnel (`--profile tunnel`), no open ports.
- **Data:** user files on a NAS share mounted at `~/nextcloud-data`; database and Redis stay on the VM disk.
- **Backups:** restic over SFTP (port 23) to a Storage Box, 7 daily / 4 weekly / 6 monthly.

## Repository layout

| Path | Goes to | Purpose |
| --- | --- | --- |
| `docker-compose.yml`, `Caddyfile`, `caddy/Dockerfile`, `env.example` | `~/nextcloud-stack/` | The stack |
| `scripts/nextcloud-backup.sh` | `/usr/local/sbin/` (mode 700) | Nightly backup job |
| `scripts/restic.env.example` | `/root/.restic.env` | restic repository settings |
| `scripts/ssh-config.example` | append to `/root/.ssh/config` | Storage Box SSH alias |
| `systemd/nextcloud-backup.{service,timer}` | `/etc/systemd/system/` | Schedule, 03:00 nightly |
| `systemd/docker.service.d/nas.conf` | `/etc/systemd/system/docker.service.d/` | Docker waits for the NAS mount |

Replace `youruser` in `nas.conf`, `nextcloud-backup.sh` and `.env` with your Linux username.

## Quick start

```bash
# 1. NAS share (NFS, rw, no root squash, VM IP only) mounted in your home
sudo apt install -y nfs-common
mkdir -p ~/nextcloud-data
echo "NAS-IP:/nextcloud $HOME/nextcloud-data nfs4 rw,hard,noatime,_netdev 0 0" | sudo tee -a /etc/fstab
sudo mount -a && sudo chown 33:33 ~/nextcloud-data && sudo chmod 750 ~/nextcloud-data
sudo install -D -m 644 systemd/docker.service.d/nas.conf /etc/systemd/system/docker.service.d/nas.conf
sudo systemctl daemon-reload

# 2. Stack
git clone <this repo> ~/nextcloud-stack && cd ~/nextcloud-stack
cp env.example .env && chmod 600 .env      # fill in DOMAIN, CF_API_TOKEN, secrets, NEXTCLOUD_DATA_PATH
docker compose config -q
docker compose up -d --build               # option A
docker compose --profile tunnel up -d --build   # option B

# 3. Backups (as root)
sudo install -m 700 scripts/nextcloud-backup.sh /usr/local/sbin/
sudo install -m 644 systemd/nextcloud-backup.service systemd/nextcloud-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now nextcloud-backup.timer
```

Before step 3, set up the Storage Box SSH key, `/root/.restic.env`, the restic password file and `restic init` as described in the manual.

## Full manual

The step-by-step manual (moving DNS from any registrar to Cloudflare, API token, port forward vs tunnel, Cloudflare settings, Nextcloud hardening, Storage Box setup, restores and troubleshooting) is in [docs/MANUAL.md](docs/MANUAL.md).

## Secrets

`.env`, `/root/.restic.env` and `/root/.restic-pass` are never committed (see `.gitignore`). Keep the restic password in your password manager: without it the backups cannot be decrypted.
