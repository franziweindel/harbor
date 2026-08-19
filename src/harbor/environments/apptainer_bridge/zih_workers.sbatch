#!/bin/bash
#SBATCH --job-name=trp-bridge-workers
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=14
#SBATCH --gres=gpu:1
#SBATCH --mem=100G
#SBATCH --time=12:00:00
#SBATCH --partition=capella
#SBATCH --output=%x_%j.out

# Apptainer Bridge Workers on ZIH Capella.
#
# Capella quirks (see OpenThoughts-Agent-trp/.agents/ops/zih/ops.md):
#   * the submit cli_filter REJECTS jobs without gres and typed gres —
#     use UNTYPED --gres=gpu:1 even though workers are CPU-bound;
#   * CPUs are capped at 14 per requested GPU on non-exclusive jobs;
#   * staging/overlays MUST be node-local ($TMPDIR), never /data/* (Lustre);
#   * worker python: use a node-local venv copy w/ shebang rewrite if the
#     venv lives on Lustre (see teacher-proxy-cluster-setup skill).
#
# --- Barnard (CPU cluster) variant: UNVERIFIED -------------------------------
# Barnard has no GPUs and (presumably) no GPU-gres cli_filter; a variant would
# look like:
#   #SBATCH --partition=barnard --cpus-per-task=64 --mem=128G   (no --gres)
# Prerequisite before using: verify Barnard compute nodes can reach the
# bridge host over TCP (and the bridge can reach nothing on the workers —
# workers only poll OUT to the bridge, which helps across clusters).
# -----------------------------------------------------------------------------
#
# Usage:
#   BRIDGE_URL=http://<bridge-host>:9910 sbatch zih_workers.sbatch

set -e

BRIDGE_URL="${BRIDGE_URL:?set BRIDGE_URL=http://<bridge-host>:9910}"
WS_ROOT="${WS_ROOT:?set WS_ROOT (e.g. /data/cat/ws/<user>-otagent)}"
SIF_CACHE="${SIF_CACHE:-$WS_ROOT/teacher_ranking_proxy/harbor_sif_cache}"
STAGING_BASE="${STAGING_BASE:-${TMPDIR:-/tmp}/apptainer_bridge_staging}"
WORKERS_PER_NODE="${WORKERS_PER_NODE:-12}"

WORKER_SCRIPT="$(dirname "$0")/worker.py"

mkdir -p "$STAGING_BASE"
echo "bridge=$BRIDGE_URL sif_cache=$SIF_CACHE staging=$STAGING_BASE workers=$WORKERS_PER_NODE"

exec python3 "$WORKER_SCRIPT" \
    --bridge-url "$BRIDGE_URL" \
    --sif-cache "$SIF_CACHE" \
    --staging-base "$STAGING_BASE" \
    --num-workers "$WORKERS_PER_NODE"
