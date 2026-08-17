#!/usr/bin/env bash
set -euo pipefail

DC="docker compose"

wait_mongo() {
  local service="$1"
  local port="$2"
  echo "Waiting for ${service}:${port}..."
  until $DC exec -T "$service" mongosh --port "$port" --quiet --eval "db.adminCommand('ping').ok" >/dev/null 2>&1; do
    sleep 2
  done
}

wait_primary() {
  local service="$1"
  local port="$2"
  echo "Waiting for PRIMARY on ${service}:${port}..."
  until $DC exec -T "$service" mongosh --port "$port" --quiet --eval "db.helloCommand({hello:1}).isWritablePrimary" 2>/dev/null | grep -q true; do
    sleep 2
  done
}

wait_mongo configSrv 27017
wait_mongo shard1 27018
wait_mongo shard2 27019

# Initialize config server replica set (idempotent).
$DC exec -T configSrv mongosh --port 27017 --quiet <<'EOF' || true
try {
  rs.status();
} catch (e) {
  rs.initiate({
    _id: "config_server",
    configsvr: true,
    members: [{ _id: 0, host: "configSrv:27017" }]
  });
}
EOF

# Initialize shard replica sets (one member each in Task 2).
$DC exec -T shard1 mongosh --port 27018 --quiet <<'EOF' || true
try {
  rs.status();
} catch (e) {
  rs.initiate({
    _id: "shard1",
    members: [{ _id: 0, host: "shard1:27018" }]
  });
}
EOF

$DC exec -T shard2 mongosh --port 27019 --quiet <<'EOF' || true
try {
  rs.status();
} catch (e) {
  rs.initiate({
    _id: "shard2",
    members: [{ _id: 0, host: "shard2:27019" }]
  });
}
EOF

wait_primary configSrv 27017
wait_primary shard1 27018
wait_primary shard2 27019

wait_mongo mongos_router 27020

# Add shards and configure sharding. Commands are safe to run repeatedly.
$DC exec -T mongos_router mongosh --port 27020 --quiet <<'EOF'
const existing = db.getSiblingDB("config").shards.find({}).toArray().map(s => s._id);
if (!existing.includes("shard1")) {
  printjson(sh.addShard("shard1/shard1:27018"));
}
if (!existing.includes("shard2")) {
  printjson(sh.addShard("shard2/shard2:27019"));
}

sh.enableSharding("somedb");

const cfg = db.getSiblingDB("config");
const ns = "somedb.helloDoc";
const alreadySharded = cfg.collections.findOne({_id: ns});
if (!alreadySharded) {
  printjson(sh.shardCollection(ns, {name: "hashed"}));
}

const dbx = db.getSiblingDB("somedb");
const ops = [];
for (let i = 0; i < 1000; i++) {
  ops.push({
    updateOne: {
      filter: {_id: i, name: "ly" + i},
      update: {$setOnInsert: {age: i, name: "ly" + i}},
      upsert: true
    }
  });
}
if (ops.length) {
  dbx.helloDoc.bulkWrite(ops, {ordered: false});
}

print("Total documents via mongos:");
print(dbx.helloDoc.countDocuments());
print("Shard status:");
sh.status();
EOF

echo
echo "Initialization complete."
echo "Run ./check.sh to verify document distribution."
