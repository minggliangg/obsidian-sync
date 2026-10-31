# Obsidian LiveSync on the Pi

CouchDB in Docker, reachable only over Tailscale with HTTPS.

## Files

```
obsidian-sync/
├── docker-compose.yml
├── local.ini          # CouchDB config for LiveSync (CORS, size limits, auth)
├── .env.example       # copy to .env
└── init-couchdb.sh    # one-time DB + user setup, safe to re-run
```

## 1. Pi setup

```bash
mkdir -p ~/obsidian-sync && cd ~/obsidian-sync
# copy the files here

cp .env.example .env
nano .env                      # set passwords + DATA_DIR on the SSD
chmod 600 .env
chmod +x init-couchdb.sh

sudo mkdir -p /mnt/ssd/couchdb  # match DATA_DIR
sudo chown -R 5984:5984 /mnt/ssd/couchdb   # couchdb's uid in the image

docker compose up -d
docker compose logs -f couchdb  # wait until it settles, Ctrl+C
./init-couchdb.sh
```

## 2. Expose over Tailscale

```bash
sudo tailscale serve --bg 5984
tailscale serve status
```

You get something like `https://pi.your-tailnet.ts.net`. HTTPS certs need
MagicDNS and HTTPS enabled in the Tailscale admin console (DNS page).

Check from the Mac (on the tailnet):

```bash
curl -u obsidian:PASSWORD https://pi.your-tailnet.ts.net/vault
```

## 3. Mac (first device, source of truth)

1. Community plugins → install **Self-hosted LiveSync** → enable it.
2. Run the setup wizard, choose manual CouchDB setup:
   - URI: `https://pi.your-tailnet.ts.net`
   - Username / password: the OBSIDIAN_USER ones from `.env`
   - Database: `vault`
3. **Turn on End-to-End Encryption and Path Obfuscation now**, before the
   first sync. Pick a strong passphrase and save it in your password manager.
   Losing it means the server copy is unreadable.
4. Sync mode: LiveSync.
5. Let the initial upload finish.
6. Command palette → "Copy setup URI". It's encrypted with a passphrase
   you choose.

## 4. iPhone, Android phone, tablet

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

Sync is not backup. On the Mac, add obsidian-git with hourly auto-commit to a
private repo, or point restic at the vault folder. Optionally also back up
the CouchDB data dir on the Pi:

```bash
# cron, nightly. Brief stop keeps the files consistent.
0 3 * * * cd ~/obsidian-sync && docker compose stop couchdb && \
  tar czf ~/backups/couchdb-$(date +\%F).tgz -C /mnt/ssd couchdb && \
  docker compose start couchdb
```

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
| Container won't start, permission denied | DATA_DIR not owned by 5984:5984 |
| Plugin warns about DB config | Run its "Check database configuration" with the admin creds once, then switch back |
