# Nextcloud Docker setup manual

Oct 25, 2026 · Niels Vegter

## Overview

This manual sets up the standard Nextcloud Docker stack on an Ubuntu VM, configured from one `.env` file. Nextcloud answers on `http://<VM-IP>:8080` in your LAN. To reach it from the internet over HTTPS, put the nginx reverse proxy on your other machine in front of it; [NGINX-PROXY.md](NGINX-PROXY.md) explains that part.

The stack has four containers:

| Container | Image | Job |
| --- | --- | --- |
| `nextcloud` | `nextcloud` (Apache) | The web app, published on port 8080 |
| `db` | `postgres` | Database |
| `redis` | `redis` | Cache and file locking |
| `cron` | `nextcloud` | Runs background jobs every 5 minutes |

Around it:

- A Linux user called `nextcloud` owns the stack in `/home/nextcloud/nextcloud-proxmox` and runs the `docker compose` commands.
- User files live on the NAS, mounted over NFS at `/home/nextcloud/nextcloud-data`.
- A nightly restic job backs up files, database and config to a Hetzner Storage Box.

```
Visitor ─▶ router ─▶ nginx proxy (192.168.0.10, HTTPS) ─▶ VM 192.168.0.30:8080 ─▶ nextcloud ─▶ Postgres / Redis / cron
                                                                                    │
                                                                  NAS (NFS) ◀───────┘     restic ─▶ Hetzner Storage Box
```

Visitors from the internet only ever reach the nginx machine; Nextcloud's port 8080 stays inside your LAN.

The NAS is at `192.168.0.249`. The examples use `192.168.0.30` for the VM; replace it with your VM's real address (`ip -4 addr` shows it).

**Prerequisites**

- An Ubuntu 22.04 or 24.04 VM with a fixed LAN IP, 2 vCPU, 4 GB RAM or more.
- A NAS that can export an NFS share, with a fixed IP.
- A Hetzner Storage Box for backups.
- The files from this repository: `docker-compose.yml`, `env.example`, the backup script and the systemd units.

## Part 1: Prepare the VM

Run these from your own admin account.

**1. Install Docker** from Docker's own repository:

```bash
sudo apt update && sudo apt install -y ca-certificates curl git
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

**2. Create the `nextcloud` user** and let it use Docker:

```bash
sudo adduser --disabled-password --gecos "" nextcloud
sudo usermod -aG docker nextcloud
```

The `docker` group gives admin-level control over Docker, so the account gets no password and no SSH login. You open a shell as it with `sudo -iu nextcloud`.

**3. Get the stack files** as the `nextcloud` user:

```bash
sudo -iu nextcloud
git clone https://github.com/rnvegter/nextcloud-proxmox ~/nextcloud-proxmox   # private repo: sign in with a token
mkdir -p ~/nextcloud-data                                                     # mount point for the NAS
exit
```

## Part 2: User files on the NAS

Nextcloud keeps user files on an NFS share from the NAS. The database and Nextcloud's own code stay on the VM's disk.

**On the NAS:**

1. Create a shared folder, for example `nextcloud`.
2. Enable NFS and add an access rule for that folder: host = the VM's IP only, read/write, **no root squash**. The backup job runs as root and must be able to read every file.
3. Note the export path the NAS shows, for example `/nextcloud` or `/share/nextcloud`.

**On the VM** (admin account), mount the share and give it to the container's web user, `www-data` (uid 33):

```bash
sudo apt install -y nfs-common
echo "192.168.0.249:/nextcloud /home/nextcloud/nextcloud-data nfs4 rw,hard,noatime,_netdev 0 0" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount -a
df -h /home/nextcloud/nextcloud-data      # must show the NAS
sudo chown 33:33 /home/nextcloud/nextcloud-data
sudo chmod 750 /home/nextcloud/nextcloud-data
```

Make Docker wait for the share at boot, so Nextcloud never starts against an empty folder:

```bash
sudo install -D -m 644 /home/nextcloud/nextcloud-proxmox/systemd/docker.service.d/nas.conf \
  /etc/systemd/system/docker.service.d/nas.conf
sudo systemctl daemon-reload
```

After a power cut, start the NAS before the VM.

## Part 3: Configure and start the stack

Everything here runs as the `nextcloud` user.

**1. Create `.env`:**

```bash
sudo -iu nextcloud
cd ~/nextcloud-proxmox
cp env.example .env && chmod 600 .env
for i in 1 2 3; do openssl rand -hex 24; done   # three random passwords
nano .env
```

Fill in at least these values:

| Variable | Value |
| --- | --- |
| `NEXTCLOUD_ADMIN_PASSWORD` | Password 1 (or your own strong password) |
| `POSTGRES_PASSWORD` | Password 2 |
| `REDIS_PASSWORD` | Password 3 |
| `NEXTCLOUD_TRUSTED_DOMAINS` | `192.168.0.30` (the VM's IP; add your domain later, see NGINX-PROXY.md) |
| `NEXTCLOUD_DATA_PATH` | `/home/nextcloud/nextcloud-data` |
| `NEXTCLOUD_PORT` | `8080` (the port Nextcloud listens on at the VM) |

Leave the four reverse-proxy variables (`TRUSTED_PROXIES`, `OVERWRITE*`) empty for now.

**2. Start:**

```bash
docker compose config -q && echo "config OK"
docker compose up -d
docker compose logs -f nextcloud     # first install takes 1–3 minutes; Ctrl+C to stop watching
```

**3. Open** `http://192.168.0.30:8080` in a browser on your LAN and log in with `NEXTCLOUD_ADMIN_USER` and `NEXTCLOUD_ADMIN_PASSWORD`.

The admin account and trusted domains in `.env` are only read on the very first install. To change them later, use `occ` (Part 4).

## Part 4: First login and basic settings

Open *Administration settings → Overview* and work through any warnings. The commands below clear the usual ones. Run them as `nextcloud` in `~/nextcloud-proxmox`:

```bash
occ() { docker compose exec -u www-data nextcloud php occ "$@"; }
occ db:add-missing-indices
occ maintenance:repair --include-expensive
occ config:system:set default_phone_region --value=NL
occ config:system:set maintenance_window_start --type=integer --value=1
```

- **Background jobs:** under *Administration → Basic settings*, select **Cron**. The `cron` container runs them.
- **Add a trusted domain later:** `occ config:system:set trusted_domains 1 --value=cloud.example.com` (use 2, 3 … for more).
- **Accounts:** turn on 2FA for the admin (*Two-Factor TOTP Provider* app) and create a normal user for daily use.

## Part 5: Nightly backups to the Hetzner Storage Box

Every night at 03:00, a restic job on the VM puts Nextcloud in maintenance mode for a minute, dumps the database, and then sends the dump, the user files, Nextcloud's config and the stack folder (with `.env`) to the Storage Box. Backups are encrypted before they leave the VM. It keeps 7 daily, 4 weekly and 6 monthly backups.

Run everything below from your admin account.

**1. Storage Box.** In the Hetzner Console, enable **SSH support**, **External reachability** and **automatic snapshots**. SSH runs on port 23. Replace `uXXXXX` below with your Storage Box user.

**2. SSH key for root:**

```bash
sudo -i
ssh-keygen -t ed25519 -f /root/.ssh/storagebox -N ""
ssh-copy-id -p 23 -s -i /root/.ssh/storagebox.pub uXXXXX@uXXXXX.your-storagebox.de   # asks the password once
cat /home/nextcloud/nextcloud-proxmox/scripts/ssh-config.example >> /root/.ssh/config     # then edit uXXXXX
chmod 600 /root/.ssh/config
sftp storagebox      # must log in without a password; type 'bye'
```

**3. restic repository** (still as root):

```bash
apt install -y restic
openssl rand -hex 32 > /root/.restic-pass && chmod 600 /root/.restic-pass
install -m 600 /home/nextcloud/nextcloud-proxmox/scripts/restic.env.example /root/.restic.env
set -a; . /root/.restic.env; set +a
restic init
exit
```

**Store the contents of `/root/.restic-pass` in your password manager.** Without it the backups cannot be decrypted.

**4. Install the script and the timer:**

```bash
S=/home/nextcloud/nextcloud-proxmox
sudo install -m 700 $S/scripts/nextcloud-backup.sh /usr/local/sbin/
sudo install -m 644 $S/systemd/nextcloud-backup.service $S/systemd/nextcloud-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nextcloud-backup.timer
sudo systemctl start nextcloud-backup.service    # first run now; can take hours
journalctl -u nextcloud-backup -f
```

**5. Check it now and then:**

```bash
sudo -i
set -a; . /root/.restic.env; set +a
restic snapshots                       # one per night
restic restore latest --target /tmp/restore-test --include /home/nextcloud/nextcloud-data/admin/files
```

To restore everything onto a fresh VM: repeat Parts 1 and 2 and the restic setup, run `restic restore latest --target /`, start only the database (`docker compose up -d db`), load the dump with `docker compose exec -T db pg_restore -U nextcloud -d nextcloud --clean --if-exists < /var/backups/nextcloud/db.dump`, then start the stack and run `occ files:scan --all`.

## Updating and troubleshooting

**Update** (as `nextcloud`):

```bash
sudo -iu nextcloud
cd ~/nextcloud-proxmox
git pull                  # newer stack files, if any
docker compose pull
docker compose up -d
docker image prune -f
```

Nextcloud can only move up one major version at a time. Once it runs, pin `NEXTCLOUD_TAG` in `.env` to the current major (for example `31-apache`) and raise it by one per update. Never change `POSTGRES_TAG` to a new major without a dump and restore.

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| "Access through untrusted domain" | The address you use is not a trusted domain | `occ config:system:set trusted_domains 1 --value=<address>` |
| Stack does not start after a reboot | NAS share not mounted | Start the NAS, run `sudo mount -a`, check `df -h /home/nextcloud/nextcloud-data` |
| Nextcloud cannot write files | NAS folder not owned by uid 33 | `sudo chown 33:33 /home/nextcloud/nextcloud-data` (add `-R` if files exist) |
| Backup: permission denied | NFS rule uses root squash | Set no root squash for the VM's IP on the NAS |
| Backup failed | Storage Box key, space or NAS mount | `journalctl -u nextcloud-backup`; if needed `occ maintenance:mode --off` |
| Port 8080 already in use | Another service on the VM | Change `NEXTCLOUD_PORT` in `.env` and run `docker compose up -d` |

Useful checks: `docker compose ps`, `docker compose logs --tail=100 nextcloud`, `occ status`.
