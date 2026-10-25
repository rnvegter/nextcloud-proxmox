# Connect Nextcloud to an nginx proxy on another machine

The nginx machine receives `https://cloud.example.com`, holds the HTTPS certificate and forwards every request to Nextcloud at `http://192.168.0.30:8080`. Nextcloud itself stays plain HTTP inside your LAN; it only needs to know that a proxy sits in front of it.

The examples use `192.168.0.10` for the nginx machine, `192.168.0.30` for the Nextcloud VM and `cloud.example.com` for your domain. Replace the first two with your real addresses.

**Before you start**

- nginx is installed on the other machine.
- Your router forwards ports 80 and 443 to the nginx machine (not to the Nextcloud VM).
- An A record for `cloud.example.com` points to your public IP. Port 8080 on the VM is never forwarded on the router.

## Step 1: Tell Nextcloud about the proxy

On the VM, as `nextcloud`, set the four proxy variables in `.env`:

```bash
TRUSTED_PROXIES=192.168.0.10
OVERWRITEPROTOCOL=https
OVERWRITEHOST=cloud.example.com
OVERWRITECLIURL=https://cloud.example.com
```

Apply them and add the domain as trusted:

```bash
sudo -iu nextcloud
cd ~/nextcloud-proxmox
docker compose up -d
docker compose exec -u www-data nextcloud php occ config:system:set trusted_domains 1 --value=cloud.example.com
```

From now on Nextcloud builds all its links as `https://cloud.example.com`, also when you open it through the VM's IP.

## Step 2: Add the site to nginx

On the nginx machine, create `/etc/nginx/sites-available/nextcloud.conf`:

```nginx
server {
    listen 80;
    server_name cloud.example.com;

    # Large uploads and slow clients
    client_max_body_size 10G;
    client_body_buffer_size 512k;
    proxy_request_buffering off;
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;

    add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;

    # Calendar and contacts discovery
    location = /.well-known/carddav { return 301 $scheme://$host/remote.php/dav/; }
    location = /.well-known/caldav  { return 301 $scheme://$host/remote.php/dav/; }

    location / {
        proxy_pass http://192.168.0.30:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
    }
}
```

Enable it, then let certbot add the certificate, the HTTPS listener and the HTTP-to-HTTPS redirect:

```bash
sudo ln -s /etc/nginx/sites-available/nextcloud.conf /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo apt install -y certbot python3-certbot-nginx
sudo certbot --nginx -d cloud.example.com --redirect
```

certbot renews the certificate automatically. If you already manage certificates another way on this machine, add `listen 443 ssl;` and your `ssl_certificate` lines to the server block instead.

## Step 3: Check

1. Open `https://cloud.example.com` from outside your network (for example on your phone without Wi-Fi) and log in.
2. *Administration settings → Overview* shows no warnings about HTTPS, the proxy or `.well-known` URLs.
3. *Personal settings → Security* lists your session with your real public IP, not `192.168.0.10`.

## Using Nginx Proxy Manager instead

If the other machine runs Nginx Proxy Manager (the web interface), Step 1 stays the same, with `TRUSTED_PROXIES` set to that machine's IP. Then:

1. *Hosts → Proxy Hosts → Add Proxy Host*: domain `cloud.example.com`, scheme `http`, forward hostname `192.168.0.30`, port `8080`. Tick *Block Common Exploits* and *Websockets Support*.
2. *SSL* tab: *Request a new SSL Certificate*, and tick *Force SSL*, *HTTP/2 Support* and *HSTS Enabled*.
3. *Advanced* tab, custom configuration:

```nginx
client_max_body_size 10G;
proxy_request_buffering off;
proxy_buffering off;
proxy_read_timeout 3600s;
location = /.well-known/carddav { return 301 $scheme://$host/remote.php/dav/; }
location = /.well-known/caldav  { return 301 $scheme://$host/remote.php/dav/; }
```

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| 502 Bad Gateway | nginx cannot reach the VM | From the nginx machine: `curl -I http://192.168.0.30:8080`; check `docker compose ps` on the VM |
| "Access through untrusted domain" | Domain not trusted | Run the `occ ... trusted_domains` command from Step 1 |
| Redirects to `http://` or to port 8080 | Overwrite settings missing | Check the four variables in `.env`, then `docker compose up -d` |
| 413 Request Entity Too Large | Upload limit in nginx | Raise `client_max_body_size` and reload nginx |
| 504 Gateway Timeout on big uploads | nginx timeouts | Raise `proxy_read_timeout` and `proxy_send_timeout` |
| Log shows `192.168.0.10` instead of visitor IPs | `TRUSTED_PROXIES` wrong | Set it to the nginx machine's IP as the VM sees it |
| certbot fails | Port 80 not forwarded, or DNS not pointing at you | Check the router forward and the A record |
