#!/bin/bash
set -e

if [ "$1" = "node" ] || [ "$1" = "npm" ]; then
    echo "[entrypoint] Running custom command: $*"
    exec "$@"
fi

echo "[entrypoint] Starting nginx..."
nginx

echo "[entrypoint] Starting IDURAR backend on port ${PORT:-8888}..."
exec node src/server.js
