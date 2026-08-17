#!/usr/bin/env bash
set -euo pipefail

DC=(docker compose -f "mongo-sharding.yaml")
MAX_ATTEMPTS=30
SLEEP_SECONDS=2

wait_mongo() {
  local service="$1"
  local port="$2"

  echo "Waiting for ${service}:${port}..."

  for ((i=1; i<=MAX_ATTEMPTS; i++)); do
    if "${DC[@]}" exec -T "$service" \
      mongosh --port "$port" --quiet \
      --eval "db.adminCommand({ping:1}).ok" \
      >/dev/null 2>&1; then
      echo "${service}:${port} is available"
      return 0
    fi

    echo "  attempt ${i}/${MAX_ATTEMPTS}"
    sleep "$SLEEP_SECONDS"
  done

  echo "ERROR: ${service}:${port} is unavailable"
  "${DC[@]}" logs --tail=80 "$service" || true
  return 1
}

wait_primary() {
  local service="$1"
  local port="$2"

  echo "Waiting for PRIMARY on ${service}:${port}..."

  for ((i=1; i<=MAX_ATTEMPTS; i++)); do
    if "${DC[@]}" exec -T "$service" \
      mongosh --port "$port" --quiet \
      --eval "db.hello().isWritablePrimary" \
      2>/dev/null | grep -q "true"; then
      echo "${service}:${port} is PRIMARY"
      return 0
    fi

    echo "  attempt ${i}/${MAX_ATTEMPTS}"
    sleep "$SLEEP_SECONDS"
  done

  echo "ERROR: ${service}:${port} did not become PRIMARY"
  "${DC[@]}" logs --tail=80 "$service" || true
  return 1
}

echo "=== 1. Start config server and shard MongoDB instances ==="
"${DC[@]}" up -d configSrv shard1 shard2

wait_mongo configSrv 27017
wait_mongo shard1 27018
wait_mongo shard2 27019

echo
echo "=== 2. Initialize config server ReplicaSet ==="
if "${DC[@]}" exec -T configSrv mongosh --port 27017 --quiet \
  --eval "rs.status().ok" >/dev/null 2>&1; then
  echo "config_server is already initialized"
else
  "${DC[@]}" exec -T configSrv mongosh --port 27017 --quiet <<'EOF'
printjson(
  rs.initiate({
    _id: "config_server",
    configsvr: true,
    members: [
      { _id: 0, host: "configSrv:27017" }
    ]
  })
);
EOF
fi

echo
echo "=== 3. Initialize shard1 ReplicaSet ==="
if "${DC[@]}" exec -T shard1 mongosh --port 27018 --quiet \
  --eval "rs.status().ok" >/dev/null 2>&1; then
  echo "shard1 is already initialized"
else
  "${DC[@]}" exec -T shard1 mongosh --port 27018 --quiet <<'EOF'
printjson(
  rs.initiate({
    _id: "shard1",
    members: [
      { _id: 0, host: "shard1:27018" }
    ]
  })
);
EOF
fi

echo
echo "=== 4. Initialize shard2 ReplicaSet ==="
if "${DC[@]}" exec -T shard2 mongosh --port 27019 --quiet \
  --eval "rs.status().ok" >/dev/null 2>&1; then
  echo "shard2 is already initialized"
else
  "${DC[@]}" exec -T shard2 mongosh --port 27019 --quiet <<'EOF'
printjson(
  rs.initiate({
    _id: "shard2",
    members: [
      { _id: 0, host: "shard2:27019" }
    ]
  })
);
EOF
fi

echo
echo "=== 5. Wait until all ReplicaSets become PRIMARY ==="
wait_primary configSrv 27017
wait_primary shard1 27018
wait_primary shard2 27019

echo
echo "=== 6. Start mongos router ==="
"${DC[@]}" up -d mongos_router
wait_mongo mongos_router 27020

echo
echo "=== 7. Add shards, enable sharding and seed test data ==="
"${DC[@]}" exec -T mongos_router mongosh --port 27020 --quiet <<'EOF'
const configDB = db.getSiblingDB("config");

const existingShards = configDB.shards
  .find({})
  .toArray()
  .map(s => s._id);

if (!existingShards.includes("shard1")) {
  print("Adding shard1...");
  printjson(sh.addShard("shard1/shard1:27018"));
} else {
  print("shard1 is already registered");
}

if (!existingShards.includes("shard2")) {
  print("Adding shard2...");
  printjson(sh.addShard("shard2/shard2:27019"));
} else {
  print("shard2 is already registered");
}

print("Enabling sharding for somedb...");
try {
  printjson(sh.enableSharding("somedb"));
} catch (e) {
  print("Sharding for somedb is already enabled or not required: " + e.message);
}

const namespace = "somedb.helloDoc";
const collectionConfig = configDB.collections.findOne({
  _id: namespace,
  dropped: { $ne: true }
});

if (!collectionConfig || !collectionConfig.key) {
  print("Sharding somedb.helloDoc by {name: 'hashed'}...");
  printjson(sh.shardCollection(namespace, { name: "hashed" }));
} else {
  print("somedb.helloDoc is already sharded");
}

const appDB = db.getSiblingDB("somedb");
const operations = [];

for (let i = 0; i < 1000; i++) {
  operations.push({
    updateOne: {
      filter: { name: "ly" + i },
      update: {
        $setOnInsert: {
          _id: i,
          age: i,
          name: "ly" + i
        }
      },
      upsert: true
    }
  });
}

appDB.helloDoc.bulkWrite(operations, { ordered: false });

print("");
print("Total documents via mongos:");
print(appDB.helloDoc.countDocuments());

print("");
print("Registered shards:");
printjson(configDB.shards.find({}).toArray());
EOF

echo
echo "=== 8. Start application ==="
"${DC[@]}" up -d pymongo-api

echo
echo "=== Initialization completed ==="
echo "Run:"
echo "  bash check.sh"
