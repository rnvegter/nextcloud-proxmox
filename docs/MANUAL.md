# Nextcloud + Caddy + Cloudflare setup manual

Oct 25, 2026 · Niels Vegter

## Overview

This manual takes a domain bought at any registrar, moves its DNS to Cloudflare, and publishes Nextcloud at `https://cloud.example.com` through Caddy. Replace `cloud.example.com` and `example.com` with your own names throughout.

The stack runs on one Ubuntu VM with Docker Compose:

- **A dedicated user** called `nextcloud` owns the stack and runs the `docker compose` commands. The stack lives in its home, `/home/nextcloud`.
- **Caddy** terminates HTTPS and gets Let's Encrypt certificates through the Cloudflare DNS API (DNS-01), so port 80 is never needed.
- **Nextcloud** (Apache image) sits behind Caddy with no published ports. All user files live on an external NAS, mounted over NFS at `/home/nextcloud/nextcloud-data`.
- **Postgres**, **Redis** and a **cron** worker live on an internal network with no route to the internet. Their data stays on the VM's own disk.
- **cloudflared** is optional and only runs for option B.
- **restic** runs on the VM host every night and sends encrypted, deduplicated backups of user files, database and configuration to a **Hetzner Storage Box** (Part 8).

```
Visitor ─▶ Cloudflare edge ─▶ (A) home router :443 ──┐
                            └▶ (B) cloudflared ───────┴▶ Caddy ─▶ Nextcloud ─▶ Postgres / Redis / cron
                                                                     │
                                                    NAS (NFS) ◀──────┘        restic ─▶ Hetzner Storage Box
```

Option A enters through the router, option B through `cloudflared` inside the VM; either way Caddy is the only door to Nextcloud, and the database never touches the internet.

You choose one of two ways to reach the VM from the internet:

| | Option A: port forward | Option B: Cloudflare Tunnel |
| --- | --- | --- |
| Router change | Forward 443 to the VM | None |
| Works behind CGNAT | No | Yes |
| Public IP needed | Yes (static or DDNS) | No |
| DNS record | A record, proxied | CNAME created by the tunnel |
| Can bypass the 100 MB upload cap | Yes, with a DNS-only record | No |

Pick A if you have a public IPv4 address and control the router. Pick B if you are behind CGNAT, cannot change the router, or want no open ports at all.

**Prerequisites**

- A domain at any registrar, with access to its nameserver settings.
- A free Cloudflare account.
- An Ubuntu 22.04 or 24.04 VM with a fixed LAN IP (static or a DHCP reservation), 2 vCPU, 4 GB RAM or more.
- A NAS on the same LAN that can export an NFS share, with a fixed IP and room for all users' data plus growth.
- A Hetzner Storage Box, with room for at least 1.5 times the user data to hold backup history.
- The stack files from this repository: `docker-compose.yml`, `env.example`, `Caddyfile`, `caddy/Dockerfile`.

## Part 1: Move DNS from your registrar to Cloudflare

Your domain stays registered (and paid for) at your current registrar. You only change its nameservers so Cloudflare answers DNS for it. Menu names differ per registrar; look for "Nameservers", "DNS servers" or "Custom nameservers".

1. **Inventory existing records.** At the registrar, note every DNS record you rely on: MX and TXT (SPF, DKIM, DMARC) for email, and any A or CNAME records for websites. Missing these after the switch breaks email.
2. **Turn off DNSSEC at the registrar** if it is on. Changing nameservers while DNSSEC is active makes the domain unresolvable until the old DS record expires.
3. **Add the domain to Cloudflare.** In the Cloudflare dashboard choose *Add a domain*, enter the bare domain (`example.com`, not `cloud.example.com`) and select the Free plan.
4. **Review the imported records.** Cloudflare scans and imports what it can find. Compare against your inventory and add anything missing. Set email-related records (MX targets, mail hosts) to *DNS only* (grey cloud).
5. **Copy the two Cloudflare nameservers** shown on the activation screen, for example `ada.ns.cloudflare.com` and `bob.ns.cloudflare.com`. Yours will have different names.
6. **Replace the nameservers at the registrar.** Choose the option for custom or external nameservers, remove all existing entries and enter only the two Cloudflare names. Save.
7. **Wait for activation.** This usually takes minutes to a few hours, at most about 24 hours. Cloudflare emails you when the domain is active. Check from any machine:

   ```bash
   dig NS example.com +short
   # expected: the two *.ns.cloudflare.com names
   ```

8. **Re-enable DNSSEC through Cloudflare.** In Cloudflare go to *DNS → Settings → DNSSEC → Enable*. Cloudflare shows a DS record (key tag, algorithm, digest type, digest). Enter those values at the registrar's DNSSEC page. Some registrars only accept the public key (DNSKEY) instead; Cloudflare shows that too.

Do not create the `cloud` record yet. Part 5 creates it, differently for each option.

**Optional: transfer the registration itself to Cloudflare.** Cloudflare Registrar sells domains at cost, but it is not required for anything in this manual. A transfer needs the domain to be active on Cloudflare, unlocked at the old registrar, older than 60 days since registration or last transfer, and an authorisation (EPP) code. Not every TLD is supported, so check yours before starting.

## Part 2: Create the Cloudflare API token for Caddy

Caddy uses this token to create a temporary `_acme-challenge` TXT record, which proves to Let's Encrypt that you own the domain. The token can only edit DNS for this one zone.

1. In Cloudflare, open *My Profile → API Tokens → Create Token*.
2. Pick the template **Edit zone DNS**.
3. Under *Zone Resources* choose *Include → Specific zone → example.com*.
4. Optional: under *Client IP Address Filtering*, limit it to your home public IP. Skip this if your IP changes.
5. *Continue to summary → Create Token*. Copy the token now; Cloudflare shows it only once.

Verify it works before going further:

```bash
curl -s https://api.cloudflare.com/client/v4/user/tokens/verify \
  -H "Authorization: Bearer YOUR_TOKEN"
# expected: "status":"active"
```

The token goes into `CF_API_TOKEN` in `.env` (Part 4). Use a token, never your Global API Key.

## Part 3: Prepare the Ubuntu VM

**Fixed LAN address.** Give the VM a static IP, or a DHCP reservation in the router. Option A forwards traffic to this address.

**Install Docker Engine and the Compose plugin** from Docker's own repository (the Ubuntu `docker.io` package lags behind):

```bash
sudo apt update && sudo apt install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

**Create the `nextcloud` user.** This user owns the stack and runs all `docker compose` commands. Run from your own admin account:

```bash
sudo adduser --disabled-password --gecos "" nextcloud
sudo usermod -aG docker nextcloud
sudo -iu nextcloud docker compose version     # check
```

Membership of the `docker` group gives control over the Docker daemon, which runs as root, so treat `nextcloud` as an admin-level account: no password login and no SSH access of its own. You reach it only through `sudo -iu nextcloud`.

**From here on, `~` means `/home/nextcloud`, and every `docker compose` command runs as the `nextcloud` user** in a shell opened with `sudo -iu nextcloud`. Steps that need `sudo` run from your admin account; they say so.

**Firewall.** Ports that Docker publishes bypass `ufw`, so `ufw` rules do not protect them. Control exposure with the `CADDY_HTTPS_BIND` setting and the router instead. Still use `ufw` for SSH:

```bash
sudo ufw allow OpenSSH
sudo ufw enable
```

**Folders.**

```bash
sudo -iu nextcloud
mkdir -p ~/nextcloud-stack/caddy ~/nextcloud-data   # stack folder and NAS mount point
exit
```

**User files on the NAS.** Nextcloud keeps user files on an NFS share from the NAS, mounted at `~/nextcloud-data`. The database, Redis and Nextcloud's own code stay on the VM's disk; never put the Postgres data on a network share. The examples use `192.168.1.20` for the NAS and `/nextcloud` as the export path; use your own.

On the NAS:

1. Give the NAS a fixed IP.
2. Create a shared folder for Nextcloud, for example `nextcloud`.
3. Enable the NFS service (NFSv4 if offered) and add an NFS access rule for that folder: host = the VM's IP only, read/write, **no root squash** (some NAS menus call it "no mapping"). Root on the VM needs full access to set ownership and to let the backup job read every user's files. Limiting the rule to the VM's IP keeps that contained.
4. Note the export path the NAS shows; depending on the model it is `/nextcloud` or `/share/nextcloud`.

On the VM, from your admin account, mount the share and hand it to the container's `www-data` user (uid 33):

```bash
sudo apt install -y nfs-common
echo "192.168.1.20:/nextcloud /home/nextcloud/nextcloud-data nfs4 rw,hard,noatime,_netdev 0 0" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount -a
df -h /home/nextcloud/nextcloud-data          # must show the NAS, not the VM disk
sudo chown 33:33 /home/nextcloud/nextcloud-data
sudo chmod 750 /home/nextcloud/nextcloud-data
```

Make Docker wait for the share at boot, so Nextcloud never starts against the empty mount point (also in this repo as `systemd/docker.service.d/nas.conf`):

```bash
sudo mkdir -p /etc/systemd/system/docker.service.d
printf '[Unit]\nRequiresMountsFor=/home/nextcloud/nextcloud-data\n' \
  | sudo tee /etc/systemd/system/docker.service.d/nas.conf
sudo systemctl daemon-reload
```

If the NAS is off, Docker now waits for it instead of starting the stack. That is intended: Nextcloud offline is better than Nextcloud writing into the wrong folder. Start the NAS before the VM after a power cut. A wired 1 Gbit link between VM host and NAS is enough for home use; preview generation is the most I/O-heavy part.

Copy the stack files (or clone this repository) so the layout is:

```
~/nextcloud-stack/          (= /home/nextcloud/nextcloud-stack)
├── docker-compose.yml
├── env.example
├── Caddyfile
└── caddy/Dockerfile
```

Everything sits in the `nextcloud` user's home: the stack in `~/nextcloud-stack`, the user files on the NAS mount at `~/nextcloud-data`. Run all `docker compose` commands as `nextcloud` from the stack folder. The backup job in Part 8 runs as root, where `~` means `/root`, so it uses full paths under `/home/nextcloud`.

## Part 4: Configure and start the stack

**1. Create `.env`.**

```bash
sudo -iu nextcloud     # everything in Part 4 runs as nextcloud
cd ~/nextcloud-stack
cp env.example .env && chmod 600 .env
for i in 1 2 3; do openssl rand -hex 24; done   # three secrets
```

Hex secrets avoid characters such as `$` that Compose would try to interpolate. Fill in at least these values:

| Variable | Value |
| --- | --- |
| `DOMAIN` | `cloud.example.com` |
| `ACME_EMAIL` | Your email, for Let's Encrypt expiry notices |
| `CF_API_TOKEN` | Token from Part 2 |
| `NEXTCLOUD_ADMIN_PASSWORD` | Secret 1 (or your own strong password) |
| `POSTGRES_PASSWORD` | Secret 2 |
| `REDIS_PASSWORD` | Secret 3 |
| `NEXTCLOUD_DATA_PATH` | `/home/nextcloud/nextcloud-data` |
| `CADDY_HTTPS_BIND` | `443` for option A, `127.0.0.1:443` for option B |
| `CF_TUNNEL_TOKEN` | Option B only, filled in Part 5B |

`PROXY_SUBNET` (default `172.30.0.0/24`) must not overlap your LAN or another Docker network. If an older network named `proxy` exists, remove it first with `docker network rm proxy`.

**2. Check the configuration.**

```bash
docker compose config -q && echo "config OK"
```

**3. Start.** For option A start now. For option B, finish Part 5B first, then start with the tunnel profile.

```bash
docker compose up -d --build                    # option A
docker compose --profile tunnel up -d --build   # option B
```

**4. Watch the first start.**

```bash
docker compose ps                        # all services Up, db healthy
docker compose logs -f caddy             # look for "certificate obtained successfully"
docker compose logs -f nextcloud         # first install takes 1–3 minutes
```

Caddy can get its certificate before any public DNS record exists, because DNS-01 only needs the API token. If the certificate step fails, the token or zone is wrong (see Troubleshooting).

`NEXTCLOUD_ADMIN_*` and `NEXTCLOUD_TRUSTED_DOMAINS` are used only on the very first install. Changing them later in `.env` has no effect; use `occ` instead (Part 7).

## Part 5A: Expose with port forwarding

**1. Check you have a real public IP.** Compare the WAN address on your router's status page with what `curl -4 ifconfig.me` returns from the VM. If they differ, or the router shows an address in `100.64.0.0/10`, you are behind CGNAT: use option B.

**2. Forward the port on the router.**

| External port | Protocol | Internal IP | Internal port |
| --- | --- | --- | --- |
| 443 | TCP | VM LAN IP | 443 |
| 443 | UDP | VM LAN IP | 443 |

The UDP rule only matters if you later switch the record to DNS-only; behind the orange cloud, Cloudflare handles HTTP/3 to clients. Port 80 is not needed.

**3. Create the DNS record in Cloudflare** (*DNS → Records → Add record*):

| Type | Name | Content | Proxy status |
| --- | --- | --- | --- |
| A | `cloud` | Your public IPv4 | Proxied (orange) |

Add an AAAA record only if the VM is reachable on IPv6 and your router allows inbound 443 on IPv6.

**4. If your public IP changes**, run a dynamic-DNS updater. A small option is the `favonia/cloudflare-ddns` container, using an API token with the same *Edit zone DNS* scope. Set it to update only `cloud.example.com` and keep it proxied.

**5. Set SSL/TLS to Full (strict)** (Part 6). Then open `https://cloud.example.com`.

**Optional hardening: only accept traffic from Cloudflare.** Because the record is proxied, all legitimate traffic arrives from Cloudflare's published IP ranges ([cloudflare.com/ips](https://www.cloudflare.com/ips/)). Restrict the 443 forward to those ranges in the router if it supports source filtering, or enable *Authenticated Origin Pulls* in Cloudflare and require the client certificate in Caddy.

## Part 5B: Expose with a Cloudflare Tunnel

The `cloudflared` container makes an outbound connection to Cloudflare, so nothing on your router changes. It reaches Caddy over the internal `proxy` network.

**1. Create the tunnel.** Open the Cloudflare *Zero Trust* dashboard and go to *Networks → Tunnels* (older layouts: *Access → Tunnels*). Choose *Create a tunnel → Cloudflared*, name it (for example `home-vm`) and save.

**2. Copy the token.** On the install screen, pick *Docker*. The command shown ends with `--token eyJ...`. Copy only the long token value into `CF_TUNNEL_TOKEN` in `.env`. Do not run the shown command; the compose file runs `cloudflared` for you.

**3. Add a public hostname** (the next screen, or the tunnel's *Public Hostname* tab):

| Field | Value |
| --- | --- |
| Subdomain | `cloud` |
| Domain | `example.com` |
| Path | empty |
| Service type | HTTPS |
| URL | `caddy:443` |

Then open *Additional application settings → TLS* and set **Origin Server Name** to `cloud.example.com`. Without it, Caddy cannot pick the right certificate and the tunnel returns 502. Leave *No TLS Verify* off; Caddy's certificate is valid.

Cloudflare creates the proxied `cloud` CNAME record pointing at the tunnel. If an A record named `cloud` already exists, delete it first or the hostname save fails.

**4. Lock down the origin.** Make sure `.env` has `CADDY_HTTPS_BIND=127.0.0.1:443`, so Caddy is not reachable from the LAN or the internet. Remove any 443 port forward you made earlier.

**5. Start with the tunnel profile.**

```bash
docker compose --profile tunnel up -d --build
docker compose logs -f cloudflared   # look for "Registered tunnel connection" (usually 4 of them)
```

The tunnel shows *Healthy* in the dashboard. Set SSL/TLS to Full (strict) (Part 6), then open `https://cloud.example.com`.

## Part 6: Recommended Cloudflare settings

These apply to both options. The most important one is SSL/TLS mode: anything other than Full (strict) causes redirect loops or an unverified origin.

| Where in Cloudflare | Setting | Why |
| --- | --- | --- |
| SSL/TLS → Overview | **Full (strict)** | Caddy has a valid certificate; Flexible causes a redirect loop |
| SSL/TLS → Edge Certificates | Always Use HTTPS: On | Redirects stray HTTP requests |
| SSL/TLS → Edge Certificates | Minimum TLS Version: 1.2 | Drops outdated clients |
| SSL/TLS → Edge Certificates | HSTS: leave off | Caddy already sends the header |
| Caching → Cache Rules | Bypass cache when hostname equals `cloud.example.com` | Avoids stale JavaScript after Nextcloud updates and cached private files |
| Speed → Optimization | Rocket Loader: Off | Rewrites scripts and breaks the Nextcloud web UI |
| Security → Bots | Bot Fight Mode: Off | Blocks desktop and mobile sync clients |
| Network | WebSockets: On (default) | Needed by some Nextcloud apps |

**Upload limit.** The Free plan accepts at most 100 MB per request through the proxy. The Nextcloud web UI and the official desktop and mobile apps upload in chunks well below that, so normal use works. Single large uploads over WebDAV from third-party tools fail with HTTP 413. Under option A you can avoid the limit by switching the record to *DNS only*, at the cost of exposing your home IP.

**Timeouts.** Cloudflare waits up to 100 seconds for the origin to answer a request. Very slow operations (assembling a huge chunked upload on slow storage) can hit this; faster storage for the data directory helps.

**Optional WAF rule.** To cut noise, add a custom rule under *Security → WAF* that blocks requests to `cloud.example.com` from countries you never use. Test that your phone still syncs when travelling before tightening it.

## Part 7: Nextcloud post-install and hardening

Log in as the admin user and open *Administration settings → Overview*. Work through the warnings it lists; the steps below clear the common ones.

A shorthand for running `occ` in the container:

```bash
occ() { docker compose exec -u www-data nextcloud php occ "$@"; }
```

**Database and housekeeping.**

```bash
occ db:add-missing-indices
occ maintenance:repair --include-expensive
occ config:system:set default_phone_region --value=NL
occ config:system:set maintenance_window_start --type=integer --value=1   # 01:00 UTC
```

**Background jobs.** Under *Administration → Basic settings*, select **Cron**. The `cron` container runs them every 5 minutes.

**Changing the domain later.** The trusted domain set at install is not updated from `.env`. Use:

```bash
occ config:system:set trusted_domains 1 --value=new.example.com
```

**Pass the real client IP through.** Without this, Nextcloud logs and brute-force protection see Cloudflare or Docker addresses instead of the visitor. Nextcloud already trusts Caddy (`TRUSTED_PROXIES`); Caddy must also trust Cloudflare. The `Caddyfile` in this repository has both blocks below commented out in its global options; uncomment one.

Option B (tunnel), where `cloudflared` reaches Caddy from the Docker network:

```
{
	email {$ACME_EMAIL}
	servers {
		trusted_proxies static private_ranges
		client_ip_headers CF-Connecting-IP X-Forwarded-For
	}
}
```

Option A (port forward), where requests come from Cloudflare's public ranges. Add the module `--with github.com/WeidiDeng/caddy-cloudflare-ip` to the `xcaddy build` line in `caddy/Dockerfile`, then:

```
{
	email {$ACME_EMAIL}
	servers {
		trusted_proxies cloudflare
		client_ip_headers CF-Connecting-IP X-Forwarded-For
	}
}
```

The module fetches Cloudflare's current IP list itself. Apply with `docker compose up -d --build caddy` (as `nextcloud`). Check under *Administration → Logging* (or *Security → Devices & sessions*) that your own public IP appears.

**Account security.**

- Enable the *Two-Factor TOTP Provider* app and turn on 2FA for the admin account.
- Create a normal user for daily use; keep the admin account for administration only.
- Run the external check at [scan.nextcloud.com](https://scan.nextcloud.com) and aim for an A or A+ rating.

## Part 8: Back up to a Hetzner Storage Box

A nightly restic job on the VM backs up the user files, a database dump, Nextcloud's config and the stack folder to a Hetzner Storage Box over SFTP. Backups are encrypted on the VM before they leave, and only changed data is sent after the first run.

| What | Where on the VM | How |
| --- | --- | --- |
| User files | `/home/nextcloud/nextcloud-data` (NAS) | Read directly by restic |
| Database | `/var/backups/nextcloud/db.dump` | `pg_dump` in maintenance mode |
| Nextcloud config, apps, themes | `nextcloud_html` volume | Read directly by restic |
| Stack files and `.env` | `/home/nextcloud/nextcloud-stack` | Read directly by restic |

restic reads the user files from the NAS over NFS, so the VM must keep the share mounted and the NFS rule must have **no root squash**; with root squash, root on the VM is mapped to an anonymous user and cannot read folders owned by uid 33. The first run is limited by both the NAS link and your upload speed. If your NAS has its own snapshot feature, turn it on as well: it protects against accidental deletes between nightly backups.

### 1. Prepare the Storage Box

In the Hetzner Console open the Storage Box and, under *Change settings*, enable **SSH support** and **External reachability**. SSH and SFTP run on port **23**; port 22 gives no interactive access. Optionally create a sub-account for this VM so it only sees its own folder; then use the sub-account's username (`uXXXXX-sub1`) below.

Also enable **automatic snapshots** on the Storage Box. The VM can delete what it wrote, so if it is ever compromised, Storage Box snapshots are the copy an attacker cannot reach.

### 2. SSH key for root on the VM

The job runs as root, so the key belongs to root (the SSH config is also in `scripts/ssh-config.example`):

```bash
sudo -i
ssh-keygen -t ed25519 -f /root/.ssh/storagebox -N ""
ssh-copy-id -p 23 -s -i /root/.ssh/storagebox.pub uXXXXX@uXXXXX.your-storagebox.de
cat >> /root/.ssh/config <<'EOF'
Host storagebox
    HostName uXXXXX.your-storagebox.de
    User uXXXXX
    Port 23
    IdentityFile /root/.ssh/storagebox
EOF
chmod 600 /root/.ssh/config
sftp storagebox   # must log in without a password; type 'bye'
```

`ssh-copy-id` asks for the Storage Box password once. The `-s` flag uploads the key over SFTP, which the Storage Box needs.

### 3. Install restic and create the repository

```bash
apt install -y restic && restic self-update
openssl rand -hex 32 > /root/.restic-pass && chmod 600 /root/.restic-pass
cat > /root/.restic.env <<'EOF'
RESTIC_REPOSITORY=sftp:storagebox:./nextcloud-restic
RESTIC_PASSWORD_FILE=/root/.restic-pass
EOF
chmod 600 /root/.restic.env
set -a; . /root/.restic.env; set +a
restic init
```

**Store the restic password outside the VM** (in your password manager). Without it the backups cannot be decrypted, and Hetzner cannot recover it.

### 4. Backup script

The script is `scripts/nextcloud-backup.sh` in this repository. Install it:

```bash
sudo install -m 700 scripts/nextcloud-backup.sh /usr/local/sbin/
```

What it does:

1. Puts Nextcloud in maintenance mode and makes a `pg_dump` to `/var/backups/nextcloud/db.dump`, then leaves maintenance mode (a trap also switches it off if anything fails).
2. Runs `restic backup` over the dump, the NAS data path, the stack folder and the `config`, `custom_apps` and `themes` folders of the `nextcloud_html` volume, excluding caches and thumbnails.
3. Applies retention: 7 daily, 4 weekly, 6 monthly, and prunes.
4. On Sundays, checks 5% of the stored data for integrity.

Nextcloud is only in maintenance mode during the database dump. Files changed by users during the following file backup may be slightly newer than the dump; for a home setup that is acceptable, and a `files:scan` after a restore reconciles it. Thumbnails (`preview`) are excluded because Nextcloud regenerates them.

### 5. Schedule it with systemd

The units are in `systemd/` in this repository:

```bash
sudo install -m 644 systemd/nextcloud-backup.service systemd/nextcloud-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now nextcloud-backup.timer
sudo systemctl start nextcloud-backup.service     # first run now; can take hours
journalctl -u nextcloud-backup -f                 # follow progress
```

The timer runs every night at 03:00 (with up to 15 minutes random delay) and catches up after downtime. The first run uploads all user data, so it is limited by your upload speed. Later runs send only changes.

### 6. Check and test restores

```bash
sudo -i
set -a; . /root/.restic.env; set +a
restic snapshots                      # one per night
restic stats latest                   # size of the latest snapshot
restic restore latest --target /tmp/restore-test \
  --include /home/nextcloud/nextcloud-data/admin/files   # spot-check one user's files
```

**Full restore onto a new VM**, in outline:

1. Prepare the VM as in Part 3 (the nextcloud user and Docker, NAS share mounted at `~/nextcloud-data`, SSH key, restic env and password). If the NAS and its files survived, add `--exclude /home/nextcloud/nextcloud-data` to the restore in the next step so only the VM side comes back.
2. `restic restore latest --target /` puts back `/home/nextcloud/nextcloud-data`, `/home/nextcloud/nextcloud-stack` (with `.env`) and the dump.
3. Start only the database: `docker compose up -d db`, then load the dump: `docker compose exec -T db pg_restore -U nextcloud -d nextcloud --clean --if-exists < /var/backups/nextcloud/db.dump`.
4. Start Nextcloud once so it creates its volume, stop it, copy the restored `config`, `custom_apps` and `themes` into the volume, then start the full stack.
5. Run `occ maintenance:data-fingerprint` and `occ files:scan --all` so clients resync cleanly.

Test a restore at least once, and set a monthly reminder to glance at `restic snapshots`.

## Troubleshooting and maintenance

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Caddy log: certificate could not be obtained | Token wrong, expired or scoped to another zone | Re-run the verify call from Part 2; check `CF_API_TOKEN` in `.env` |
| Browser: too many redirects | SSL/TLS mode is Flexible | Set Full (strict) |
| Cloudflare error 525 or 526 | Caddy has no valid certificate yet | Check the Caddy log; wait for the first certificate |
| Cloudflare error 502 (tunnel) | Origin Server Name missing, or wrong service URL | Set `cloud.example.com` as Origin Server Name; URL `caddy:443`, type HTTPS |
| Cloudflare error 1033 | `cloudflared` not running | Start with `--profile tunnel`; check `CF_TUNNEL_TOKEN` |
| Cloudflare error 521 or 522 (option A) | Port forward missing, wrong VM IP, or CGNAT | Recheck the router rule; test `curl -k https://VM-IP` from the LAN |
| "Access through untrusted domain" | Domain differs from install-time trusted domain | `occ config:system:set trusted_domains 1 --value=…` |
| HTTP 413 on upload | Cloudflare 100 MB request cap | Use a chunking client, or DNS-only under option A |
| Links or redirects use `http://` | Overwrite settings missing | Check `OVERWRITEPROTOCOL` and `OVERWRITEHOST` in the compose file |
| Warnings about IP or proxy in Overview | Caddy not trusting Cloudflare | Uncomment the `servers` block from Part 7 |
| Stack does not start after reboot, or "data directory invalid" | NAS share not mounted (NAS off, IP changed, NFS rule wrong) | Start the NAS, then `sudo mount -a` and check `df -h ~/nextcloud-data`; Docker starts once the share is there |
| Backup log: permission denied on user files | NFS rule uses root squash | Set no root squash for the VM's IP on the NAS, then remount |

Useful checks: `docker compose ps`, `docker compose logs --tail=100 <service>`, and `occ status`.

**Updating.**

```bash
sudo -iu nextcloud
cd ~/nextcloud-stack
docker compose pull
docker compose up -d --build     # add --profile tunnel for option B
docker image prune -f
```

- Nextcloud can only move up one major version at a time. Pin `NEXTCLOUD_TAG` to a major (for example `31-apache`) once running, and raise it by one, start, and let the upgrade finish before the next step.
- A new Postgres major (for example 17 to 18) cannot read the old data directory. Upgrade by dump and restore, never by just changing `POSTGRES_TAG`.

**Backups.** Nightly backups to the Hetzner Storage Box are set up in Part 8. If a backup fails, `journalctl -u nextcloud-backup` shows why; the usual causes are a changed Storage Box password or key, a full Storage Box, the NAS share not mounted, or Nextcloud left in maintenance mode (`occ maintenance:mode --off`).
