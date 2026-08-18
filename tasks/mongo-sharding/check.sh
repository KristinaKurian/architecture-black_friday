#!/usr/bin/env bash
set -euo pipefail

DC=(docker compose -f "compose.yaml")

echo "=== Docker services ==="
"${DC[@]}" ps

echo
echo "=== ReplicaSet state ==="
for item in "configSrv:27017" "shard1:27018" "shard2:27019"; do
  service="${item%%:*}"
  port="${item##*:}"
  echo "-- ${service} --"
  "${DC[@]}" exec -T "$service" mongosh --port "$port" --quiet \
    --eval "printjson(db.hello().isWritablePrimary)"
done

echo
echo "=== Registered shards ==="
SHARD_COUNT=$(
  "${DC[@]}" exec -T mongos_router mongosh --port 27020 --quiet \
    --eval "db.getSiblingDB('config').shards.countDocuments()" | tr -d '\r'
)
echo "Shard count: ${SHARD_COUNT}"

echo
echo "=== Total documents through mongos_router ==="
TOTAL=$(
  "${DC[@]}" exec -T mongos_router mongosh --port 27020 --quiet \
    --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()" | tr -d '\r'
)
echo "Total: ${TOTAL}"

echo
echo "=== Documents on shard1 ==="
SHARD1=$(
  "${DC[@]}" exec -T shard1 mongosh --port 27018 --quiet \
    --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()" | tr -d '\r'
)
echo "shard1: ${SHARD1}"

echo
echo "=== Documents on shard2 ==="
SHARD2=$(
  "${DC[@]}" exec -T shard2 mongosh --port 27019 --quiet \
    --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()" | tr -d '\r'
)
echo "shard2: ${SHARD2}"

echo
echo "=== Sharding status ==="
"${DC[@]}" exec -T mongos_router mongosh --port 27020 --quiet \
  --eval "sh.status()"

echo
echo "=== Validation ==="

if [ "${SHARD_COUNT}" -lt 2 ]; then
  echo "ERROR: expected 2 registered shards, got ${SHARD_COUNT}"
  exit 1
fi

if [ "${TOTAL}" -lt 1000 ]; then
  echo "ERROR: expected at least 1000 documents, got ${TOTAL}"
  exit 1
fi

if [ "${SHARD1}" -eq 0 ] || [ "${SHARD2}" -eq 0 ]; then
  echo "ERROR: documents are not distributed between both shards"
  exit 1
fi

echo "OK: 2 shards are registered."
echo "OK: total documents >= 1000."
echo "OK: documents exist on both shards."
