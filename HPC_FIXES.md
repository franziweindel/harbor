# Apptainer bridge fixes on this branch (franziska/zih-bridge)

Base: `marin-community/harbor @ main` (2b6a406, 2026-08-24). This branch only
touches `src/harbor/environments/apptainer/worker.py` (§1–3) and
`server.py` (§4). Found while bringing the bridge up on ZIH (Alpha Centauri and Capella: Slurm, Lustre, Apptainer
1.5, no Docker, no root, no `/etc/subuid` entry for the user).

How the bridge works, for orientation: Harbor's driver never runs `apptainer`
itself. It POSTs start/exec/upload/stop requests to a small HTTP relay
(`server.py`); `worker.py` processes on compute nodes poll that relay, own the
Apptainer instances, and run every command in them. Everything below is on the
worker side, i.e. inside those instances. Each fix was isolated with the
oracle (golden solution, then verifier) on three Terminal-Lego tasks, first
with relay, workers and driver on one node ("loopback", so the network is not
a variable), then with relay and workers on a different cluster than the
driver; the table at the end lists every configuration and its result.

## 1. Tasks need root inside the container

Docker runs a task as root, so verifiers and solutions install packages
freely (`apt-get install curl`, `pip install …`, writing under `/root`). The
worker started every instance as the calling user. Inside, `apt-get` got as
far as downloading the packages and then `dpkg` refused: `requested operation
requires superuser privilege`. The verifier's later steps (`curl`, `uvx`)
were missing and every task scored 0 — without any error surfacing, because
each command did "run" and exit.

Fix: start the instance with `--fakeroot`. Commands exec'd into a running
instance join its namespaces, so only the start needs the flag. The mode is
selectable with `BRIDGE_USE_FAKEROOT`: `1` always, `0` never (the old
behaviour), `auto` (default) tries with fakeroot first and falls back
without, for base images whose old glibc cannot load Apptainer's fakeroot
helper (see the sibling local-mode fork's HPC_FIXES.md §7 for that case).

## 2. Fakeroot and the ext3 overlay do not mix

The worker gives each instance a writable layer as an ext3 image file
(`overlay.img`, created with `apptainer overlay create`). That is the right
choice on setuid installations such as MareNostrum 5, where a non-root user
may not use a directory as overlay. Combined with `--fakeroot` it fails on
ZIH: the image is created by the real uid, and the namespace-root that
fakeroot maps us to cannot write its upper directory — the start dies with
`setup of overlay upper dir failed: … /upper is not writable: permission
denied`, and `auto` mode silently fell back to the rootless start of §1.

Fix: choose the overlay per start attempt. With `--fakeroot` use a plain
directory under the worker's staging directory (kernel overlayfs inside the
user namespace; the staging directory is node-local, which overlayfs needs
for its upper dir). Without fakeroot keep the ext3 image exactly as before,
so setuid clusters are unaffected.

## 3. apt inside a single-uid user namespace

Without a `/etc/subuid` entry, `--fakeroot` maps only our own uid to 0;
every other uid is unmapped. apt normally drops privileges to the `_apt`
user (uid 100) for downloads and keeps its download directories owned by it
with mode 700, which namespace-root cannot write. The worker's post-start
script therefore writes an apt config that runs apt as root and points its
archive and list directories at fresh root-owned ones on the overlay. Only
applied when the instance actually started with fakeroot.

Verified necessary in isolation: with §1 and §2 in place but this config
left out, apt downloads the packages and then fails on every one with
`Could not open file /var/cache/apt/archives/partial/….deb – Permission
denied`; `curl` is never installed and the task scores 0.

## 4. Jobs vanish when the worker host name contains a dash

The relay routes every job after the first (exec, upload, download, stop)
to the node that owns the instance — "sticky" routing. It derived that
node's queue key from the recorded worker id with `rsplit("-", 1)[0]`,
assuming the `host-N` shape of the single-job endpoint, while the per-node
dispatcher polls the batch endpoint with its bare host name. On a host
whose name contains a dash the two disagree: on ZIH Julia the worker
reports `julia.hpc.tu-dresden.de`, the relay queued its jobs under
`julia.hpc.tu`, nobody ever polled that key, and every upload/exec timed
out after 120 s (`/status` showed `jobs_submitted: 33, jobs_completed: 6,
queue_size: 0, active_jobs: 0`). JSC (`jwc07n056`) and ZIH Alpha (`i8035`)
host names have no dash, which is why it never surfaced there.

Fix: record the queue key on the environment when the START job is handed
out (both endpoints), and route later jobs by that recorded key. The
`rsplit` derivation stays only as a fallback for environments created
before the fix.

## What is deliberately NOT changed

- Nothing on the driver side (`apptainer.py`); `server.py` only gains the
  recorded queue key of §4.
- The one-`exec`-per-action model. The local-mode fork needed a persistent
  "anchor" exec because there a tmux server started by one exec was killed
  when that exec exited. Through the bridge worker this does not happen:
  probed on ZIH Julia and Alpha (fakeroot instance, Apptainer 1.5) — a tmux server
  started in one exec is still listed by the next exec, and `send-keys`
  from a third exec runs the command. An agent run (terminus-2 on Qwen3-8B,
  Alpha, 2 tasks) confirms it end to end: one task solved (reward 1), the
  other a genuine model failure (it declared the task complete after one
  batch). No anchor is needed on the bridge side.

## Verified on ZIH

Oracle over tasks task_01501, task_03245, task_06714 from
`SWE-Lego/Terminal-Lego-15k` (scripts in OpenThoughts-Agent-trp
`data/teacher_ranking_proxy/bridge_deploy/`):

| setup | worker code | oracle reward |
|---|---|---|
| loopback, one Alpha node | upstream main (rootless, ext3 overlay) | 0, 0, 0 |
| loopback, one Alpha node | + §1 alone (fakeroot start failed, auto fell back) | 0, 0, 0 |
| loopback, one Alpha node | + §1 + §2 + §3 | 1, 1, 1 |
| cross-cluster: relay + workers on Julia, driver on Capella login | + §1–3, without §4 | error: every job after START timed out |
| cross-cluster, same | + §1–2 + §4, §3 disabled | 0, 0, 0 (apt partial/ permission denied) |
| cross-cluster, same | + §1–4 | 1, 1, 1 |
