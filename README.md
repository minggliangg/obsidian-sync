# Obsidian LiveSync on the Pi

CouchDB in Docker, reachable only over Tailscale with HTTPS. The Obsidian
[Self-hosted LiveSync](https://github.com/vrtmrz/obsidian-livesync) plugin on
each device syncs through it.

```
Mac / iPhone / Android / tablet  (Obsidian + Self-hosted LiveSync)
            │  HTTPS, tailnet only
            ▼
  Pi: tailscale serve :443 → 127.0.0.1:5984 → CouchDB (Docker) → DATA_DIR
```

Live endpoint: `https://raspberry-pi-5.taile30169.ts.net`

## Files

```
obsidian-sync/
├── docker-compose.yml
├── local.ini          # CouchDB config for LiveSync (CORS, size limits, auth)
├── .env.example       # copy to .env (gitignored)
├── init-couchdb.sh    # one-time DB + user setup, safe to re-run
└── data/              # CouchDB data when DATA_DIR=./data (gitignored)
```

## 1. Install Docker (once per Pi)

From Docker's official apt repo (Debian's package lags and may lack `docker compose`):

```bash
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"   # log out/in to use docker without sudo
```

## 2. Server setup

```bash
cd ~/Projects/obsidian-sync

cp .env.example .env
nano .env                      # passwords: openssl rand -base64 24
chmod 600 .env

# Data location (must match DATA_DIR, owned by couchdb's uid in the image)
mkdir -p data && sudo chown -R 5984:5984 data
# or, with an SSD: sudo mkdir -p /mnt/ssd/couchdb && sudo chown -R 5984:5984 /mnt/ssd/couchdb

docker compose up -d
./init-couchdb.sh
docker compose ps               # should say (healthy) after ~30s
```

**Storage:** this Pi currently has no SSD, so `DATA_DIR=./data` (SD card).
A notes vault is small and CouchDB compacts automatically, so that's fine.
To move to an SSD later: `docker compose down`, copy `data/` to the SSD
(keep ownership 5984:5984), point `DATA_DIR` at it, `docker compose up -d`.

## 3. Expose over Tailscale

```bash
sudo tailscale serve --bg 5984
tailscale serve status
```

Serves `https://raspberry-pi-5.taile30169.ts.net` (port 443) to the tailnet only.
Coexists with the other service already on `:8443`. To remove: `sudo tailscale serve --https=443 off`.

Check from the Mac (on the tailnet):

```bash
curl -u obsidian:PASSWORD https://raspberry-pi-5.taile30169.ts.net/vault
```

## 4. Mac (first device, source of truth)

1. Community plugins → install **Self-hosted LiveSync** → enable it.
2. Run the setup wizard, choose manual CouchDB setup:
   - URI: `https://raspberry-pi-5.taile30169.ts.net`
   - Username / password: `OBSIDIAN_USER` / `OBSIDIAN_PASSWORD` from `.env`
     (never the admin account)
   - Database: `vault`
3. **Turn on End-to-End Encryption and Path Obfuscation now**, before the
   first sync. Pick a strong passphrase and save it in your password manager.
   Losing it means the server copy is unreadable.
4. Sync mode: LiveSync.
5. Let the initial upload finish.
6. Command palette → "Copy setup URI". It's encrypted with a passphrase
   you choose.

## 5. iPhone, Android phone, tablet

1. Install Tailscale, sign in, enable VPN On Demand (iOS) / Always-on VPN (Android).
2. Create a **new empty vault**. On iPhone, store it on device, NOT iCloud.
3. Install + enable Self-hosted LiveSync.
4. Open the setup URI (paste it into the plugin's "Use setup URI" option).
5. Choose to fetch from the server, let it pull everything.
6. Sync mode: Periodic + sync on file open/save (easier on battery).

## Settings to watch

- Leave Customization Sync off at first. If you want settings synced, exclude
  `workspace.json` / `workspace-mobile.json`.
- Never put a LiveSync vault inside iCloud, Dropbox, Syncthing, etc.

## Backups

Sync is not backup: a deletion or a bad edit replicates everywhere instantly.

**Notes → private GitHub repo, from the Mac only.** Install the
**obsidian-git** plugin in the Mac vault, point it at a private repo
(e.g. `obsidian-vault`), auto-commit + push hourly. Don't run it on the
phones too; one committer avoids conflicts.

The vault repo is **plain text on GitHub** (private ≠ encrypted). LiveSync's
settings file holds the CouchDB password and the E2EE passphrase, so the
vault's `.gitignore` must include:

```
.obsidian/plugins/obsidian-livesync/data.json
.obsidian/workspace*.json
```

GitHub rejects files over 100 MB; exclude large attachments if needed.

**Server → this repo.** Config only, `.env` is gitignored (keep the
passwords in your password manager). No CouchDB data backup: the Pi holds
only an encrypted copy of what's on every device.

**If the Pi dies:** clone this repo, recreate `.env`, run sections 1-3, then on
the Mac use LiveSync's "Rebuild everything" / overwrite-remote option to
re-upload the vault. Other devices then re-fetch from the server.

## Maintenance

```bash
docker compose pull && docker compose up -d   # update CouchDB (stay on 3.5.x)
docker compose logs --tail 100 couchdb
curl -u admin:PASS http://127.0.0.1:5984/vault | jq '.sizes'
```

Admin UI (Fauxton) from the Pi or over the tailnet: `/_utils/`

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Mobile can't connect, desktop can | Tailscale off on the phone, or using http:// instead of https:// |
| CORS error | Edited `local.ini` without `docker compose restart` |
| 401 | Wrong user/password, or user not in the vault's `_security` members |
| Container restart loop, no logs | `local.ini` not world-readable (`chmod 644 local.ini`), or DATA_DIR not owned by 5984:5984 |
| Plugin warns about DB config | Run its "Check database configuration" with the admin creds once, then switch back |
| Slow sync | `tailscale ping raspberry-pi-5` from the Mac; "via DERP" means relayed, not direct |

## Implementation notes

- `local.ini` is mounted at `/config` and copied into `local.d` on each start.
  The image's entrypoint chowns everything under `/opt/couchdb` and exits
  silently when that fails, which it does on a read-only bind mount.
- The healthcheck authenticates because `require_valid_user` also covers `/_up`.
