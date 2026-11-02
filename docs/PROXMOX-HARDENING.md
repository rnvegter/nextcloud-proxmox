# Harden Proxmox, LXC containers and VMs

Every container or VM that Caddy publishes on the internet can be hacked one day, through a bug in the app, a weak password or a missing update. This guide makes sure that a hacked guest **can't reach the rest of your network**, **can't escape to the Proxmox host**, and **can be restored quickly**. It also puts a login page with two-factor authentication (Authelia) in front of web apps that don't need to be public.

**What you'll do**

| Step | What | Protects against |
| --- | --- | --- |
| 1 | Lock down the Proxmox host | Someone taking over the host and with it every guest |
| 2 | Firewall per guest | A hacked guest attacking your LAN, NAS or other guests |
| 3 | Harden LXC containers | A hacked container escaping to the host |
| 4 | Harden VMs | Same, for VMs |
| 5 | Basics inside every guest | Old software and guessed passwords |
| 6 | Authelia in front of web apps | Strangers reaching admin pages and tools |
| 7 | Backups | Losing everything after an attack |
| 8 | Optional: a separate DMZ network | Mistakes in the firewall rules |

**Assumptions in the examples**

| What | Address |
| --- | --- |
| LAN | `192.168.0.0/24` |
| UniFi gateway (router, DNS) | `192.168.0.1` (check yours: *UniFi → Settings → Networks*) |
| Proxmox host | `<PROXMOX_IP>` |
| Caddy proxy | `192.168.0.201` |
| Nextcloud VM | `192.168.0.202` |
| QNAP NAS | `192.168.0.249` |

- Caddy is set up as in [CADDY-PROXY.md](CADDY-PROXY.md), without plugins. [CADDY-HARDENING.md](CADDY-HARDENING.md) adds security headers, CrowdSec and rate limiting on top; that guide is separate and optional.
- Commands on the Proxmox host run as `root` in the host's *Shell* (select the node → *>_ Shell*), unless a step says otherwise. `<ID>` is the number of a container or VM (for example `101`).

**Keep a way back in.** Firewall mistakes can lock you out. Before Step 1, check that you can reach the Proxmox host's screen and keyboard directly (or through a KVM/IPMI). Do the steps one at a time and test after each.

## Step 1: Lock down the Proxmox host

The host controls every guest. Whoever owns the host owns everything.

### Never put the Proxmox web interface on the internet

Port `8006` (web interface) and `22` (SSH) of the host are never forwarded on the FritzBox or UniFi gateway, and there is never a Caddy site for them. To manage Proxmox from outside, use a VPN (Tailscale or WireGuard) to your home network.

### Turn on two-factor login

1. *Datacenter → Permissions → Two Factor → Add → TOTP*.
2. User: `root@pam`. Scan the QR code with your authenticator app (for example Aegis, 2FAS or your password manager) and enter the code.
3. Also add *Recovery Keys* on the same page and store them in your password manager.

Log out and log in again: Proxmox now asks for the 6-digit code.

### Keep the host up to date

Proxmox needs `full-upgrade`, not `upgrade`:

```bash
apt update
```

```bash
apt full-upgrade
```

After a kernel update (the output mentions `proxmox-kernel`), reboot the host when it suits you. **This matters more than usual:** all LXC containers share the host's kernel, so an old kernel is a risk for every container.

### Firewall on the host

The Proxmox firewall works on three levels: *Datacenter* (rules for the host), *node*, and each guest. Guests are only filtered when the firewall is on at Datacenter level **and** on the guest itself. Turning it on at Datacenter level doesn't change anything for guests yet.

First allow management from your LAN, so you don't lock yourself out:

```bash
nano /etc/pve/firewall/cluster.fw
```

If the file is empty or doesn't exist, paste:

```
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
IN ACCEPT -source 192.168.0.0/24 -p tcp -dport 8006 -log nolog # web interface from LAN
IN ACCEPT -source 192.168.0.0/24 -p tcp -dport 22 -log nolog # SSH from LAN
IN ACCEPT -source 192.168.0.0/24 -p icmp -log nolog # ping from LAN
```

If the file already has content, add only the three `IN ACCEPT` lines under `[RULES]` and set `enable: 1` under `[OPTIONS]`.

Check in the browser: *Datacenter → Firewall* shows the rules and *Datacenter → Firewall → Options* shows *Firewall: Yes*. Open a **new** browser tab to `https://<PROXMOX_IP>:8006` to check that you can still log in. Something wrong? On the host's own screen, set `enable: 0` in `/etc/pve/firewall/cluster.fw`.

If you reach Proxmox over Tailscale running on the host itself, add `IN ACCEPT -source 100.64.0.0/10 -p tcp -dport 8006` as well.

### SSH on the host: keys only

Put your SSH key on the host first (from your own computer: `ssh-copy-id root@<PROXMOX_IP>`) and check that `ssh root@<PROXMOX_IP>` logs in without a password. Then:

```bash
nano /etc/ssh/sshd_config.d/10-hardening.conf
```

```
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
```

`prohibit-password` keeps root login with a key working; Proxmox needs that for some tasks. Check and apply:

```bash
sshd -t
```

```bash
systemctl reload ssh
```

Keep the current SSH session open and test in a new one.

## Step 2: Firewall per guest

This is the most important step. Each internet-facing guest gets two kinds of rules:

- **IN:** only the traffic it really needs. The backend app only accepts traffic from Caddy; Caddy accepts web traffic from the internet.
- **OUT:** no traffic to your LAN (NAS, PCs, Proxmox host), except what it really needs (DNS from the router, the NAS for Nextcloud). Internet stays open for updates and certificates.

The firewall is *stateful*: replies to allowed traffic always come back. You only write rules for who may **start** a connection.

The firewall runs on the Proxmox host, outside the guest. A hacker inside the guest can't switch it off, and Docker inside a VM can't get around it either.

### Turn on the firewall on the guest's network card

For every guest below: select the guest → *Network* (VM: *Hardware*) → double-click the network card (`net0`) → tick **Firewall** → *OK*. For a container this applies straight away. For a running VM, if the change shows in red (pending), shut the VM down and start it again (a reboot from inside the VM is not enough).

### Caddy proxy (`192.168.0.201`)

Look up its ID in the left column (for example `101`), then:

```bash
nano /etc/pve/firewall/<ID>.fw
```

```
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
IN ACCEPT -p tcp -dport 80 -log nolog # web traffic from internet
IN ACCEPT -p tcp -dport 443 -log nolog # web traffic from internet
IN ACCEPT -source 192.168.0.0/24 -p tcp -dport 22 -log nolog # SSH from LAN
OUT ACCEPT -dest 192.168.0.202 -p tcp -dport 8080 -log nolog # to Nextcloud
OUT ACCEPT -dest 192.168.0.1 -p udp -dport 53 -log nolog # DNS from router
OUT ACCEPT -dest 192.168.0.1 -p tcp -dport 53 -log nolog # DNS from router
OUT DROP -dest 10.0.0.0/8 -log info # rest of private networks
OUT DROP -dest 172.16.0.0/12 -log info
OUT DROP -dest 192.168.0.0/16 -log info
```

Rules are checked top to bottom; the first match wins. That's why the `OUT ACCEPT` lines come before the `OUT DROP` lines. Every new app behind Caddy gets its own `OUT ACCEPT` line to its address and port, **above** the `DROP` lines.

### Nextcloud VM (`192.168.0.202`)

```bash
nano /etc/pve/firewall/<ID>.fw
```

```
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: ACCEPT

[RULES]
IN ACCEPT -source 192.168.0.201 -p tcp -dport 8080 -log nolog # from Caddy only
IN ACCEPT -source 192.168.0.0/24 -p tcp -dport 22 -log nolog # SSH from LAN
OUT ACCEPT -dest 192.168.0.249 -log nolog # NFS to the QNAP
OUT ACCEPT -dest 192.168.0.1 -p udp -dport 53 -log nolog # DNS from router
OUT ACCEPT -dest 192.168.0.1 -p tcp -dport 53 -log nolog # DNS from router
OUT DROP -dest 10.0.0.0/8 -log info
OUT DROP -dest 172.16.0.0/12 -log info
OUT DROP -dest 192.168.0.0/16 -log info
```

Port `8080` is now only reachable from Caddy. If you also want to open `http://192.168.0.202:8080` from your own PC, add `IN ACCEPT -source <YOUR_PC_IP> -p tcp -dport 8080`.

### Any other internet-facing guest

Use the Nextcloud file as a template: `IN` only from Caddy on the app's port, SSH from the LAN, `OUT` only what the app needs, then the three `DROP` lines.

### IPv6

If your LAN uses IPv6, block the local IPv6 ranges too. Add these above the `IPv4 DROP` lines:

```
OUT DROP -dest fc00::/7 -log info
OUT DROP -dest fe80::/10 -log info
```

### Check the firewall

1. `https://nextcloud.dockerapp.org` still works from your phone on mobile data.
2. From a shell **inside** the Nextcloud VM, try to reach the Proxmox host. It must hang and fail (Ctrl+C to stop):

```bash
curl -m 5 -k https://<PROXMOX_IP>:8006
```

3. Same VM, the internet still works:

```bash
curl -m 5 -I https://deb.debian.org
```

4. Blocked attempts show in the guest's *Firewall → Log* in the Proxmox web interface.

## Step 3: Harden LXC containers

A container shares the kernel with the host. A container that is set up loosely is one bug away from the host.

### Use unprivileged containers only

In an *unprivileged* container, `root` inside is a normal, powerless user on the host. Check every container:

```bash
pct config <ID>
```

You want to see `unprivileged: 1`. If that line is missing, the container is **privileged**. Convert it:

1. Make a backup: select the container → *Backup → Backup now* (mode *Stop*).
2. *Restore* that backup to a new ID and tick **Unprivileged container** in the restore dialog. Proxmox converts the file owners.
3. Start the new container, test it, then delete the old one.

### Keep the special features off

```bash
grep -E '^(features|dev[0-9]|mp[0-9]|lxc\.)' /etc/pve/lxc/*.conf
```

What you may see, and what to do:

| Line | Meaning | Advice |
| --- | --- | --- |
| `features: nesting=1` | Default for new unprivileged containers; modern systemd needs it | OK in an unprivileged container |
| `features: keyctl=1` | Needed for Docker inside a container | For internet-facing apps: run Docker in a **VM** instead |
| `mp0: /some/host/path,…` | A host folder is visible in the container | Only when needed; add `,ro=1` if the container only reads |
| `dev0: …` | A host device is passed in | Never on an internet-facing container |
| `lxc.apparmor.profile: unconfined` | Switches off AppArmor protection | Remove the line |
| `lxc.cap.drop:` (empty) or `lxc.cgroup…devices.allow: a` | Removes protection | Remove the line |

Change a `features` setting with, for example:

```bash
pct set <ID> --features nesting=1
```

### Limit memory and CPU

Give each container a fixed limit (*Resources → Memory / Cores*), so an attack or a runaway process can't slow down the host and all other guests. Set *Swap* to the same value as *Memory* or lower.

### Put the riskiest apps in a VM

A VM has its own kernel, so a break-out is much harder. Use a VM for apps with a large attack surface: Nextcloud (already a VM), anything with PHP plugins, anything running Docker, game servers. Small, simple services (Caddy, a static site) are fine in a container.

## Step 4: Harden VMs

- **No hardware passthrough** (USB, PCI, GPU) to internet-facing VMs. It gives the VM direct access to host hardware.
- **Firmware:** for new VMs, choose *BIOS: OVMF (UEFI)* with an *EFI disk* and *Pre-Enroll keys* ticked, so Secure Boot is on.
- **Guest agent:** `qemu-guest-agent` is fine and makes backups consistent. Turn it on with *Options → QEMU Guest Agent → Use QEMU Guest Agent* and install it in the VM:

```bash
sudo apt install qemu-guest-agent
```

- **Shared storage:** mount only the NAS folders the VM really needs, and read-only where possible. The Nextcloud VM needs read-write to `/nextcloud` on the QNAP; keep QNAP snapshots on for that share, so files deleted or encrypted through a hacked Nextcloud can be restored.
- **Limits:** set fixed memory and cores, like for containers.

## Step 5: Basics inside every guest

Do this in every container and VM. In a container, open the console as `root`; in a VM, use `sudo`. The commands below are without `sudo`; add it in a VM.

### Automatic security updates

```bash
apt install unattended-upgrades
```

```bash
dpkg-reconfigure -plow unattended-upgrades
```

Answer *Yes*. Security updates are now installed every day. To also reboot automatically when an update needs it:

```bash
nano /etc/apt/apt.conf.d/52unattended-upgrades-local
```

```
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
```

Updates of the app itself (Nextcloud images, Caddy) are not covered by this. Keep doing those by hand, once a month or when a security update is announced.

### SSH: keys only, or no SSH at all

Don't need SSH into a container? Use the Proxmox console instead and remove the server:

```bash
apt purge openssh-server
```

If you do use SSH, put your key in first (`ssh-copy-id <user>@<guest-ip>`), check that it works, then:

```bash
nano /etc/ssh/sshd_config.d/10-hardening.conf
```

```
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
```

```bash
sshd -t
```

```bash
systemctl reload ssh
```

(On Ubuntu, the service may be called `ssh` or `sshd`; one of the two works.)

### Run apps as a normal user

Apps should not run as `root` inside the guest. Packages from `apt` (Caddy, Authelia) already create their own user. For Docker stacks, the `docker compose` commands run as a normal user (like `nextcloud` in [MANUAL.md](MANUAL.md)).

### Install as little as possible

Every extra package is extra code that can have a bug. Don't install tools "just in case", and remove what you no longer use:

```bash
apt autoremove --purge
```

## Step 6: Authelia in front of web apps

Many self-hosted apps have a weak login or none at all: dashboards, admin pages, tools. Authelia puts a login page with password and two-factor authentication in front of them. Only after logging in does Caddy forward the visitor to the app. Caddy's `forward_auth` does this without plugins.

**Don't put Authelia in front of Nextcloud.** The Nextcloud desktop and phone apps, WebDAV and calendar/contact sync can't get through an extra login page. Use Nextcloud's own two-factor login instead (*Apps → Two-Factor TOTP Provider*, then *Personal settings → Security*).

Authelia runs on the Caddy guest itself, so no extra firewall rules are needed.

The examples use `auth.dockerapp.org` for the login page and `app.dockerapp.org` for the app you protect. Create an A record for both in the `dockerapp.org` zone, pointing to your public IP (like `nextcloud` in CADDY-PROXY.md). Ports 80 and 443 are already forwarded to Caddy.

All commands in this step run as `root` on the Caddy guest.

### 1. Install Authelia

```bash
apt install ca-certificates curl gnupg
```

```bash
curl -fsSL https://www.authelia.com/keys/authelia-security.gpg -o /usr/share/keyrings/authelia-security.gpg
```

```bash
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/authelia-security.gpg] https://apt.authelia.com stable main" > /etc/apt/sources.list.d/authelia.list
```

```bash
apt update
```

```bash
apt install authelia
```

### 2. Make three secrets

Run this three times and keep the three outputs for part 5:

```bash
authelia crypto rand --length 64 --charset alphanumeric
```

### 3. Make a password hash for your user

Authelia stores a hash, never the password itself. Enter the password when asked and copy the line that starts with `$argon2id$`:

```bash
authelia crypto hash generate argon2
```

### 4. Create the user file

```bash
mkdir -p /var/lib/authelia
```

```bash
nano /etc/authelia/users_database.yml
```

```yaml
users:
  <USERNAME>:
    displayname: '<YOUR NAME>'
    password: '<ARGON2_HASH>'
    email: '<YOUR_EMAIL>'
    groups:
      - 'admins'
```

For more people (family), add a block per person under `users:`, each with their own hash.

### 5. Create the configuration

```bash
cp /etc/authelia/configuration.yml /etc/authelia/configuration.yml.bak
```

(If this says the file doesn't exist, that's fine.)

```bash
nano /etc/authelia/configuration.yml
```

Replace the contents with this and fill in the three secrets:

```yaml
server:
  address: 'tcp://127.0.0.1:9091/'

log:
  level: 'info'

totp:
  issuer: 'dockerapp.org'

identity_validation:
  reset_password:
    jwt_secret: '<SECRET_1>'

authentication_backend:
  file:
    path: '/etc/authelia/users_database.yml'

access_control:
  default_policy: 'deny'
  rules:
    - domain: '*.dockerapp.org'
      policy: 'two_factor'

session:
  secret: '<SECRET_2>'
  cookies:
    - domain: 'dockerapp.org'
      authelia_url: 'https://auth.dockerapp.org'

storage:
  encryption_key: '<SECRET_3>'
  local:
    path: '/var/lib/authelia/db.sqlite3'

notifier:
  filesystem:
    filename: '/var/lib/authelia/notification.txt'
```

What this does:

- Authelia only listens on `127.0.0.1`, so only Caddy on the same guest can reach it.
- `default_policy: deny` plus one rule: every protected app under `dockerapp.org` needs password **and** 2FA.
- You log in once for all subdomains of `dockerapp.org`.
- Authelia sends no emails. One-time codes go to `notification.txt` (you need it in part 7).
- After several wrong passwords, Authelia blocks that user for a while.

Keep the files private, because they contain the secrets:

```bash
chmod 600 /etc/authelia/configuration.yml /etc/authelia/users_database.yml
```

Check the configuration:

```bash
authelia validate-config --config /etc/authelia/configuration.yml
```

Start Authelia and start it on every boot:

```bash
systemctl enable --now authelia
```

```bash
systemctl status authelia
```

### 6. Add the sites to Caddy

```bash
cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak
```

```bash
nano /etc/caddy/Caddyfile
```

Add at the end. Replace `192.168.0.x:port` with the address and port of the app you protect:

```
auth.dockerapp.org {
	reverse_proxy 127.0.0.1:9091
}

app.dockerapp.org {
	forward_auth 127.0.0.1:9091 {
		uri /api/authz/forward-auth
		copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
	}
	reverse_proxy 192.168.0.x:port
}
```

```bash
caddy fmt --overwrite /etc/caddy/Caddyfile
```

```bash
caddy validate --config /etc/caddy/Caddyfile
```

```bash
systemctl reload caddy
```

Then, on the Proxmox host, allow Caddy to reach the app: add an `OUT ACCEPT -dest 192.168.0.x -p tcp -dport <port>` line to Caddy's firewall file (Step 2), above the `DROP` lines. Give the app's own guest a firewall file that only accepts that port from `192.168.0.201`.

For every next app: copy the `app.dockerapp.org` block, change the name and the address, add a DNS record, and add the firewall lines.

### 7. Set up your second factor

1. Open `https://app.dockerapp.org`. You land on the Authelia login page. Log in with your username and password.
2. Choose *Register device* → *One-Time Password*. Authelia asks for a confirmation code; read it on the Caddy guest:

```bash
cat /var/lib/authelia/notification.txt
```

3. Enter the code, scan the QR code with your authenticator app and enter the 6-digit code.
4. You're sent on to the app. Close the browser and open it again: Authelia asks for the 6-digit code again.

## Step 7: Backups

If a guest is hacked anyway, you don't repair it: you delete it and restore a clean backup from before the attack.

1. *Datacenter → Backup → Add*.
2. *Storage:* a backup storage that is **not** reachable from the guests (the guests' firewall rules from Step 2 block the NAS, except the Nextcloud share).
3. *Schedule:* daily, at night. *Selection mode:* all guests. *Mode:* Snapshot.
4. *Retention:* for example keep 7 daily, 4 weekly and 3 monthly backups.
5. Turn on *Notification* by email, so you know when a backup fails.

Keep a copy outside your house as well (the Nextcloud data already goes to the Hetzner Storage Box with restic, see [MANUAL.md](MANUAL.md)). Proxmox Backup Server is a good next step: it makes smaller, incremental backups and can sync them offsite.

**Test a restore** a few times a year: restore a backup to a new, unused ID, start it with the network card disconnected, check it, then delete it.

## Step 8 (optional): A separate DMZ network

Step 2 isolates guests with firewall rules in the same network. A separate network (a VLAN) for internet-facing guests adds a second wall: even if a firewall rule is wrong, the router still blocks traffic from the DMZ to your LAN.

It is more work, and the addresses of Caddy and Nextcloud change, so the port forwards and the Nextcloud proxy settings in CADDY-PROXY.md must be updated too. Outline:

1. **UniFi:** *Settings → Networks → New Virtual Network*, name `DMZ`, VLAN ID `30`, subnet `192.168.30.0/24`.
2. **UniFi firewall:** block `DMZ → Internal` (LAN); allow `Internal → DMZ`, so you can still manage the guests.
3. **Switch port** to the Proxmox host: its port profile must carry VLAN 30 (*Allow All* or a profile with tagged VLAN 30).
4. **Proxmox:** node → *System → Network → vmbr0 → Edit → VLAN aware* ✓, then *Apply Configuration*.
5. **Guests:** network card → *VLAN Tag* `30`, and a new fixed address in `192.168.30.0/24`.
6. Update the port forwards (to Caddy's new address), `TRUSTED_PROXIES` in Nextcloud, and the firewall files from Step 2.

## Checklist per internet-facing guest

| Check | How |
| --- | --- |
| Firewall on, at Datacenter level and on the network card | *Firewall → Options*; *Network → net0 → Firewall* ✓ |
| IN: only Caddy (or only 80/443 for Caddy itself) | `/etc/pve/firewall/<ID>.fw` |
| OUT: LAN blocked except what is needed | Same file; the test from Step 2 |
| Unprivileged (containers) | `pct config <ID>` shows `unprivileged: 1` |
| No `keyctl`, `dev`, `lxc.` overrides, no passthrough | `pct config <ID>` / *Hardware* |
| Automatic security updates | `systemctl status unattended-upgrades` |
| SSH keys only, or no SSH | `/etc/ssh/sshd_config.d/10-hardening.conf` |
| Login with 2FA (Authelia or the app's own) | Open the site in a private browser window |
| In the daily backup, restore tested | *Datacenter → Backup* |

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Locked out of the Proxmox web interface | Datacenter firewall without the LAN rules | On the host's screen: set `enable: 0` in `/etc/pve/firewall/cluster.fw`, fix the rules, set it back to `1` |
| Guest firewall rules do nothing | Firewall not ticked on the network card, or off at Datacenter level | Tick *Firewall* on `net0`; *Datacenter → Firewall → Options → Firewall: Yes* |
| Site gives `502 Bad Gateway` after Step 2 | Caddy's `OUT` rule or the app's `IN` rule is missing | Add `OUT ACCEPT` to the app in Caddy's file and `IN ACCEPT -source 192.168.0.201` in the app's file |
| Nextcloud VM: NAS mount hangs | `OUT ACCEPT -dest 192.168.0.249` missing or below the `DROP` lines | Move the line above the `DROP` lines |
| Guest can't install updates | DNS blocked | Check the two `OUT ACCEPT … -dport 53` lines and that `192.168.0.1` is really your DNS server (`cat /etc/resolv.conf` in the guest) |
| Container doesn't start after converting to unprivileged | Files with wrong owners, or a feature it needs | Check `journalctl` in the container; restore the old backup if needed |
| Authelia won't start | Error in the configuration | `authelia validate-config --config /etc/authelia/configuration.yml` shows the line |
| Authelia: redirect loop or "There was an issue retrieving the current user state" | Cookie domain or `authelia_url` wrong | `session.cookies` must say `dockerapp.org` and `https://auth.dockerapp.org`; check `journalctl -u authelia` |
| `auth.dockerapp.org` has no certificate | DNS record missing | Add the A record; watch `journalctl -u caddy -f` |
