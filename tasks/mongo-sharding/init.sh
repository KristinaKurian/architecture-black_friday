#!/usr/bin/env bash

set -euo pipefail

DC="docker compose"


wait_mongo() {
  local service="$1"
  local port="$2"
  local attempts=30

  echo "Waiting for ${service}:${port}..."

  for ((i=1; i<=attempts; i++)); do

    if $DC exec -T "$service" \
      mongosh --port "$port" --quiet \
      --eval "db.adminCommand({ping:1}).ok" \
      >/dev/null 2>&1; then

      echo "${service}:${port} is available"
      return 0
    fi

    echo "Attempt ${i}/${attempts}..."
    sleep 2
  done

  echo "ERROR: ${service}:${port} is unavailable"
  $DC logs --tail=50 "$service"

  return 1
}


wait_primary() {
  local service="$1"
  local port="$2"
  local attempts=30

  echo "Waiting for PRIMARY on ${service}:${port}..."

  for ((i=1; i<=attempts; i++)); do

    if $DC exec -T "$service" \
      mongosh --port "$port" --quiet \
      --eval "db.hello().isWritablePrimary" 2>/dev/null \
      | grep -q true; then

      echo "${service}:${port} is PRIMARY"
      return 0
    fi

    echo "Attempt ${i}/${attempts}..."
    sleep 2
  done

  echo "ERROR: ${service}:${port} did not become PRIMARY"
  $DC logs --tail=50 "$service"

  return 1
}


echo
echo "=== Waiting for MongoDB instances ==="

wait_mongo configSrv 27017
wait_mongo shard1 27018
wait_mongo shard2 27019


echo
echo "=== Initializing config server ==="

$DC exec -T configSrv mongosh --port 27017 --quiet <<'EOF'
try {
    const status = rs.status();

    print("config_server already initialized");
} catch (e) {

    printjson(
        rs.initiate({
            _id: "config_server",
            configsvr: true,
            members: [
                {
                    _id: 0,
                    host: "configSrv:27017"
                }
            ]
        })
    );
}
EOF


echo
echo "=== Initializing shard1 ==="

$DC exec -T shard1 mongosh --port 27018 --quiet <<'EOF'
try {
    const status = rs.status();

    print("shard1 already initialized");
} catch (e) {

    printjson(
        rs.initiate({
            _id: "shard1",
            members: [
                {
                    _id: 0,
                    host: "shard1:27018"
                }
            ]
        })
    );
}
EOF


echo
echo "=== Initializing shard2 ==="

$DC exec -T shard2 mongosh --port 27019 --quiet <<'EOF'
try {
    const status = rs.status();

    print("shard2 already initialized");
} catch (e) {

    printjson(
        rs.initiate({
            _id: "shard2",
            members: [
                {
                    _id: 0,
                    host: "shard2:27019"
                }
            ]
        })
    );
}
EOF