#!/bin/bash

if [ "$1" = "node" ] || [ "$1" = "npm" ]; then
    echo "[entrypoint] Running custom command: $*"
    exec "$@"
fi

echo "[entrypoint] Waiting for MongoDB..."
for i in $(seq 1 30); do
    if node -e "require('mongoose').connect(process.env.DATABASE || 'mongodb://mongodb:27017/idurar', { serverSelectionTimeoutMS: 3000 }).then(function(){ process.exit(0) }).catch(function(){ process.exit(1) })" 2>/dev/null; then
        echo "[entrypoint] MongoDB is ready."
        break
    fi
    echo "[entrypoint] MongoDB not ready (attempt $i/30), retrying..."
    sleep 3
done

echo "[entrypoint] Running database setup..."
node src/setup/setup.js || echo "[entrypoint] Setup skipped or already done."

echo "[entrypoint] Starting nginx..."
nginx

echo "[entrypoint] Starting IDURAR backend on port ${PORT:-8888}..."
exec node src/server.js
