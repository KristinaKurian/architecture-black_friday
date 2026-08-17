#!/usr/bin/env bash

set -euo pipefail

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yaml"

DC=(docker compose -f "$COMPOSE_FILE")

MAX_ATTEMPTS=30
SLEEP_SECONDS=2


# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

mongo_eval() {
    local service="$1"
    local port="$2"
    local command="$3"

    "${DC[@]}" exec -T "$service" \
        mongosh \
        --port "$port" \
        --quiet \
        --eval "$command"
}


wait_mongo() {
    local service="$1"
    local port="$2"

    echo "Waiting for ${service}:${port}..."

    for ((i=1; i<=MAX_ATTEMPTS; i++)); do

        if mongo_eval \
            "$service" \
            "$port" \
            'db.adminCommand({ping: 1}).ok' \
            >/dev/null 2>&1; then

            echo "${service}:${port} is available"
            return 0
        fi

        echo "  attempt ${i}/${MAX_ATTEMPTS}"
        sleep "$SLEEP_SECONDS"
    done

    echo "ERROR: ${service}:${port} is unavailable"

    "${DC[@]}" logs --tail=100 "$service" || true

    exit 1
}


wait_primary() {
    local service="$1"
    local port="$2"

    echo "Waiting for PRIMARY on ${service}:${port}..."

    for ((i=1; i<=MAX_ATTEMPTS; i++)); do

        result="$(
            mongo_eval \
                "$service" \
                "$port" \
                'print(db.hello().isWritablePrimary)' \
                2>/dev/null \
                | tail -n 1 \
                | tr -d '\r '
        )"

        if [[ "$result" == "true" ]]; then
            echo "${service}:${port} is PRIMARY"
            return 0
        fi

        echo "  attempt ${i}/${MAX_ATTEMPTS}"
        sleep "$SLEEP_SECONDS"
    done

    echo "ERROR: ${service}:${port} did not become PRIMARY"

    "${DC[@]}" logs --tail=100 "$service" || true

    exit 1
}


get_document_count() {
    local service="$1"
    local port="$2"

    mongo_eval \
        "$service" \
        "$port" \
        'print(db.getSiblingDB("somedb").helloDoc.countDocuments())' \
        | tail -n 1 \
        | tr -d '\r '
}


# ------------------------------------------------------------
# Start MongoDB instances
# ------------------------------------------------------------

echo
echo "=================================================="
echo "1. Start Config Server and shards"
echo "=================================================="

"${DC[@]}" up -d configSrv shard1 shard2


wait_mongo configSrv 27017
wait_mongo shard1 27018
wait_mongo shard2 27019


# ------------------------------------------------------------
# Config Server ReplicaSet
# ------------------------------------------------------------

echo
echo "=================================================="
echo "2. Initialize Config Server ReplicaSet"
echo "=================================================="

if mongo_eval \
    configSrv \
    27017 \
    'try { rs.status(); quit(0); } catch (e) { quit(1); }' \
    >/dev/null 2>&1; then

    echo "config_server is already initialized"

else

    mongo_eval \
        configSrv \
        27017 \
        '
        const result = rs.initiate({
            _id: "config_server",
            configsvr: true,
            members: [
                {
                    _id: 0,
                    host: "configSrv:27017"
                }
            ]
        });

        printjson(result);

        if (result.ok !== 1) {
            quit(1);
        }
        '

fi


# ------------------------------------------------------------
# Shard 1 ReplicaSet
# ------------------------------------------------------------

echo
echo "=================================================="
echo "3. Initialize shard1 ReplicaSet"
echo "=================================================="

if mongo_eval \
    shard1 \
    27018 \
    'try { rs.status(); quit(0); } catch (e) { quit(1); }' \
    >/dev/null 2>&1; then

    echo "shard1 is already initialized"

else

    mongo_eval \
        shard1 \
        27018 \
        '
        const result = rs.initiate({
            _id: "shard1",
            members: [
                {
                    _id: 0,
                    host: "shard1:27018"
                }
            ]
        });

        printjson(result);

        if (result.ok !== 1) {
            quit(1);
        }
        '

fi


# ------------------------------------------------------------
# Shard 2 ReplicaSet
# ------------------------------------------------------------

echo
echo "=================================================="
echo "4. Initialize shard2 ReplicaSet"
echo "=================================================="

if mongo_eval \
    shard2 \
    27019 \
    'try { rs.status(); quit(0); } catch (e) { quit(1); }' \
    >/dev/null 2>&1; then

    echo "shard2 is already initialized"

else

    mongo_eval \
        shard2 \
        27019 \
        '
        const result = rs.initiate({
            _id: "shard2",
            members: [
                {
                    _id: 0,
                    host: "shard2:27019"
                }
            ]
        });

        printjson(result);

        if (result.ok !== 1) {
            quit(1);
        }
        '

fi


# ------------------------------------------------------------
# Wait for PRIMARY
# ------------------------------------------------------------

echo
echo "=================================================="
echo "5. Wait for ReplicaSet PRIMARY"
echo "=================================================="

wait_primary configSrv 27017
wait_primary shard1 27018
wait_primary shard2 27019


# ------------------------------------------------------------
# Start mongos
# ------------------------------------------------------------

echo
echo "=================================================="
echo "6. Start mongos router"
echo "=================================================="

"${DC[@]}" up -d mongos_router

wait_mongo mongos_router 27020


# ------------------------------------------------------------
# Add shard1
# ------------------------------------------------------------

echo
echo "=================================================="
echo "7. Register shard1"
echo "=================================================="

mongo_eval \
    mongos_router \
    27020 \
    '
    const configDB = db.getSiblingDB("config");

    if (!configDB.shards.findOne({_id: "shard1"})) {

        print("Adding shard1...");

        const result =
            sh.addShard("shard1/shard1:27018");

        printjson(result);

        if (result.ok !== 1) {
            quit(1);
        }

    } else {

        print("shard1 is already registered");

    }
    '


# ------------------------------------------------------------
# Add shard2
# ------------------------------------------------------------

echo
echo "=================================================="
echo "8. Register shard2"
echo "=================================================="

mongo_eval \
    mongos_router \
    27020 \
    '
    const configDB = db.getSiblingDB("config");

    if (!configDB.shards.findOne({_id: "shard2"})) {

        print("Adding shard2...");

        const result =
            sh.addShard("shard2/shard2:27019");

        printjson(result);

        if (result.ok !== 1) {
            quit(1);
        }

    } else {

        print("shard2 is already registered");

    }
    '


# ------------------------------------------------------------
# Validate shards
# ------------------------------------------------------------

echo
echo "=================================================="
echo "9. Validate registered shards"
echo "=================================================="

SHARD_COUNT="$(
    mongo_eval \
        mongos_router \
        27020 \
        'print(db.getSiblingDB("config").shards.countDocuments())' \
        | tail -n 1 \
        | tr -d '\r '
)"

echo "Registered shards: $SHARD_COUNT"

if ! [[ "$SHARD_COUNT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid shard count: $SHARD_COUNT"
    exit 1
fi

if [[ "$SHARD_COUNT" -ne 2 ]]; then
    echo "ERROR: expected 2 shards, got $SHARD_COUNT"
    exit 1
fi

echo "OK: 2 shards registered"


# ------------------------------------------------------------
# Enable database sharding
# ------------------------------------------------------------

echo
echo "=================================================="
echo "10. Enable sharding for somedb"
echo "=================================================="

mongo_eval \
    mongos_router \
    27020 \
    '
    const result = sh.enableSharding("somedb");

    printjson(result);

    if (result.ok !== 1) {
        quit(1);
    }
    '


# ------------------------------------------------------------
# Shard collection
# ------------------------------------------------------------

echo
echo "=================================================="
echo "11. Shard somedb.helloDoc"
echo "=================================================="

mongo_eval \
    mongos_router \
    27020 \
    '
    const configDB = db.getSiblingDB("config");

    const collection =
        configDB.collections.findOne({
            _id: "somedb.helloDoc",
            dropped: { $ne: true }
        });

    if (!collection || !collection.key) {

        print("Creating hashed sharded collection...");

        const result =
            sh.shardCollection(
                "somedb.helloDoc",
                {
                    name: "hashed"
                }
            );

        printjson(result);

        if (result.ok !== 1) {
            quit(1);
        }

    } else {

        print("somedb.helloDoc is already sharded");
        printjson(collection.key);

    }
    '


# ------------------------------------------------------------
# Insert test data
# ------------------------------------------------------------

echo
echo "=================================================="
echo "12. Create 1000 test documents"
echo "=================================================="

mongo_eval \
    mongos_router \
    27020 \
    '
    const appDB = db.getSiblingDB("somedb");

    const operations = [];

    for (let i = 0; i < 1000; i++) {

        operations.push({

            updateOne: {

                filter: {
                    name: "ly" + i
                },

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

    const result =
        appDB.helloDoc.bulkWrite(
            operations,
            {
                ordered: false
            }
        );

    printjson({
        inserted: result.upsertedCount,
        total: appDB.helloDoc.countDocuments()
    });
    '


# ------------------------------------------------------------
# Validate document count
# ------------------------------------------------------------

echo
echo "=================================================="
echo "13. Validate document count"
echo "=================================================="

TOTAL="$(
    mongo_eval \
        mongos_router \
        27020 \
        'print(db.getSiblingDB("somedb").helloDoc.countDocuments())' \
        | tail -n 1 \
        | tr -d '\r '
)"

echo "Total documents via mongos: $TOTAL"

if ! [[ "$TOTAL" =~ ^[0-9]+$ ]]; then
    echo "ERROR: invalid document count: $TOTAL"
    exit 1
fi

if [[ "$TOTAL" -lt 1000 ]]; then
    echo "ERROR: expected at least 1000 documents, got $TOTAL"
    exit 1
fi

echo "OK: database contains at least 1000 documents"


# ------------------------------------------------------------
# Wait for distribution
# ------------------------------------------------------------

echo
echo "=================================================="
echo "14. Check document distribution"
echo "=================================================="

SHARD1_COUNT=0
SHARD2_COUNT=0

for ((i=1; i<=MAX_ATTEMPTS; i++)); do

    SHARD1_COUNT="$(get_document_count shard1 27018)"
    SHARD2_COUNT="$(get_document_count shard2 27019)"

    echo \
        "attempt ${i}/${MAX_ATTEMPTS}: " \
        "shard1=${SHARD1_COUNT}, shard2=${SHARD2_COUNT}"

    if [[ "$SHARD1_COUNT" =~ ^[0-9]+$ ]] \
        && [[ "$SHARD2_COUNT" =~ ^[0-9]+$ ]] \
        && [[ "$SHARD1_COUNT" -gt 0 ]] \
        && [[ "$SHARD2_COUNT" -gt 0 ]]; then

        break
    fi

    sleep "$SLEEP_SECONDS"
done


if [[ "$SHARD1_COUNT" -eq 0 ]] || [[ "$SHARD2_COUNT" -eq 0 ]]; then

    echo
    echo "ERROR: documents were not distributed between both shards"

    echo
    echo "Current sharding status:"

    mongo_eval \
        mongos_router \
        27020 \
        'sh.status()'

    exit 1
fi


echo
echo "Documents on shard1: $SHARD1_COUNT"
echo "Documents on shard2: $SHARD2_COUNT"


# ------------------------------------------------------------
# Start application
# ------------------------------------------------------------

echo
echo "=================================================="
echo "15. Start pymongo-api"
echo "=================================================="

"${DC[@]}" up -d pymongo-api


# ------------------------------------------------------------
# Final status
# ------------------------------------------------------------

echo
echo "=================================================="
echo "MongoDB sharding initialization completed"
echo "=================================================="

echo
echo "Registered shards: $SHARD_COUNT"
echo "Total documents:   $TOTAL"
echo "shard1 documents:  $SHARD1_COUNT"
echo "shard2 documents:  $SHARD2_COUNT"

echo
echo "Docker services:"
"${DC[@]}" ps

echo
echo "Next:"
echo "bash check.sh"