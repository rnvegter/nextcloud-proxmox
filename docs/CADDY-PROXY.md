# Connect Nextcloud to the Caddy proxy

Caddy on `192.168.0.201` receives `https://nextcloud.dockerapp.org`, gets the HTTPS certificate from Let's Encrypt by itself and forwards every request to Nextcloud at `http://192.168.0.202:8080`. Nextcloud stays plain HTTP inside your LAN; it only needs to know that a proxy sits in front of it.

```
Internet → FritzBox (195.240.56.75) → UniFi Cloud Gateway → Caddy 192.168.0.201 → Nextcloud 192.168.0.202:8080
```

**Before you start**

- Both machines have a fixed address (DHCP reservation in the UniFi gateway).
- An A record for `nextcloud` in the `dockerapp.org` zone points to your public IP. Check from any machine: `nslookup nextcloud.dockerapp.org` returns your public IP, and `curl -4 ifconfig.me` on the Caddy machine shows the same address.

## Step 1: Forward ports 80 and 443 through both routers

There are two routers in a row (double NAT), so the ports must be forwarded on both. Port 8080 on the Nextcloud VM is never forwarded.

**1. Find the UniFi gateway's WAN address.** In the UniFi Network app, open *Settings → Internet* (or the dashboard) and note the WAN IP. It is an address in the FritzBox network, usually `192.168.178.x`.

**2. FritzBox → UniFi gateway.** In the FritzBox, open *Internet → Permit Access → Port Sharing* (German: *Internet → Freigaben → Portfreigaben*), *Add Device for Sharing*, select the UniFi gateway and add:

| Protocol | External port | To port |
| --- | --- | --- |
| TCP | 80 | 80 |
| TCP | 443 | 443 |

Alternatively, tick *Exposed Host* for the UniFi gateway; the FritzBox then passes everything on and the UniFi firewall decides. Make sure the FritzBox's own remote access (MyFRITZ / HTTPS) does not use port 443.

**3. UniFi gateway → Caddy.** In UniFi, open *Settings → Routing → Port Forwarding* (older versions: *Settings → Firewall & Security → Port Forwarding*) and create:

| Name | WAN port | Forward IP | Forward port | Protocol |
| --- | --- | --- | --- | --- |
| Caddy HTTP | 80 | 192.168.0.201 | 80 | TCP |
| Caddy HTTPS | 443 | 192.168.0.201 | 443 | TCP |

## Step 2: Tell Nextcloud about the proxy

On the Nextcloud VM, as `nextcloud`:

```bash
cd ~/nextcloud-proxmox
```

```bash
nano .env
```

Set these four lines:

```
TRUSTED_PROXIES=192.168.0.201
OVERWRITEPROTOCOL=https
OVERWRITEHOST=nextcloud.dockerapp.org
OVERWRITECLIURL=https://nextcloud.dockerapp.org
```

Apply them:

```bash
docker compose up -d
```

Add the domain and the VM's IP as trusted domains. Look at the list first and use free index numbers:

```bash
docker compose exec -u www-data nextcloud php occ config:system:get trusted_domains
```

```bash
docker compose exec -u www-data nextcloud php occ config:system:set trusted_domains 1 --value=192.168.0.202
```

```bash
docker compose exec -u www-data nextcloud php occ config:system:set trusted_domains 2 --value=nextcloud.dockerapp.org
```

To remove an old entry: `occ config:system:delete trusted_domains <index>`.

## Step 3: Add the site to Caddy

On the Caddy machine (`192.168.0.201`). First check that Caddy can reach Nextcloud:

```bash
curl -I http://192.168.0.202:8080
```

Back up and open the Caddyfile:

```bash
cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.bak
```

```bash
nano /etc/caddy/Caddyfile
```

Add this block at the end:

```
nextcloud.dockerapp.org {
	request_body {
		max_size 10GB
	}
	header Strict-Transport-Security "max-age=15552000; includeSubDomains"
	redir /.well-known/carddav /remote.php/dav/ 301
	redir /.well-known/caldav /remote.php/dav/ 301
	reverse_proxy 192.168.0.202:8080
}
```

Tidy the formatting and check the file:

```bash
caddy fmt --overwrite /etc/caddy/Caddyfile
```

```bash
caddy validate --config /etc/caddy/Caddyfile
```

"Valid configuration" at the end means it is fine. A warning that a server "is listening only on the HTTP port" comes from another site in the file (often the default `:80` welcome page) and can be ignored or removed.

Reload Caddy and watch for the certificate:

```bash
systemctl reload caddy
```

```bash
journalctl -u caddy -f
```

Wait for "certificate obtained successfully" for `nextcloud.dockerapp.org`, then Ctrl+C. Caddy renews the certificate by itself.

## Step 4: Check

1. Open `https://nextcloud.dockerapp.org` from outside your network (for example on your phone without Wi-Fi) and log in.
2. *Administration settings → Overview* shows no warnings about HTTPS or the proxy.
3. *Personal settings → Security* lists your session with your real public IP, not `192.168.0.201`.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Caddy log: `challenge failed … Error getting validation data` | Ports 80/443 do not reach Caddy from the internet | Check both port forwards (FritzBox → UniFi, UniFi → `192.168.0.201`); test `http://<public IP>` on your phone without Wi-Fi |
| Caddy log shows another IP than your public IP | DNS record points elsewhere | Fix the A record for `nextcloud.dockerapp.org` |
| 502 Bad Gateway | Caddy cannot reach the Nextcloud VM | From the Caddy machine: `curl -I http://192.168.0.202:8080`; on the VM: `docker compose ps` |
| "Access through untrusted domain" | Domain or IP not trusted | Add it with `occ config:system:set trusted_domains <n> --value=…` (Step 2) |
| Redirects to `http://` or to port 8080 | Overwrite settings missing | Check the four lines in `.env`, then `docker compose up -d` |
| Log shows `192.168.0.201` instead of visitor IPs | `TRUSTED_PROXIES` wrong | Set it to the Caddy machine's IP |
| Uploads of large files fail | Upload limit | Raise `max_size` in the Caddyfile and `PHP_UPLOAD_LIMIT` in `.env` |
