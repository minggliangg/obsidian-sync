#!/usr/bin/env bash
# One-time CouchDB setup for Obsidian LiveSync. Safe to re-run.
set -euo pipefail

cd "$(dirname "$0")"
[ -f .env ] || { echo "Missing .env (copy .env.example first)"; exit 1; }
set -a; source .env; set +a

URL="http://127.0.0.1:5984"
ADMIN="${COUCHDB_ADMIN_USER}:${COUCHDB_ADMIN_PASSWORD}"

# PUT that treats "already exists" (412) as success
put() {
  local path="$1" body="${2:-}"
  local code
  code=$(curl -s -o /tmp/couch_resp -w '%{http_code}' -u "$ADMIN" \
    -X PUT "$URL$path" -H 'Content-Type: application/json' ${body:+-d "$body"})
  case "$code" in
    200|201|202) echo "  ok      $path" ;;
    412)         echo "  exists  $path" ;;
    *)           echo "  FAILED  $path ($code): $(cat /tmp/couch_resp)"; exit 1 ;;
  esac
}

echo "Waiting for CouchDB..."
for _ in $(seq 1 30); do
  curl -fs -u "$ADMIN" "$URL/_up" >/dev/null 2>&1 && break
  sleep 2
done
curl -fs -u "$ADMIN" "$URL/_up" >/dev/null || { echo "CouchDB not reachable"; exit 1; }

echo "System databases:"
put /_users
put /_replicator

echo "Sync user:"
user_doc=$(curl -s -u "$ADMIN" "$URL/_users/org.couchdb.user:${OBSIDIAN_USER}")
rev=$(echo "$user_doc" | sed -n 's/.*"_rev":"\([^"]*\)".*/\1/p')
body="{\"name\":\"${OBSIDIAN_USER}\",\"password\":\"${OBSIDIAN_PASSWORD}\",\"roles\":[],\"type\":\"user\"${rev:+,\"_rev\":\"$rev\"}}"
put "/_users/org.couchdb.user:${OBSIDIAN_USER}" "$body"

echo "Vault database:"
put "/${VAULT_DB}"

echo "Permissions (only ${OBSIDIAN_USER} + admins can touch ${VAULT_DB}):"
put "/${VAULT_DB}/_security" \
  "{\"admins\":{\"names\":[],\"roles\":[]},\"members\":{\"names\":[\"${OBSIDIAN_USER}\"],\"roles\":[]}}"

echo
echo "Sanity check as ${OBSIDIAN_USER}:"
curl -fs -u "${OBSIDIAN_USER}:${OBSIDIAN_PASSWORD}" "$URL/${VAULT_DB}" >/dev/null \
  && echo "  ${OBSIDIAN_USER} can read ${VAULT_DB}" \
  || { echo "  ${OBSIDIAN_USER} cannot read ${VAULT_DB}"; exit 1; }

echo
echo "Done. Next: tailscale serve --bg 5984"
