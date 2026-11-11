# Job submission scripts

Two commands share one set of cluster and project settings:

- `submit` submits a single job running a command.
- `submit-array` submits a job array with one task per directory. Each task
  runs the calculations in its directory one after another until they
  converge, optionally writing new calculation folders as it goes.

Slurm is the default backend. `-b local` runs the job right here instead,
which is useful for testing.

```
bin/submit, bin/submit-array   the commands
lib/common.sh                  settings, profiles, backends
lib/array_worker.sh            the per-directory loop of submit-array
vasp/vasp_prerun.sh            VASP prerun + main run in scratch
vasp/vasp_time.sh              table of VASP and Slurm run times
examples/                      cluster.conf, submit.conf
env.sh, install.sh             shell setup
```

## Setup on a cluster

```bash
git clone <repo> ~/software/submit-tools
~/software/submit-tools/install.sh          # adds bin/ and vasp/ to PATH via your rc file
mkdir -p ~/.config/submit-tools
cp ~/software/submit-tools/examples/cluster.conf ~/.config/submit-tools/cluster.conf   # then edit
```

`install.sh` adds a marked block to `~/.bashrc` or `~/.zshrc` (or the file
given with `--rc`). The block sets `SUBMIT_TOOLS_HOME` and sources `env.sh`.
Run the installer again after moving the repo; `--uninstall` removes the block.

## Settings

Settings files are bash, sourced at submission time, in this order (later
ones win):

1. **Cluster settings**: `~/.config/submit-tools/cluster.conf` (respects
   `$XDG_CONFIG_HOME`), or the file in `$SUBMIT_CLUSTER_CONF`. These hold the
   account, the module setup and the profiles. Each cluster has its own home
   directory, so each cluster gets its own file automatically.
2. **Project settings**: every `submit.conf` from the outermost parent folder
   down to the current folder, so inner files override outer ones. The search
   stops below `$HOME`, which matters for projects inside your home folder.
   For example, `project/submit.conf` can hold the walltime for the whole
   project and `project/step1/submit.conf` the hooks for that step. Giving
   `-c FILE` (repeatable) reads only those files instead.
3. **Command-line options**.

While a file is being read, `CONF_DIR` is its folder. Use it for files next
to the settings, such as `RUN_CMD="bash $CONF_DIR/run.sh"`. That works no
matter which subfolder you submit from, while `SUBMIT_DIR` is the folder you
submitted from.

| Variable          | Meaning                                                              |
|-------------------|----------------------------------------------------------------------|
| `SCHED_ARGS`      | Bash array of scheduler arguments. Append with `SCHED_ARGS+=(...)`.  |
| `SETUP`           | Shell code run in the job before the command (`ml ...`, `export ...`). Append with `SETUP+=`. |
| `profile_NAME()`  | Function picked with `-P NAME`. It appends resource arguments to `SCHED_ARGS`. |
| `DEFAULT_PROFILE` | Profile used without `-P`.                                           |
| `JOB_NAME`        | Defaults to the name of the current directory.                       |
| `LOG_DIR`         | Defaults to `logs`.                                                  |

Scheduler arguments go to `sbatch` in this order: profile, `SCHED_ARGS`,
`-t`, `-x`. When an option appears more than once, sbatch uses the last one,
so `SCHED_ARGS+=(-t 24:00:00)` in a project overrides the cluster default,
and `-t 1:00:00` on the command line overrides both.

Every submission creates `LOG_DIR/JOB_NAME_TIMESTAMP/`. It holds the job
script, copies of the settings files used (listed in order in `configs`),
`jobid`, and the logs (`job.out`, or one
`<index>.out` per array task). Queued jobs only read from this folder, so you
can edit the settings after submitting.

## submit

```bash
submit -P shared -t 1:00:00 srun python sampling.py
submit 'srun vasp_std > vasp.log'          # one argument = shell code
submit -n vasp_prerun.sh                   # dry run: print the job script
```

## submit-array

```bash
submit-array joblist                       # file with one directory per line
submit-array runs/*/                       # or the directories themselves
submit-array -p 20 -t 4:00:00 joblist      # at most 20 tasks running at once
```

The per-directory loop, `lib/array_worker.sh`, repeats these steps:

1. If `CONVERGED_CMD` succeeds, stop. It only runs again after more
   calculations have finished.
2. Pick the first unfinished calc dir: a dir containing `CALC_MARKER` for which
   `DONE_CMD` fails. Dirs are ordered by step, then seed.
3. If there is none, run `NEXT_CMD` once to write new calc dirs. If it writes
   nothing, stop.
4. If the walltime left is less than 1.2× the longest run so far, stop.
5. Run `RUN_CMD` in that dir. After `MAX_FAILS` consecutive failures, stop.

Resubmitting the same task list is safe. Finished dirs are skipped, and a dir
that was cut off by the walltime is run again. The last line of each task log
is `STATUS: converged|exhausted|max-runs|walltime|failed`, for example:
`grep -h STATUS logs/*/[0-9]*.out | sort | uniq -c`.

| Variable        | Runs in  | Meaning                                                       |
|-----------------|----------|---------------------------------------------------------------|
| `RUN_CMD`       | calc dir | Runs one calculation. **Required.**                           |
| `DONE_CMD`      | calc dir | Exit 0 = the calculation is finished. **Required.**           |
| `CALC_MARKER`   |          | File that marks a calc dir (default `INCAR`).                 |
| `CONVERGED_CMD` | task dir | Exit 0 = converged, stop.                                     |
| `NEXT_CMD`      | task dir | Writes the next calc dir(s).                                  |
| `MAX_RUNS`      |          | Maximum runs started per task (default 0 = no limit).         |
| `MAX_FAILS`     |          | Consecutive failures before giving up (default 3).            |
| `WALLTIME`      |          | Time limit when `squeue` is not available, `[D-]HH:MM:SS`.    |

Hooks run through `bash -c` with `TASK_DIR`, `SUBMIT_DIR` and (for
`RUN_CMD`/`DONE_CMD`) `CALC_DIR` exported. Because the settings are sourced at
submission, use double quotes for things that should expand then, such as
`"$CONF_DIR/run.sh"`. Use single quotes for things that should expand when
the hook runs, such as `'$(basename "$PWD")'`. `examples/submit.conf` is a
complete VASP setup.

Scripts that hooks call, such as `vasp_prerun.sh`, are not copied into the
submission folder. Bash reads a script while it runs, so editing one while
jobs use it can break running calculations.

## Other schedulers

A backend is a function `submit_<name> NTASKS` in `lib/common.sh` (see
`submit_slurm`, `submit_local`); `NTASKS` is 0 for a single job. The array
job script reads its index from `ARRAY_TASK_ID`, `SLURM_ARRAY_TASK_ID`,
`PBS_ARRAY_INDEX`, `SGE_TASK_ID` or `LSB_JOBINDEX`. The walltime guard asks
`squeue`, and falls back to `WALLTIME` on other schedulers.
