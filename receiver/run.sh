#!/bin/sh
# Starts the receiver with settings from receiver/.env (see example.env).
set -eu
cd "$(dirname "$0")"
if [ ! -f .env ]; then echo "Missing receiver/.env — copy example.env and set WR_TOKEN (python3 scripts/gen_token.py)." >&2; exit 2; fi
set -a; . ./.env; set +a
umask 077
exec python3 server.py "$@"
