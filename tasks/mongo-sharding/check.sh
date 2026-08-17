#!/usr/bin/env bash
set -euo pipefail
DC="docker compose"

echo "=== Services ==="
$DC ps

echo
echo "=== Total through mongos_router ==="
$DC exec -T mongos_router mongosh --port 27020 --quiet <<'EOF'
use somedb
db.helloDoc.countDocuments()
EOF

echo
echo "=== shard1 ==="
$DC exec -T shard1 mongosh --port 27018 --quiet <<'EOF'
use somedb
db.helloDoc.countDocuments()
EOF

echo
echo "=== shard2 ==="
$DC exec -T shard2 mongosh --port 27019 --quiet <<'EOF'
use somedb
db.helloDoc.countDocuments()
EOF

echo
echo "=== Sharding status ==="
$DC exec -T mongos_router mongosh --port 27020 --quiet --eval 'sh.status()'
