#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yaml"
DC=(docker compose -f "$COMPOSE_FILE")

MAX_ATTEMPTS=45
SLEEP_SECONDS=2

mongo_eval() {
    local service="$1"
    local port="$2"
    local command="$3"

    "${DC[@]}" exec -T "$service" \
        mongosh --port "$port" --quiet --eval "$command"
}

repl_eval() {
    local exec_service="$1"
    local uri="$2"
    local command="$3"

    "${DC[@]}" exec -T "$exec_service" \
        mongosh "$uri" --quiet --eval "$command"
}

wait_mongo() {
    local service="$1"
    local port="$2"

    echo "Waiting for ${service}:${port}..."

    for ((i=1; i<=MAX_ATTEMPTS; i++)); do
        if mongo_eval "$service" "$port" 'db.adminCommand({ping:1}).ok' >/dev/null 2>&1; then
            echo "OK: ${service}:${port} is available"
            return 0
        fi
        sleep "$SLEEP_SECONDS"
    done

    echo "ERROR: ${service}:${port} is unavailable"
    "${DC[@]}" logs --tail=100 "$service" || true
    exit 1
}

wait_primary_single() {
    local service="$1"
    local port="$2"

    echo "Waiting for PRIMARY on ${service}:${port}..."

    for ((i=1; i<=MAX_ATTEMPTS; i++)); do
        result="$(
            mongo_eval "$service" "$port" 'print(db.hello().isWritablePrimary)' 2>/dev/null \
                | tail -n 1 | tr -d '\r '
        )"

        if [[ "$result" == "true" ]]; then
            echo "OK: ${service}:${port} is PRIMARY"
            return 0
        fi
        sleep "$SLEEP_SECONDS"
    done

    echo "ERROR: ${service}:${port} did not become PRIMARY"
    exit 1
}

wait_replica_ready() {
    local name="$1"
    local exec_service="$2"
    local uri="$3"

    echo "Waiting for ReplicaSet ${name} (1 PRIMARY + 2 SECONDARY)..."

    for ((i=1; i<=MAX_ATTEMPTS; i++)); do
        summary="$(
            repl_eval "$exec_service" "$uri" '
                const members = rs.status().members || [];
                const primary = members.filter(m => m.stateStr === "PRIMARY").length;
                const secondary = members.filter(m => m.stateStr === "SECONDARY").length;
                print(members.length + ":" + primary + ":" + secondary);
            ' 2>/dev/null | tail -n 1 | tr -d '\r '
        )"

        if [[ "$summary" == "3:1:2" ]]; then
            echo "OK: ${name} is ready (${summary})"
            return 0
        fi

        echo "  attempt ${i}/${MAX_ATTEMPTS}: ${summary:-not ready}"
        sleep "$SLEEP_SECONDS"
    done

    echo "ERROR: ReplicaSet ${name} is not ready"
    exit 1
}

echo
echo "=== 1. Start Config Server and shard replicas ==="

"${DC[@]}" up -d \
    configSrv \
    shard1-1 shard1-2 shard1-3 \
    shard2-1 shard2-2 shard2-3

wait_mongo configSrv 27017
wait_mongo shard1-1 27018
wait_mongo shard1-2 27018
wait_mongo shard1-3 27018
wait_mongo shard2-1 27019
wait_mongo shard2-2 27019
wait_mongo shard2-3 27019

echo
echo "=== 2. Initialize Config Server ReplicaSet ==="

if mongo_eval configSrv 27017 'try { rs.status(); quit(0); } catch (e) { quit(1); }' >/dev/null 2>&1; then
    echo "config_server is already initialized"
else
    mongo_eval configSrv 27017 '
        const result = rs.initiate({
            _id: "config_server",
            configsvr: true,
            members: [{_id: 0, host: "configSrv:27017"}]
        });
        printjson(result);
        if (result.ok !== 1) quit(1);
    '
fi

echo
echo "=== 3. Initialize shard1 ReplicaSet ==="

if mongo_eval shard1-1 27018 'try { rs.status(); quit(0); } catch (e) { quit(1); }' >/dev/null 2>&1; then
    echo "shard1 is already initialized"
else
    mongo_eval shard1-1 27018 '
        const result = rs.initiate({
            _id: "shard1",
            members: [
                {_id: 0, host: "shard1-1:27018", priority: 2},
                {_id: 1, host: "shard1-2:27018", priority: 1},
                {_id: 2, host: "shard1-3:27018", priority: 1}
            ]
        });
        printjson(result);
        if (result.ok !== 1) quit(1);
    '
fi

echo
echo "=== 4. Initialize shard2 ReplicaSet ==="

if mongo_eval shard2-1 27019 'try { rs.status(); quit(0); } catch (e) { quit(1); }' >/dev/null 2>&1; then
    echo "shard2 is already initialized"
else
    mongo_eval shard2-1 27019 '
        const result = rs.initiate({
            _id: "shard2",
            members: [
                {_id: 0, host: "shard2-1:27019", priority: 2},
                {_id: 1, host: "shard2-2:27019", priority: 1},
                {_id: 2, host: "shard2-3:27019", priority: 1}
            ]
        });
        printjson(result);
        if (result.ok !== 1) quit(1);
    '
fi

SHARD1_URI='mongodb://shard1-1:27018,shard1-2:27018,shard1-3:27018/?replicaSet=shard1'
SHARD2_URI='mongodb://shard2-1:27019,shard2-2:27019,shard2-3:27019/?replicaSet=shard2'

echo
echo "=== 5. Wait for ReplicaSets ==="

wait_primary_single configSrv 27017
wait_replica_ready shard1 shard1-1 "$SHARD1_URI"
wait_replica_ready shard2 shard2-1 "$SHARD2_URI"

echo
echo "=== 6. Start mongos router ==="

"${DC[@]}" up -d mongos_router
wait_mongo mongos_router 27020

echo
echo "=== 7. Register shard1 ==="

mongo_eval mongos_router 27020 '
    const configDB = db.getSiblingDB("config");

    if (!configDB.shards.findOne({_id: "shard1"})) {
        const result = sh.addShard(
            "shard1/shard1-1:27018,shard1-2:27018,shard1-3:27018"
        );
        printjson(result);
        if (result.ok !== 1) quit(1);
    } else {
        print("shard1 is already registered");
    }
'

echo
echo "=== 8. Register shard2 ==="

mongo_eval mongos_router 27020 '
    const configDB = db.getSiblingDB("config");

    if (!configDB.shards.findOne({_id: "shard2"})) {
        const result = sh.addShard(
            "shard2/shard2-1:27019,shard2-2:27019,shard2-3:27019"
        );
        printjson(result);
        if (result.ok !== 1) quit(1);
    } else {
        print("shard2 is already registered");
    }
'

echo
echo "=== 9. Validate shards ==="

SHARD_COUNT="$(
    mongo_eval mongos_router 27020 \
        'print(db.getSiblingDB("config").shards.countDocuments())' \
        | tail -n 1 | tr -d '\r '
)"

echo "Registered shards: $SHARD_COUNT"

if ! [[ "$SHARD_COUNT" =~ ^[0-9]+$ ]] || [[ "$SHARD_COUNT" -ne 2 ]]; then
    echo "ERROR: expected 2 registered shards, got ${SHARD_COUNT}"
    exit 1
fi

echo
echo "=== 10. Enable sharding for somedb ==="

mongo_eval mongos_router 27020 '
    const configDB = db.getSiblingDB("config");
    const database = configDB.databases.findOne({_id: "somedb"});

    if (!database || database.partitioned !== true) {
        printjson(sh.enableSharding("somedb"));
    } else {
        print("Sharding is already enabled for somedb");
    }
'

echo
echo "=== 11. Shard somedb.helloDoc ==="

mongo_eval mongos_router 27020 '
    const configDB = db.getSiblingDB("config");
    const collection = configDB.collections.findOne({
        _id: "somedb.helloDoc",
        dropped: {$ne: true}
    });

    if (!collection || !collection.key) {
        const result = sh.shardCollection(
            "somedb.helloDoc",
            {name: "hashed"}
        );
        printjson(result);
        if (result.ok !== 1) quit(1);
    } else {
        print("somedb.helloDoc is already sharded");
    }
'

echo
echo "=== 12. Seed 1000 documents ==="

mongo_eval mongos_router 27020 '
    const appDB = db.getSiblingDB("somedb");
    const operations = [];

    for (let i = 0; i < 1000; i++) {
        operations.push({
            updateOne: {
                filter: {name: "ly" + i},
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

    const result = appDB.helloDoc.bulkWrite(operations, {ordered:false});
    printjson({
        upserted: result.upsertedCount,
        total: appDB.helloDoc.countDocuments()
    });
'

TOTAL="$(
    mongo_eval mongos_router 27020 \
        'print(db.getSiblingDB("somedb").helloDoc.countDocuments())' \
        | tail -n 1 | tr -d '\r '
)"

echo "Total documents via mongos: $TOTAL"

if ! [[ "$TOTAL" =~ ^[0-9]+$ ]] || [[ "$TOTAL" -lt 1000 ]]; then
    echo "ERROR: expected at least 1000 documents, got ${TOTAL}"
    exit 1
fi

echo
echo "=== 13. Validate documents on both shards ==="

SHARD1_COUNT="$(
    repl_eval shard1-1 "$SHARD1_URI" \
        'print(db.getSiblingDB("somedb").helloDoc.countDocuments())' \
        | tail -n 1 | tr -d '\r '
)"

SHARD2_COUNT="$(
    repl_eval shard2-1 "$SHARD2_URI" \
        'print(db.getSiblingDB("somedb").helloDoc.countDocuments())' \
        | tail -n 1 | tr -d '\r '
)"

echo "shard1 documents: $SHARD1_COUNT"
echo "shard2 documents: $SHARD2_COUNT"

if ! [[ "$SHARD1_COUNT" =~ ^[0-9]+$ ]] \
    || ! [[ "$SHARD2_COUNT" =~ ^[0-9]+$ ]] \
    || [[ "$SHARD1_COUNT" -le 0 ]] \
    || [[ "$SHARD2_COUNT" -le 0 ]]; then
    echo "ERROR: documents must exist on both shards"
    exit 1
fi

echo
echo "=== 14. Start pymongo-api ==="

"${DC[@]}" up -d --build pymongo-api

echo
echo "=== Initialization completed ==="
echo "Registered shards: $SHARD_COUNT"
echo "Total documents:   $TOTAL"
echo "shard1 documents:  $SHARD1_COUNT"
echo "shard2 documents:  $SHARD2_COUNT"
echo "shard1 replicas:   3"
echo "shard2 replicas:   3"

echo
echo "ReplicaSet shard1:"
repl_eval shard1-1 "$SHARD1_URI" \
    'printjson(rs.status().members.map(m => ({name:m.name,state:m.stateStr})))'

echo
echo "ReplicaSet shard2:"
repl_eval shard2-1 "$SHARD2_URI" \
    'printjson(rs.status().members.map(m => ({name:m.name,state:m.stateStr})))'

echo
"${DC[@]}" ps

echo
echo "Next: bash check.sh"
