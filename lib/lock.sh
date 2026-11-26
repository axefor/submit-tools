# Locks of calc dirs, shared by array_worker.sh and submit-array; sourced.
#
# A lock is a directory .running in the calc dir. mkdir succeeds for only one
# job, so only one job runs a calc dir at a time. The lock holds the owner's
# Slurm job ID (or "local"), host and PID; a lock whose owner no longer runs
# is stale and gets replaced.

LOCK_NAME=.running

# Succeeds if calc dir $1 is locked by a job that may still be running.
lock_held() {
    local lock=$1/$LOCK_NAME job host pid out
    [[ -d $lock ]] || return 1
    if ! { read -r job && read -r host && read -r pid; } 2>/dev/null < "$lock/owner"; then
        # The owner is written right after mkdir; without it a minute later
        # the job died in between.
        [[ -z $(find "$lock" -maxdepth 0 -mmin +1) ]]
        return
    fi
    if [[ $job != local ]]; then
        command -v squeue >/dev/null || return 0
        if out=$(squeue -h -j "$job" -o %i 2>&1); then
            [[ -n $out ]]
        else
            # Only a job unknown to Slurm is gone; other squeue errors are
            # not proof of that.
            [[ $out != *"Invalid job id"* ]]
        fi
        return
    fi
    [[ $host == "$(hostname)" ]] || return 0
    kill -0 "$pid" 2>/dev/null
}

# Takes the lock of calc dir $1, replacing a stale one; fails if it is held.
lock_take() {
    local lock=$1/$LOCK_NAME
    if ! mkdir "$lock" 2>/dev/null; then
        lock_held "$1" && return 1
        mv "$lock" "$lock.stale.$$" 2>/dev/null && rm -rf "$lock.stale.$$"
        mkdir "$lock" 2>/dev/null || return 1
    fi
    printf '%s\n' "${SLURM_JOB_ID:-local}" "$(hostname)" "$$" > "$lock/owner"
}

lock_release() { rm -rf "${1:?}/$LOCK_NAME"; }
