# HPC/Apptainer fixes on this branch (franziska/hpc-fixes)

Base: `laude-institute/harbor @ penfever/temp-override` (the local
ApptainerEnvironment). Fixes 1-4 are code changes in this repo
(`src/harbor/environments/apptainer.py`,
`src/harbor/agents/terminus_2/tmux_session.py`); fixes 5-6 live in the
consuming pipeline's apptainer shim (OpenThoughts-Agent-trp
`data/teacher_ranking_proxy/apptainer_patch/`) and are documented here for
the complete picture. Found while reproducing Terminal-Lego trace generation
on ZIH Capella (Slurm, Lustre, Apptainer 1.5, no Docker, no user systemd).

## 1. Cached-image bug

`start()` had an early return in the image-already-cached branch, so for
cached images the container was never started and every later exec failed
with "no instance found". Fix: remove the early return so instance start
always runs (and only build when there's no cache hit).

## 2. tmux socket on Lustre (+ bootstrap robustness)

Harbor placed the tmux socket under `/logs/agent/` (bind-mounted from the
run directory — on ZIH that was the Lustre workspace). Unix sockets don't
work on Lustre: every tmux command connecting to it hangs forever with no
error. Fix: put the socket on container-local `/tmp` (node disk), unique
name per trial.

Also for robustness: setup used to wait forever if a tmux command hung.
Now every bootstrap command gets a 60s kill-switch (`timeout`), success is
verified with `list-sessions`, and on failure we retry up to 3 times on a
fresh socket (to catch hangs like the Lustre-socket case above).

## 3. Shell-readiness gate

The agent's first keystrokes were sometimes typed before bash in the
terminal had even started. Fix: type a small echo and wait until the answer
appears — i.e. proof bash is alive — before the agent gets the terminal.

## 4. Dying tmux server (the root cause of dead-terminal trials)

`apptainer exec instance://taskX <command>` enters container X, runs one
command, and exits. Harbor runs one exec per action it wants to execute in
the sandbox. Under Docker, a background process started this way keeps
running afterwards; on Apptainer 1.5, everything an exec spawned is killed
when the exec exits. So the tmux server (which holds the agent's shell
session between actions) died right after the exec that started it, and all
later actions went to a terminal with no shell behind it. No error was
raised because the terminal device (pty) accepts and echoes keystrokes even
with no process reading them — screens looked normal, but no command ever
executed (student trials all 0, while the one-exec-per-command oracle
passed). Fix: each container's Slurm step (same lifetime as the container,
already used for per-task limits) holds one exec open permanently, and the
tmux server runs inside it; all other execs are just tmux clients connecting
to its socket. (Harbor side: `HARBOR_TMUX_ANCHOR=1` makes TmuxSession attach
to the anchored server instead of spawning its own.)

## 5. Resource limits via Slurm steps (environment gap, fixed in the shim)

Code passes `--memory/--cpus` to Apptainer, assuming Apptainer can enforce
them — but it can't on Capella (no root, no user systemd). Fix: the shim
launches each container inside its own Slurm step (`srun --overlap`,
instant, same job), and Slurm — which runs as root — builds the enforcing
cgroup with exactly those limits.

## 6. Nested-srun env cleaning (tiny fix inside #5)

An `srun` launched from inside another step inherits the parent's
CPU-placement environment variables and fails ("CPU binding outside
allocation"). Fix: strip those `SLURM_*` variables before launching the
child step.

## 7. Images whose build steps can't run rootless

One task, `task_10016` from the Terminal-Lego dataset
(`SWE-Lego/Terminal-Lego-15k`). Its Dockerfile is:

```dockerfile
FROM mcr.microsoft.com/dotnet/sdk:6.0
WORKDIR /app
RUN apt-get update && apt-get install -y curl git vim && rm -rf /var/lib/apt/lists/*
```

That base image is built on old Debian (bullseye).

Apptainer converts a Dockerfile into a `.def` file and runs the `RUN` lines in
a `%post` section. With no root on the cluster it falls back to fakeroot, which
preloads a small library into every command so that `apt-get` believes it is
root when it does `chown`/`chmod`. That preload has to link against the glibc
inside the image; against bullseye's glibc it fails to load and the build dies.

Fix: import the base image with `apptainer build … docker://<base>` (no
`%post`, no fakeroot) and run the Dockerfile's own steps separately. Moving them
to instance start and running them in the image did not work. Instead they run
once inside a new user namespace created with `unshare -r`, where our uid is
mapped to 0 — so `apt-get` and `dpkg` see a real root and install normally,
without any fakeroot shim that would have to load against the image's old libs.
What they install is not written back into the SIF, which stays immutable: it
goes into a separate overlay file next to it. At trial time that overlay is
mounted read-only on top of the SIF, so every trial starts from an image that
already has everything installed and nothing is installed again.

The overlay is created with `--sparse`, so where the filesystem supports it the
file only takes up as much disk as is actually written to it. Not every one
does: on ZIH, sparse files work on `/data/horse` and on node-local disk, but
`/data/cat` allocates the full nominal size regardless. Keep
`HARBOR_DEFERRED_OVERLAY_MB` (default 2048) in mind on such a filesystem — it is
a per-image cost there, not a ceiling.

Verified on ZIH Capella: `task_10016`, which never built before, now scores
reward 1 with 19/19 of its tests passing.

## 8. SIF cache location

The cache matters: harbor builds one SIF per task image, and the trial wraps
the whole environment build in the task's `build_timeout_sec` (600 s default,
`[environment]` in `task.toml`). Building from a Dockerfile plus `apt`/`pip`
on a compute node regularly takes longer than that, so an uncached task can
fail its build before the agent ever starts. With the SIF cached, the start
takes seconds. For a proxy run over hundreds of tasks the cache is therefore
a precondition, not an optimisation.

The cache path was hard-coded to `~/.apptainer/harbor_cache`, so the only way
to put it on cluster storage was to make that path a symlink. A symlink is one
fixed target for every job, and on ZIH the right target differs per job:
`/data/cat` exists only on Capella, `/data/horse` is what the other clusters
see, and neither is guaranteed on a given node (horse was mounted on one
Capella node and missing on another). A symlink into a filesystem the node
does not have makes harbor die on its own cache directory, and rewriting the
symlink per job races when several jobs run at once.

Fix: the cache path is read from `HARBOR_SIF_CACHE` (falling back to the old
default). It becomes a per-job setting instead of a per-machine one, so each
run points at a directory its node can reach.
