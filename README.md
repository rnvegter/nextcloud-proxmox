# nextcloud-proxmox

Nextcloud on an Ubuntu VM (Proxmox) behind Caddy, published through a Cloudflare domain. Docker runs rootless under a dedicated `nextcloud` user, user files live on a NAS over NFS, and restic sends nightly backups to a Hetzner Storage Box.

```
Visitor ─▶ Cloudflare ─▶ (A) router :443  ─┐
                       └▶ (B) cloudflared ─┴▶ Caddy ─▶ Nextcloud ─▶ Postgres / Redis / cron
                                                          │
                                         NAS (NFS) ◀──────┘     restic ─▶ Hetzner Storage Box
```

- **Rootless Docker:** the daemon and all containers run as the unprivileged `nextcloud` user; no root daemon, nobody in the `docker` group.
- **Caddy** gets Let's Encrypt certificates via the Cloudflare DNS API (DNS-01); no port 80.
- **Exposure:** option A = port forward 443 + proxied A record; option B = Cloudflare Tunnel (`--profile tunnel`), no open ports.
- **Data:** user files on a NAS share mounted at `/home/nextcloud/nextcloud-data`; database and Redis stay on the VM disk.
- **Backups:** restic over SFTP (port 23) to a Storage Box, 7 daily / 4 weekly / 6 monthly.

## Repository layout

| Path | Goes to | Purpose |
| --- | --- | --- |
| `docker-compose.yml`, `Caddyfile`, `caddy/Dockerfile`, `env.example` | `/home/nextcloud/nextcloud-stack/` | The stack |
| `scripts/nextcloud-backup.sh` | `/usr/local/sbin/` (mode 700) | Nightly backup job (runs as root, talks to the rootless daemon) |
| `scripts/restic.env.example` | `/root/.restic.env` | restic repository settings |
| `scripts/ssh-config.example` | append to `/root/.ssh/config` | Storage Box SSH alias |
| `systemd/nextcloud-backup.{service,timer}` | `/etc/systemd/system/` | Schedule, 03:00 nightly |
| `systemd/user@.service.d/nas.conf` | `/etc/systemd/system/user@<uid of nextcloud>.service.d/` | `nextcloud`'s session (and Docker) waits for the NAS mount |

## Quick start

```bash
# 0. As your admin user: Docker (from Docker's apt repo) + rootless prerequisites
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
  docker-ce-rootless-extras uidmap dbus-user-session systemd-container nfs-common
sudo adduser --disabled-password --gecos "" nextcloud
sudo systemctl disable --now docker.service docker.socket && sudo rm -f /var/run/docker.sock
sudo loginctl enable-linger nextcloud
echo 'net.ipv4.ip_unprivileged_port_start=443' | sudo tee /etc/sysctl.d/99-rootless-ports.conf && sudo sysctl --system

# 1. As nextcloud: rootless daemon + stack
sudo machinectl shell nextcloud@
dockerd-rootless-setuptool.sh install
echo "export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock" >> ~/.bashrc && . ~/.bashrc
git clone https://github.com/rnvegter/nextcloud-proxmox ~/nextcloud-stack   # private repo: sign in with a token or deploy key
mkdir -p ~/nextcloud-data
exit

# 2. As your admin user: NAS share (NFS, rw, no root squash, VM IP only)
echo "NAS-IP:/nextcloud /home/nextcloud/nextcloud-data nfs4 rw,hard,noatime,_netdev 0 0" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount -a
WWW_UID=$(( $(grep ^nextcloud: /etc/subuid | cut -d: -f2) + 32 ))   # rootless-mapped www-data, usually 100032
WWW_GID=$(( $(grep ^nextcloud: /etc/subgid | cut -d: -f2) + 32 ))
sudo chown "$WWW_UID:$WWW_GID" /home/nextcloud/nextcloud-data && sudo chmod 750 /home/nextcloud/nextcloud-data
sudo install -D -m 644 /home/nextcloud/nextcloud-stack/systemd/user@.service.d/nas.conf \
  /etc/systemd/system/user@$(id -u nextcloud).service.d/nas.conf
sudo systemctl daemon-reload

# 3. As nextcloud: configure and start
sudo machinectl shell nextcloud@
cd ~/nextcloud-stack
cp env.example .env && chmod 600 .env      # fill in DOMAIN, CF_API_TOKEN, secrets
docker compose config -q
docker compose up -d --build                    # option A
docker compose --profile tunnel up -d --build   # option B
exit

# 4. As your admin user: backups
cd /tmp
sudo install -m 700 /home/nextcloud/nextcloud-stack/scripts/nextcloud-backup.sh /usr/local/sbin/
sudo install -m 644 /home/nextcloud/nextcloud-stack/systemd/nextcloud-backup.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now nextcloud-backup.timer
```

Before step 4, set up the Storage Box SSH key, `/root/.restic.env`, the restic password file and `restic init` as described in the manual.

## Full manual

The step-by-step manual (moving DNS from any registrar to Cloudflare, API token, rootless Docker under the `nextcloud` user, port forward vs tunnel, Cloudflare settings, Nextcloud hardening, Storage Box setup, restores and troubleshooting) is in [docs/MANUAL.md](docs/MANUAL.md).

## Secrets

`.env`, `/root/.restic.env` and `/root/.restic-pass` are never committed (see `.gitignore`). Keep the restic password in your password manager: without it the backups cannot be decrypted.
