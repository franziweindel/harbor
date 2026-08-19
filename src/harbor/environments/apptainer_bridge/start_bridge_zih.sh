#!/bin/bash
# Start the Apptainer bridge server on ZIH.
#
# The bridge is a tiny stdlib-only HTTP server (server.py) — no GPU, minimal
# CPU. Two placement options:
#   1. small CPU-bearing Slurm job (recommended; login nodes kill >600s-CPU
#      processes, though the bridge is mostly idle so it MAY survive there);
#   2. login node inside tmux for short experiments.
# Workers and the harbor driver must be able to reach $HOST:$PORT over TCP.
#
# Usage:  ./start_bridge_zih.sh [port]
set -e
PORT="${1:-9910}"
HERE="$(dirname "$0")"
echo "bridge listening on $(hostname):$PORT — export APPTAINER_BRIDGE_URL=http://$(hostname):$PORT"
exec python3 "$HERE/server.py" --host 0.0.0.0 --port "$PORT"
