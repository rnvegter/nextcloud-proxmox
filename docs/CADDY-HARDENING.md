# Harden the Caddy proxy

[CADDY-PROXY.md](CADDY-PROXY.md) puts Nextcloud on the internet. This guide adds three layers of protection on the Caddy machine (`192.168.0.201`):

1. **Security headers and TLS.** Caddy tells browsers to always use HTTPS and not to guess file types.
2. **CrowdSec, rate limiting and GeoIP.** Caddy blocks known attackers, slows down password guessing and, if you want, only lets in visitors from the EU.
3. **Two-factor login.** Nextcloud uses its own 2FA. Other web apps you publish later get a login page from Authelia in front of them.

```
Visitor ─▶ FritzBox ─▶ UniFi ─▶ Caddy 192.168.0.201
                                  ├─ CrowdSec check, GeoIP check, rate limit
                                  ├─ nextcloud.dockerapp.org ─▶ Nextcloud (own 2FA)
                                  └─ app.dockerapp.org ─▶ Authelia login ─▶ app
```

**Before you start**

- CADDY-PROXY.md is done and `https://nextcloud.dockerapp.org` works.
- Caddy runs on Debian or Ubuntu and was installed with `apt` (it has `/etc/caddy/Caddyfile` and `systemctl reload caddy` works).
- All commands run as `root` on the Caddy machine, unless a step says otherwise.
- Back up the Caddyfile before every step:

```bash
cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak
```

If something breaks, put the backup back with `cp /etc/caddy/Caddyfile.bak /etc/caddy/Caddyfile` and `systemctl reload caddy`.

## Step 1: Add the plugins to Caddy

The standard Caddy has no CrowdSec, rate limiting or GeoIP. `caddy add-package` downloads a Caddy with these plugins built in and replaces the program.

```bash
caddy add-package github.com/hslatman/caddy-crowdsec-bouncer/http github.com/mholt/caddy-ratelimit github.com/porech/caddy-maxmind-geolocation
```

Check that the plugins are there. You should see three lines:

```bash
caddy list-modules | grep -E 'crowdsec|rate_limit|maxmind'
```

Stop `apt` from replacing your Caddy with the plain version on the next update:

```bash
apt-mark hold caddy
```

```bash
systemctl restart caddy
```

**Updating Caddy from now on:** `apt upgrade` skips Caddy. Update it with `caddy upgrade` (this keeps the plugins), then `systemctl restart caddy`. Do this once a month, together with your other updates.

## Step 2: Security headers and TLS

### TLS: already good

Caddy gets and renews the certificates by itself, sends `http://` visitors to `https://`, and only allows TLS 1.2 and 1.3 with strong ciphers. You don't need to change anything. Don't add `tls` settings unless you know why.

### Security headers

The headers go in a snippet: a reusable block at the top of the Caddyfile that every site loads with one `import` line.

```bash
nano /etc/caddy/Caddyfile
```

Add this **at the top of the file** (above all sites):

```
(hardening) {
	log {
		output file /var/log/caddy/{args[0]}.log
	}
	header {
		defer
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "SAMEORIGIN"
		Referrer-Policy "no-referrer"
		X-Robots-Tag "noindex, nofollow"
		-Server
		-X-Powered-By
	}
}
```

What each line does:

| Header | Effect |
| --- | --- |
| `Strict-Transport-Security` | The browser only uses HTTPS for this domain for one year (HSTS) |
| `X-Content-Type-Options nosniff` | The browser doesn't guess file types, so an uploaded file can't run as a script |
| `X-Frame-Options SAMEORIGIN` | Other sites can't load your pages in a frame (stops clickjacking) |
| `Referrer-Policy no-referrer` | Your URLs aren't sent to other sites when you click a link |
| `X-Robots-Tag` | Search engines don't index your private sites |
| `-Server`, `-X-Powered-By` | Removes headers that show which software you run |
| `defer` | Caddy's values replace the ones Nextcloud sends, so there are no double headers |
| `log` | Writes an access log per site to `/var/log/caddy/<name>.log`; CrowdSec reads it in Step 3 |

These values match what Nextcloud's own security check expects. Don't use the `preload` option for HSTS: getting a domain off the browser preload list takes months.

Now load the snippet in the Nextcloud site. Replace the whole `nextcloud.dockerapp.org { … }` block with this (the old `Strict-Transport-Security` line moves into the snippet):

```
nextcloud.dockerapp.org {
	import hardening nextcloud
	request_body {
		max_size 10GB
	}
	redir /.well-known/carddav /remote.php/dav/ 301
	redir /.well-known/caldav /remote.php/dav/ 301
	reverse_proxy 192.168.0.202:8080
}
```

`nextcloud` after `import hardening` is the name of the log file. Use a different name for every site.

```bash
caddy fmt --overwrite /etc/caddy/Caddyfile
```

```bash
caddy validate --config /etc/caddy/Caddyfile
```

```bash
systemctl reload caddy
```

Check the headers:

```bash
curl -sI https://nextcloud.dockerapp.org/login
```

You should see `strict-transport-security`, `x-content-type-options: nosniff` and the other headers, each only once, and no `server: Caddy`. For a full report, enter your domain at [securityheaders.com](https://securityheaders.com) and [SSL Labs](https://www.ssllabs.com/ssltest/) (aim for A or A+).

## Step 3: CrowdSec

CrowdSec reads Caddy's access logs and recognizes attacks: scanners looking for `wp-admin` or `.env` files, password guessing, known exploits. It bans the attacking IP address, and Caddy (through the bouncer plugin from Step 1) then answers that address with `403 Forbidden`. You also get the community blocklist: addresses that other CrowdSec users have already seen attacking.

CrowdSec never bans addresses from your own LAN (`192.168.x.x`); it whitelists private addresses by default.

### Install CrowdSec

Add the CrowdSec package source:

```bash
curl -s https://install.crowdsec.net | sh
```

```bash
apt install crowdsec
```

Install the rules for Caddy logs:

```bash
cscli collections install crowdsecurity/caddy
```

### Tell CrowdSec where the logs are

```bash
nano /etc/crowdsec/acquis.d/caddy.yaml
```

Paste:

```yaml
filenames:
  - /var/log/caddy/*.log
labels:
  type: caddy
```

```bash
systemctl restart crowdsec
```

### Connect Caddy to CrowdSec

Create a key for Caddy:

```bash
cscli bouncers add caddy-bouncer
```

Copy the key it prints; it is shown only once.

```bash
nano /etc/caddy/Caddyfile
```

Add a global options block as the **very first thing in the file**, above the `(hardening)` snippet. Put your key in place of `<BOUNCER_KEY>`:

```
{
	order crowdsec first
	crowdsec {
		api_url http://127.0.0.1:8080
		api_key <BOUNCER_KEY>
	}
}
```

Then add `crowdsec` as the first line inside the `(hardening)` snippet, so every site that imports it is protected:

```
(hardening) {
	crowdsec
	log {
	…
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

### Check CrowdSec

Open Nextcloud once so there are log lines, then check that CrowdSec reads them. Under *Acquisition Metrics* you should see `/var/log/caddy/nextcloud.log` with lines read and parsed:

```bash
cscli metrics
```

Test a ban with your phone (Wi-Fi off). Look up the phone's public IP on [ifconfig.me](https://ifconfig.me), then ban it for five minutes:

```bash
cscli decisions add --ip <PHONE_IP> --duration 5m
```

Open `https://nextcloud.dockerapp.org` on the phone: you get `403 Forbidden`. Remove the ban:

```bash
cscli decisions delete --ip <PHONE_IP>
```

See who is banned at any time:

```bash
cscli decisions list
```

## Step 4: Rate limiting on the login page

Nextcloud already slows down repeated wrong passwords (brute-force protection). A rate limit in Caddy stops a password-guessing attack before it reaches Nextcloud at all.

The limit only covers **login attempts**, not normal traffic. The desktop and phone apps send hundreds of requests during a sync; a limit on everything would break them.

Add this to the Nextcloud site, below `import hardening nextcloud`:

```
	rate_limit {
		zone nextcloud_login {
			match {
				method POST
				path /login /index.php/login
			}
			key {remote_host}
			events 10
			window 1m
		}
	}
```

This allows 10 login attempts per minute per IP address. Number 11 gets `429 Too Many Requests` until the minute is over.

```bash
caddy fmt --overwrite /etc/caddy/Caddyfile
```

```bash
caddy validate --config /etc/caddy/Caddyfile
```

```bash
systemctl reload caddy
```

## Step 5 (optional): Only allow visitors from the EU

Most attacks come from outside the EU. A GeoIP filter answers every visitor from outside the EU with `403`.

**Think about this first:** you can't reach Nextcloud yourself when you travel outside the EU (the phone app stops syncing too). If that happens, change the country list, or use the VPN back home. Let's Encrypt keeps working: Caddy answers its certificate checks before the filter runs.

### Get the free GeoIP database

1. Create a free account at [maxmind.com/en/geolite2/signup](https://www.maxmind.com/en/geolite2/signup).
2. In your account, open *Manage License Keys* and create a key. Note the **Account ID** and the **License key**.

Install the updater. On Debian, `contrib` must be enabled in `/etc/apt/sources.list` for this package:

```bash
apt install geoipupdate
```

```bash
nano /etc/GeoIP.conf
```

Set these three lines (leave the rest):

```
AccountID <YOUR_ACCOUNT_ID>
LicenseKey <YOUR_LICENSE_KEY>
EditionIDs GeoLite2-Country
```

Download the database:

```bash
geoipupdate
```

Check that the file exists:

```bash
ls -l /var/lib/GeoIP/GeoLite2-Country.mmdb
```

Update it every week. Open root's crontab:

```bash
crontab -e
```

Add this line (Wednesday 04:00):

```
0 4 * * 3 /usr/bin/geoipupdate && systemctl reload caddy
```

### Add the filter to Caddy

```bash
nano /etc/caddy/Caddyfile
```

Add a second snippet below `(hardening)`:

```
(eu_only) {
	@outside_eu {
		not remote_ip private_ranges
		not {
			maxmind_geolocation {
				db_path /var/lib/GeoIP/GeoLite2-Country.mmdb
				allow_countries AT BE BG CY CZ DE DK EE ES FI FR GR HR HU IE IT LT LU LV MT NL PL PT RO SE SI SK
			}
		}
	}
	respond @outside_eu 403
}
```

`not remote_ip private_ranges` keeps your own LAN working: private addresses have no country and would otherwise be blocked. Want only the Netherlands? Use `allow_countries NL`. Add `CH NO GB` if you need those.

Load it in the site, below `import hardening nextcloud`:

```
	import eu_only
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

Test it: open the site through a VPN with a location outside the EU (for example the US). You get `403`. From your phone on mobile data it still works.

## Step 6: Two-factor login

### Nextcloud: use its own 2FA, not Authelia

Don't put Authelia in front of Nextcloud. The desktop client, the phone apps, WebDAV and CalDAV/CardDAV can't log in through an extra login page, so they would stop working. Nextcloud has its own two-factor login that works with all of them.

On the Nextcloud VM, as `nextcloud`:

```bash
cd ~/nextcloud-proxmox
```

```bash
docker compose exec -u www-data nextcloud php occ app:enable twofactor_totp
```

Then, in the browser:

1. *Personal settings → Security → Two-Factor Authentication*: tick *Enable TOTP*, scan the QR code with an authenticator app (for example Aegis, 2FAS or your password manager) and enter the code.
2. On the same page, generate **backup codes** and store them in your password manager.
3. Phone and desktop apps: log in again through the browser window the app opens. Each app gets its own app password, so you don't need a code each time.

When every user has 2FA set up, make it required for everybody:

```bash
docker compose exec -u www-data nextcloud php occ twofactorauth:enforce --on
```

Users without 2FA are asked to set it up at their next login.

### Other web apps: Authelia in front

Use Authelia for apps that only you (and your family) use in a browser and that have weak or no login of their own: dashboards, admin pages, tools. Authelia shows a login page with password and 2FA; only after that does Caddy forward the visitor to the app. Authelia runs on the Caddy machine itself.

The examples use `auth.dockerapp.org` for the login page and `app.dockerapp.org` for the app. Create an A record for both in the `dockerapp.org` zone, pointing to your public IP (like `nextcloud` in CADDY-PROXY.md). The port forwards for 80 and 443 already exist.

**1. Install Authelia**

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

**2. Make three secrets**

Run this three times and keep the three outputs for the next step:

```bash
authelia crypto rand --length 64 --charset alphanumeric
```

**3. Make a password hash for your user**

Authelia stores a hash, never the password itself. Enter the password when asked and copy the line that starts with `$argon2id$`:

```bash
authelia crypto hash generate argon2
```

**4. Create the user file**

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

**5. Create the configuration**

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

- Authelia only listens on `127.0.0.1`: only Caddy on the same machine can reach it.
- `default_policy: deny` plus one rule: every protected app under `dockerapp.org` needs password **and** 2FA.
- The login is remembered for all subdomains of `dockerapp.org`, so you log in once for all apps.
- Authelia sends no emails; one-time codes go to `notification.txt` (you need it in part 7 below). Authelia also blocks a user for a while after several wrong passwords.

Keep the files private, because they contain the secrets:

```bash
chmod 600 /etc/authelia/configuration.yml /etc/authelia/users_database.yml
```

Check the configuration, then start Authelia:

```bash
authelia validate-config --config /etc/authelia/configuration.yml
```

```bash
systemctl enable --now authelia
```

```bash
systemctl status authelia
```

**6. Add the sites to Caddy**

```bash
nano /etc/caddy/Caddyfile
```

Add at the end. Replace `192.168.0.x:port` with the address of the app you're protecting:

```
auth.dockerapp.org {
	import hardening auth
	reverse_proxy 127.0.0.1:9091
}

app.dockerapp.org {
	import hardening app
	forward_auth 127.0.0.1:9091 {
		uri /api/authz/forward-auth
		copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
	}
	reverse_proxy 192.168.0.x:port
}
```

For every next app, copy the `app.dockerapp.org` block, change the name, the log name and the address, and add its DNS record. Add `import eu_only` too if you use Step 5.

```bash
caddy fmt --overwrite /etc/caddy/Caddyfile
```

```bash
caddy validate --config /etc/caddy/Caddyfile
```

```bash
systemctl reload caddy
```

**7. Set up your second factor**

1. Open `https://app.dockerapp.org`. You land on the Authelia login page. Log in with your username and password.
2. Choose *Register device* → *One-Time Password*. Authelia asks for a confirmation code; read it on the Caddy machine:

```bash
cat /var/lib/authelia/notification.txt
```

3. Enter the code, scan the QR code with your authenticator app and enter the 6-digit code.
4. You're sent on to the app. Close the browser and open it again: Authelia asks for the 6-digit code again.

## Step 7: Check everything

1. `curl -sI https://nextcloud.dockerapp.org/login` shows the security headers, each once.
2. *Administration settings → Overview* in Nextcloud shows no header or HTTPS warnings.
3. `cscli metrics` shows Caddy log lines being read; `cscli decisions list` works.
4. More than 10 wrong logins within a minute give `429`.
5. (Step 5) A non-EU VPN gets `403`; your phone on mobile data works.
6. Nextcloud asks for a 2FA code in the browser; the phone and desktop apps still sync.
7. `https://app.dockerapp.org` first shows the Authelia login.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `caddy validate`: `unrecognized directive: crowdsec` (or `rate_limit`, `maxmind_geolocation`) | Plain Caddy without plugins, often after an `apt upgrade` without the hold | Run Step 1 again, including `apt-mark hold caddy` |
| Everything gives `403`, also from your LAN | Bouncer can't reach CrowdSec, or GeoIP filter without `private_ranges` | `systemctl status crowdsec`; check `api_key` and the `not remote_ip private_ranges` line |
| CrowdSec won't start: port `8080` in use | Another program on the Caddy machine uses 8080 | Change `listen_uri` in `/etc/crowdsec/config.yaml` and `api_url` in the Caddyfile to the same new port |
| `cscli metrics` shows no Caddy logs | Acquisition file wrong or no log file yet | Check `/etc/crowdsec/acquis.d/caddy.yaml`, `ls /var/log/caddy/`, then `systemctl restart crowdsec` |
| You banned yourself | Too many wrong attempts from a public address | `cscli decisions list`, then `cscli decisions delete --ip <IP>` |
| Nextcloud warns about a header ("…is not set to…") | Header value differs from what Nextcloud wants, or `defer` missing | Compare with the `(hardening)` snippet above |
| Phone app stops syncing while abroad | GeoIP filter (Step 5) | Add the country to `allow_countries`, or use the VPN home |
| Authelia: "There was an issue retrieving the current user state" or a redirect loop | Cookie domain or `authelia_url` wrong | `session.cookies` must say `dockerapp.org` and `https://auth.dockerapp.org`; check `journalctl -u authelia` |
| Authelia won't start | Error in the configuration | `authelia validate-config --config /etc/authelia/configuration.yml` shows the line |
| Caddy log: `geoip database not found` | Database missing or wrong path | `geoipupdate`, then `ls -l /var/lib/GeoIP/` |
