#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="$SCRIPT_DIR/compose.yaml"
DC=(docker compose -f "$COMPOSE_FILE")

SHARD1_URI='mongodb://shard1-1:27018,shard1-2:27018,shard1-3:27018/?replicaSet=shard1'
SHARD2_URI='mongodb://shard2-1:27019,shard2-2:27019,shard2-3:27019/?replicaSet=shard2'

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

number_from() {
    tail -n 1 | tr -d '\r '
}

FAILED=0

echo "=== Docker services ==="
"${DC[@]}" ps

echo
echo "=== Config Server ==="
CONFIG_PRIMARY="$(
    mongo_eval configSrv 27017 'print(db.hello().isWritablePrimary)' \
        | number_from
)"
echo "configSrv PRIMARY: $CONFIG_PRIMARY"

if [[ "$CONFIG_PRIMARY" != "true" ]]; then
    echo "ERROR: configSrv is not PRIMARY"
    FAILED=1
fi

echo
echo "=== Registered shards ==="
SHARD_COUNT="$(
    mongo_eval mongos_router 27020 \
        'print(db.getSiblingDB("config").shards.countDocuments())' \
        | number_from
)"
echo "Shard count: $SHARD_COUNT"

if ! [[ "$SHARD_COUNT" =~ ^[0-9]+$ ]] || [[ "$SHARD_COUNT" -ne 2 ]]; then
    echo "ERROR: expected 2 registered shards, got $SHARD_COUNT"
    FAILED=1
else
    echo "OK: 2 shards are registered"
fi

echo
echo "=== Total documents through mongos_router ==="
TOTAL="$(
    mongo_eval mongos_router 27020 \
        'print(db.getSiblingDB("somedb").helloDoc.countDocuments())' \
        | number_from
)"
echo "Total: $TOTAL"

if ! [[ "$TOTAL" =~ ^[0-9]+$ ]] || [[ "$TOTAL" -lt 1000 ]]; then
    echo "ERROR: expected at least 1000 documents, got $TOTAL"
    FAILED=1
else
    echo "OK: total documents >= 1000"
fi

echo
echo "=== Documents on shard1 ==="
SHARD1_COUNT="$(
    repl_eval shard1-1 "$SHARD1_URI" \
        'print(db.getSiblingDB("somedb").helloDoc.countDocuments())' \
        | number_from
)"
echo "shard1: $SHARD1_COUNT"

if ! [[ "$SHARD1_COUNT" =~ ^[0-9]+$ ]] || [[ "$SHARD1_COUNT" -le 0 ]]; then
    echo "ERROR: expected documents on shard1"
    FAILED=1
else
    echo "OK: shard1 contains documents"
fi

echo
echo "=== Documents on shard2 ==="
SHARD2_COUNT="$(
    repl_eval shard2-1 "$SHARD2_URI" \
        'print(db.getSiblingDB("somedb").helloDoc.countDocuments())' \
        | number_from
)"
echo "shard2: $SHARD2_COUNT"

if ! [[ "$SHARD2_COUNT" =~ ^[0-9]+$ ]] || [[ "$SHARD2_COUNT" -le 0 ]]; then
    echo "ERROR: expected documents on shard2"
    FAILED=1
else
    echo "OK: shard2 contains documents"
fi

echo
echo "=== shard1 ReplicaSet ==="
repl_eval shard1-1 "$SHARD1_URI" \
    'printjson(rs.status().members.map(m => ({name:m.name,state:m.stateStr})))'

SHARD1_REPLICAS="$(
    repl_eval shard1-1 "$SHARD1_URI" \
        'print(rs.status().members.length)' \
        | number_from
)"

SHARD1_PRIMARY="$(
    repl_eval shard1-1 "$SHARD1_URI" \
        'print(rs.status().members.filter(m => m.stateStr === "PRIMARY").length)' \
        | number_from
)"

SHARD1_SECONDARY="$(
    repl_eval shard1-1 "$SHARD1_URI" \
        'print(rs.status().members.filter(m => m.stateStr === "SECONDARY").length)' \
        | number_from
)"

echo "Replica count: $SHARD1_REPLICAS"
echo "PRIMARY:       $SHARD1_PRIMARY"
echo "SECONDARY:     $SHARD1_SECONDARY"

if [[ "$SHARD1_REPLICAS" != "3" ]] \
    || [[ "$SHARD1_PRIMARY" != "1" ]] \
    || [[ "$SHARD1_SECONDARY" != "2" ]]; then
    echo "ERROR: shard1 must have 3 replicas: 1 PRIMARY + 2 SECONDARY"
    FAILED=1
else
    echo "OK: shard1 has 3 healthy replicas"
fi

echo
echo "=== shard2 ReplicaSet ==="
repl_eval shard2-1 "$SHARD2_URI" \
    'printjson(rs.status().members.map(m => ({name:m.name,state:m.stateStr})))'

SHARD2_REPLICAS="$(
    repl_eval shard2-1 "$SHARD2_URI" \
        'print(rs.status().members.length)' \
        | number_from
)"

SHARD2_PRIMARY="$(
    repl_eval shard2-1 "$SHARD2_URI" \
        'print(rs.status().members.filter(m => m.stateStr === "PRIMARY").length)' \
        | number_from
)"

SHARD2_SECONDARY="$(
    repl_eval shard2-1 "$SHARD2_URI" \
        'print(rs.status().members.filter(m => m.stateStr === "SECONDARY").length)' \
        | number_from
)"

echo "Replica count: $SHARD2_REPLICAS"
echo "PRIMARY:       $SHARD2_PRIMARY"
echo "SECONDARY:     $SHARD2_SECONDARY"

if [[ "$SHARD2_REPLICAS" != "3" ]] \
    || [[ "$SHARD2_PRIMARY" != "1" ]] \
    || [[ "$SHARD2_SECONDARY" != "2" ]]; then
    echo "ERROR: shard2 must have 3 replicas: 1 PRIMARY + 2 SECONDARY"
    FAILED=1
else
    echo "OK: shard2 has 3 healthy replicas"
fi

echo
echo "=== Sharding status ==="
mongo_eval mongos_router 27020 'sh.status()'

echo
echo "=== Application ==="
if command -v curl >/dev/null 2>&1; then
    echo "GET http://localhost:8080/"
    curl -fsS --max-time 10 http://localhost:8080/ || \
        echo "WARNING: root endpoint did not return a successful HTTP response"
    echo
else
    echo "curl is not installed; open http://localhost:8080/ in a browser"
fi

echo
echo "=== Validation ==="

if [[ "$FAILED" -ne 0 ]]; then
    echo "FAILED"
    exit 1
fi

echo "OK: 2 shards registered"
echo "OK: total documents >= 1000"
echo "OK: documents exist on both shards"
echo "OK: shard1 has 3 replicas (1 PRIMARY + 2 SECONDARY)"
echo "OK: shard2 has 3 replicas (1 PRIMARY + 2 SECONDARY)"
echo "SUCCESS"
