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

One task, `task_10016`. Its Dockerfile is:

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

Fix: move the privileged work out of build time, where no root is available,
into run time. A third build strategy in `_build_from_dockerfile`, tried only
after both existing attempts fail, imports the base image with
`apptainer build … docker://<base>` (no `%post`, no fakeroot) and records the
skipped Dockerfile steps in a `<sif>.deferred.json` sidecar.

Replaying those steps at every instance start does NOT work, so the `RUN` steps
are instead baked ONCE into a persistent overlay image beside the SIF, executed
under `unshare -r`: that maps our uid to 0, which is real root inside the
namespace, so dpkg is happy — unlike apptainer's fakeroot helper, which cannot
even exec against these images. apt needs two nudges there, because a
single-uid namespace has no `_apt` user: keep it running as root and point its
cache directories somewhere fresh. The bake also happens on a later cache hit,
so a cached SIF never starts without its setup, and a failing step raises like
any other environment error — reward `None` and a named error, not a silent
reward 0 that is indistinguishable from a weak agent.

Two consequences at trial time. Such an image starts WITHOUT `--fakeroot`: with
it, the instance does not start at all ("exec /.singularity.d/libs/fakeroot
failed"), so the trial runs as the invoking user. And the `COPY` payload is
bind-mounted from a per-instance copy instead of being baked into the overlay,
because overlay copy-up of root-owned content needs CAP_CHOWN and fails the
moment a task writes next to its own files.

Verified on ZIH Capella: `task_10016`, which never built before, now scores
reward 1 with 19/19 of its tests passing.
