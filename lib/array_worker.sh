#!/usr/bin/env bash
# =============================================================================
# array_worker.sh TASK_DIR
#
# Runs the calculations of one task directory serially until it is converged,
# no calculations are left, MAX_RUNS is reached or the walltime runs out.
# Normally started by submit-array; all settings come from the environment
# (see README.md). Hooks run through `bash -c` with TASK_DIR exported:
#
#   RUN_CMD        in each calc dir (CALC_DIR exported)        required
#   DONE_CMD       in each calc dir, exit 0 = finished          required
#   CONVERGED_CMD  in TASK_DIR, exit 0 = converged, stop        optional
#   NEXT_CMD       in TASK_DIR, writes new calc dirs            optional
#
# The last line of output is "STATUS: <status>" with status one of converged,
# exhausted, max-runs, walltime, failed.
# =============================================================================

set -uo pipefail

: "${RUN_CMD:?RUN_CMD is not set}"
: "${DONE_CMD:?DONE_CMD is not set}"
CALC_MARKER=${CALC_MARKER:-INCAR}
CONVERGED_CMD=${CONVERGED_CMD:-}
NEXT_CMD=${NEXT_CMD:-}
MAX_RUNS=${MAX_RUNS:-0}
MAX_FAILS=${MAX_FAILS:-3}
WALLTIME=${WALLTIME:-}

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

finish() {
    log "$2"
    echo "STATUS: $1"
    [[ $1 == failed ]] && exit 1
    exit 0
}

# Seconds as integer from [D-]HH:MM:SS, MM:SS or SS; fails on UNLIMITED etc.
to_seconds() {
    awk -v t="$1" 'BEGIN {
        d = 0
        if (index(t, "-")) { split(t, a, "-"); d = a[1]; t = a[2] }
        if (t !~ /^[0-9]+(:[0-9]+)*$/) exit 1
        n = split(t, p, ":"); s = 0
        for (i = 1; i <= n; i++) s = s * 60 + p[i]
        print d * 86400 + s
    }'
}

job_deadline() {
    local left
    if [[ -n $WALLTIME ]]; then
        left=$WALLTIME
    elif [[ -n ${SLURM_JOB_ID:-} ]] && command -v squeue >/dev/null; then
        left=$(squeue -h -j "$SLURM_JOB_ID" -o %L 2>/dev/null) || return 1
    else
        return 1
    fi
    left=$(to_seconds "$left") || return 1
    echo $(( $(date +%s) + left ))
}

# Calc dirs under TASK_DIR (relative), ordered by step, then seed, then path.
list_calc_dirs() {
    find . -name "$CALC_MARKER" -not -path '*/.*/*' -exec dirname {} \; |
    awk '{
        s = 0; t = 0
        if (match($0, /seed[_-]?[0-9]+/))   { s = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", s) }
        if (match($0, /steps?[_-]?[0-9]+/)) { t = substr($0, RSTART, RLENGTH); gsub(/[^0-9]/, "", t) }
        print t + 0, s + 0, $0
    }' |
    sort -k1,1n -k2,2n -k3 |
    cut -d' ' -f3-
}

is_done() { (cd "$1" && CALC_DIR=$PWD bash -c "$DONE_CMD") >/dev/null 2>&1; }

# Sets n_done and pending (first unfinished calc dir not failed in this job).
scan() {
    local dir
    n_done=0
    pending=
    while IFS= read -r dir; do
        if is_done "$dir"; then
            n_done=$(( n_done + 1 ))
        elif [[ -z $pending && $failed != *$'\n'"$dir"$'\n'* ]]; then
            pending=$dir
        fi
    done < <(list_calc_dirs)
}

[[ $# -eq 1 && -d $1 ]] || { echo "usage: ${0##*/} TASK_DIR" >&2; exit 2; }
cd "$1" || exit 1
export TASK_DIR=$PWD

log "Task: $TASK_DIR (host $(hostname))"
deadline=$(job_deadline) || deadline=
[[ -n $deadline ]] || log "Walltime unknown, runs are started regardless of time left."

failed=$'\n'
n_runs=0
n_fails=0
longest=0
last_checked=-1
generated=0

while :; do
    scan

    if [[ -n $CONVERGED_CMD && $n_done -ne $last_checked ]]; then
        log "Checking convergence with $n_done finished calculation(s)."
        if bash -c "$CONVERGED_CMD"; then
            finish converged "Converged with $n_done finished calculation(s)."
        fi
        last_checked=$n_done
    fi

    if [[ -z $pending ]]; then
        if [[ -n $NEXT_CMD && $generated -eq 0 ]]; then
            log "No pending calculations, writing the next ones."
            bash -c "$NEXT_CMD" || finish failed "NEXT_CMD failed."
            generated=1
            continue
        fi
        finish exhausted "No calculations left to run ($n_done finished)."
    fi
    generated=0

    if (( MAX_RUNS > 0 && n_runs >= MAX_RUNS )); then
        finish max-runs "Started $n_runs run(s), the MAX_RUNS limit."
    fi
    if [[ -n $deadline ]]; then
        left=$(( deadline - $(date +%s) ))
        if (( left < longest + longest / 5 )); then
            finish walltime "${left}s left, longest run took ${longest}s; not starting $pending."
        fi
    fi

    log "Running $pending ($n_done finished so far)."
    start=$(date +%s)
    (cd "$pending" && CALC_DIR=$PWD bash -c "$RUN_CMD")
    rc=$?
    took=$(( $(date +%s) - start ))
    (( took > longest )) && longest=$took
    n_runs=$(( n_runs + 1 ))

    if is_done "$pending"; then
        log "Finished $pending in ${took}s."
        n_fails=0
    else
        log "FAILED $pending after ${took}s (exit code $rc)."
        failed+="$pending"$'\n'
        n_fails=$(( n_fails + 1 ))
        (( n_fails >= MAX_FAILS )) && finish failed "$n_fails consecutive failures."
    fi
done
