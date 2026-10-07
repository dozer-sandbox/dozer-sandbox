# The dashboard on your other computers, tablets and phones (`doz serve`)

`doz ui` is this Mac's own dashboard: it listens on `127.0.0.1` and nothing else can reach it. `doz serve` is the
same dashboard for the other browsers of your home network — the laptop on the couch, a second Mac, the iPad, a
phone — at `http://<this Mac>.local:7443`.

```bash
doz serve
```

It runs until you press Ctrl-C (or run `doz serve stop` in another terminal). To keep it running without a terminal
open, start it in the background:

```bash
doz serve start --detach     # or -d: prints where it listens and an invite, then returns
doz serve status             # pid, since when, the addresses, the version, its log
doz serve stop
```

A detached `doz serve` belongs to no terminal — closing the terminal does not stop it; its output goes to
`<store>/serve/serve.log`. Nothing listens beyond this Mac until you start it.

## Letting a browser in

A browser gets in once, with an **invite**, and then stays in until you remove it. An invite is three things at
once — use whichever suits the device:

- a **QR code** — point a phone's or tablet's camera at it;
- a short **access code** like `Y14G-99K3` — type it on the dashboard's sign-in page;
- a **link** — open it in the other browser.

Whichever is used first lets ONE browser in, within five minutes; the other two stop working. `doz serve` prints
an invite when it starts (on a terminal) — its link by name (`http://<this Mac>.local:7443/…`) and by each of the
Mac's addresses (`http://192.168.1.20:7443/…`): `.local` names do not resolve the same everywhere, so use an address
if the name does not answer. The links work in this Mac's own browser too. For another invite:

```bash
doz serve share
```

or, on any browser that is already in: **Devices › Add another browser**. The Mac's own `doz ui` has the same
Devices page.

A browser that opens the dashboard without an invite sees the sign-in page and nothing else — no sandbox, no
name, no data. A request `doz serve` refuses always gets an answer saying why — only a sandbox's connection is
dropped without one.

## What another browser can do

Everything the Mac's dashboard does — watch and drive sandboxes, open terminals in the browser, create sandboxes,
change their network, settings, images and resources — with two exceptions:

- **No keys or tokens over plain HTTP.** Adding an account's API key or setup token, a sandbox's own key or a
  GitHub token would send it across your network unencrypted, so the dashboard does not offer the field there and
  `doz serve` refuses it. Add it on the Mac (`doz account add NAME --api-key`, or the Mac's own `doz ui`), or reach
  `doz serve` over HTTPS through your reverse proxy (below) — there it is allowed.
- **Nothing that opens a window on the Mac's screen**: the Mac's folder and file pickers and **Open in Terminal**
  are not shown on another computer. Type the folder's path instead, and use the browser's own terminals.

The `serve.*` settings — who can reach the dashboard — are changed only on the Mac, with `doz config set`.

## The browsers that are in

```bash
doz serve devices           # name, when let in, last seen, from where, which browser
doz serve rename ID "Kitchen iPad"
doz serve revoke ID         # or --all
```

The **Devices** page (on every browser that is in, and on the Mac's `doz ui`) lists the same, with **Remove** and
**Rename**, and the recent activity. A removed browser is signed out at once — its pages say so and its
terminals close — and needs a new invite to come back.

Every change a remote browser asks for, every terminal it opens, every admission and every refusal is written to
an audit log — never a key, a code or what was typed:

```bash
doz serve log
```

## Where it listens

By default (`serve.bind = lan`) on every network interface of this Mac (Wi-Fi, Ethernet, the Thunderbolt Bridge)
and on Tailscale — never on a sandbox's network. A sandbox can never reach `doz serve`: a connection from a
sandbox's network is dropped before anything is read, and the proxy that carries a proxied sandbox's traffic
refuses the Mac's own addresses on the dashboards' ports, whatever the sandbox's network policy says.

`doz serve` also announces itself with Bonjour as "Dozer on <this Mac>" (`serve.advertise`), so Safari's Bonjour
list and other devices can find it.

The port is `serve.port` (7443). It never moves by itself — an installed app and a bookmark belong to it: when
another program holds it, `doz serve` refuses and names that program.

```bash
doz config set serve.port 8443
```

## HTTPS behind your own reverse proxy

If you already run a reverse proxy at home (Caddy, Traefik, nginx, Nginx Proxy Manager, a Cloudflare Tunnel …),
put `doz serve` behind it: your proxy does HTTPS, and through it the dashboard can be installed as an app (with
its offline page, like `doz ui`'s) and takes keys and tokens.

Tell `doz serve` three things:

```bash
doz config set serve.public_origins https://doz.home.example   # the address your proxy serves it at
doz config set serve.trusted_proxies 127.0.0.1,::1             # your proxy's address (here: on this Mac)
doz config set serve.bind loopback                             # a proxy on this Mac: listen on 127.0.0.1 only
```

For a proxy on another machine of your network, set `serve.trusted_proxies` to that machine's address and
`serve.bind` to this Mac's address the proxy connects to (or leave it `lan`).

`doz serve` believes `X-Forwarded-Proto`, `X-Forwarded-Host` and `X-Forwarded-For` ONLY from the addresses in
`serve.trusted_proxies`; from anyone else they are ignored, and the public address is refused. When it starts it
prints the upstream your proxy should use and what is missing. Check the whole path:

```bash
doz doctor
```

— its `doz serve via https://…` line fetches each public address from this Mac and says whether it came back to
this `doz serve`, over https, through a trusted proxy.

What your proxy must do: pass the `Host` header (or `X-Forwarded-Host`), set `X-Forwarded-Proto` and
`X-Forwarded-For`, pass WebSocket upgrades (the terminals), and not buffer responses (the live updates are a
server-sent event stream).

### Caddy

```caddyfile
doz.home.example {
	reverse_proxy 127.0.0.1:7443 {
		flush_interval -1
	}
}
```

Caddy passes `Host`, sets the forwarded headers and upgrades WebSockets by itself; `flush_interval -1` keeps the
live updates unbuffered.

### Traefik (file provider)

```yaml
http:
  routers:
    doz:
      rule: "Host(`doz.home.example`)"
      entryPoints: [websecure]
      service: doz
      tls: {}
  services:
    doz:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:7443"
```

Traefik passes `Host` and the forwarded headers and upgrades WebSockets by default.

### nginx (and Nginx Proxy Manager's custom configuration)

```nginx
map $http_upgrade $connection_upgrade { default upgrade; '' close; }

server {
    listen 443 ssl;
    server_name doz.home.example;
    ssl_certificate     /etc/ssl/doz.home.example.pem;
    ssl_certificate_key /etc/ssl/doz.home.example.key;

    location / {
        proxy_pass http://127.0.0.1:7443;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_buffering off;
        proxy_read_timeout 1h;
    }
}
```

`proxy_buffering off` matters: with nginx's default buffering the live updates arrive late or not at all.

### Cloudflare Tunnel

```yaml
# ~/.cloudflared/config.yml
tunnel: <your tunnel id>
credentials-file: /Users/you/.cloudflared/<your tunnel id>.json
ingress:
  - hostname: doz.example.com
    service: http://127.0.0.1:7443
  - service: http_status:404
```

`cloudflared` runs on this Mac, so `serve.trusted_proxies` is `127.0.0.1,::1` and `serve.public_origins` is
`https://doz.example.com`. A tunnel puts the dashboard on the Internet: put Cloudflare Access in front of it too.

The Caddy and Traefik configurations above are the ones Dozer's own tests run in front of `doz serve` (terminals,
live updates, the installable app, keys over https, `doz doctor`); the nginx and Cloudflare ones follow the same
rules.

## The macOS firewall and Local Network privacy

- **Firewall** (System Settings › Network › Firewall): when it is on, macOS asks once whether `doz` may accept
  incoming connections — answer **Allow**. A `doz` installed with Homebrew is signed, and with the firewall's
  "Automatically allow downloaded signed software" (on by default) it is allowed without asking. With "Block all
  incoming connections" nothing on your network can reach `doz serve`; `doz serve` says so when it starts. It
  never changes your firewall's settings.
- **Local Network privacy**: accepting connections from your network needs no permission. Announcing with Bonjour
  is done on behalf of the app you run `doz serve` in (Terminal, iTerm2, your editor); if macOS has refused that
  app Local Network access, `doz serve` says it was not announced — browsers still reach it by address and by
  `<this Mac>.local`. To announce it: System Settings › Privacy & Security › Local Network, allow that app, or set
  `serve.advertise` to false.

## Settings

| setting | default | what |
|---|---|---|
| `serve.port` | 7443 | the port (`--port`, `$DOZ_SERVE_PORT`) |
| `serve.bind` | `lan` | `lan`, `loopback`, or this Mac's addresses (`--bind`, `$DOZ_SERVE_BIND`) |
| `serve.public_origins` | — | your proxy's https addresses |
| `serve.trusted_proxies` | — | your proxy's addresses or networks |
| `serve.advertise` | true | announce with Bonjour |

All of them apply when `doz serve` starts again. See the [Settings reference](15-settings-reference.md).
