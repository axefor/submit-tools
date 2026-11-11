# Shared code of bin/submit and bin/submit-array; sourced, not run.
#
# Settings are read in this order, later ones winning:
#   1. cluster settings, $SUBMIT_CLUSTER_CONF or
#      ${XDG_CONFIG_HOME:-~/.config}/submit-tools/cluster.conf
#   2. project settings: the -c files, or else every submit.conf from the
#      outermost parent folder (stopping below $HOME) down to the current one
#   3. command-line options
# CONF_DIR is the folder of the settings file being read.
# Scheduler arguments are ordered profile, SCHED_ARGS, -t, -x, so for repeated
# sbatch options the project and command line win over the profile.

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CLUSTER_CONF=${SUBMIT_CLUSTER_CONF:-${XDG_CONFIG_HOME:-$HOME/.config}/submit-tools/cluster.conf}

CONFIGS=()
PROFILE=
BACKEND=slurm
JOB_NAME_OPT=
TIME=
PARALLEL=
DRY_RUN=0
CLI_SCHED_ARGS=()

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    awk 'NR > 2 && /^# =+$/ { exit } NR > 2 { sub(/^# ?/, ""); print }' "$0"
    exit "${1:-0}"
}

# Handles one option shared by all commands; sets NSHIFT, returns 1 if unknown.
common_opt() {
    NSHIFT=2
    case $1 in
        -c|--config)   CONFIGS+=("${2-}") ;;
        -P|--profile)  PROFILE=${2-} ;;
        -t|--time)     TIME=${2-} ;;
        -J|--job-name) JOB_NAME_OPT=${2-} ;;
        -x|--sched)    CLI_SCHED_ARGS+=("${2-}") ;;
        -b|--backend)  BACKEND=${2-} ;;
        -n|--dry-run)  DRY_RUN=1; NSHIFT=1 ;;
        -h|--help)     usage ;;
        *)             return 1 ;;
    esac
    (( NSHIFT == 1 || $# >= 2 )) || die "$1 needs a value."
}

# Sets CONFIGS to the submit.conf files from the outermost folder inwards.
find_configs() {
    local dir=$PWD
    while [[ $dir != "$HOME" ]]; do
        if [[ -f $dir/submit.conf ]]; then
            CONFIGS=("$dir/submit.conf" ${CONFIGS[@]+"${CONFIGS[@]}"})
        fi
        [[ $dir == / ]] && break
        dir=$(dirname "$dir")
    done
}

source_conf() {
    [[ -f $1 ]] || die "$1 not found."
    CONF_DIR=$(cd "$(dirname "$1")" && pwd)
    # shellcheck disable=SC1090
    source "$1"
}

list_profiles() {
    declare -F | awk '$3 ~ /^profile_/ { sub(/^profile_/, "", $3); printf " %s", $3 }'
}

load_settings() {
    export SUBMIT_DIR=$PWD
    JOB_NAME=${PWD##*/}
    LOG_DIR=logs
    SCHED_ARGS=()
    SETUP=
    DEFAULT_PROFILE=

    if [[ -f $CLUSTER_CONF ]]; then
        source_conf "$CLUSTER_CONF"
    fi
    if (( ${#CONFIGS[@]} == 0 )); then
        find_configs
    fi
    local i
    for (( i = 0; i < ${#CONFIGS[@]}; i++ )); do
        source_conf "${CONFIGS[i]}"
        CONFIGS[i]=$CONF_DIR/${CONFIGS[i]##*/}
    done

    local base=(${SCHED_ARGS[@]+"${SCHED_ARGS[@]}"})
    SCHED_ARGS=()
    PROFILE=${PROFILE:-$DEFAULT_PROFILE}
    if [[ -n $PROFILE ]]; then
        declare -F "profile_$PROFILE" >/dev/null ||
            die "unknown profile '$PROFILE' (defined:$(list_profiles))."
        "profile_$PROFILE"
    fi
    SCHED_ARGS+=(${base[@]+"${base[@]}"})
    if [[ -n $TIME ]]; then
        SCHED_ARGS+=(-t "$TIME")
    fi
    SCHED_ARGS+=(${CLI_SCHED_ARGS[@]+"${CLI_SCHED_ARGS[@]}"})
    if [[ -n $JOB_NAME_OPT ]]; then
        JOB_NAME=$JOB_NAME_OPT
    fi
    declare -F "submit_$BACKEND" >/dev/null || die "unknown backend '$BACKEND'."
}

# Creates RUN_DIR, the folder holding everything of one submission.
new_run_dir() {
    local base stamp
    base=$(mkdir -p "$LOG_DIR" && cd "$LOG_DIR" && pwd) || die "cannot create $LOG_DIR."
    stamp=$(date +%Y%m%d-%H%M%S)
    RUN_DIR=$base/${JOB_NAME}_$stamp
    local i=1
    while ! mkdir "$RUN_DIR" 2>/dev/null; do
        i=$(( i + 1 ))
        RUN_DIR=$base/${JOB_NAME}_${stamp}_$i
    done
    if [[ -f $CLUSTER_CONF ]]; then
        cp "$CLUSTER_CONF" "$RUN_DIR/cluster.conf"
    fi
    for (( i = 0; i < ${#CONFIGS[@]}; i++ )); do
        cp "${CONFIGS[i]}" "$RUN_DIR/config.$(( i + 1 ))"
    done
    describe_configs > "$RUN_DIR/configs"
}

# Lists the settings files used, in the order read.
describe_configs() {
    if [[ -f $CLUSTER_CONF ]]; then
        echo "$CLUSTER_CONF"
    fi
    if (( ${#CONFIGS[@]} )); then
        printf '%s\n' "${CONFIGS[@]}"
    fi
}

# Writes the named variables that are set to RUN_DIR/settings as exports.
write_settings() {
    local v
    for v in SUBMIT_DIR "$@"; do
        if [[ -n ${!v:-} ]]; then
            printf 'export %s=%q\n' "$v" "${!v}"
        fi
    done > "$RUN_DIR/settings"
}

# Writes RUN_DIR/job.sh: settings, SETUP, then the shell code in $1.
write_job() {
    {
        echo '#!/bin/bash'
        printf 'source %q\n' "$RUN_DIR/settings"
        printf 'cd %q\n' "$SUBMIT_DIR"
        printf '%s\n' "$SETUP" "$1"
    } > "$RUN_DIR/job.sh"
}

# Submits RUN_DIR/job.sh as an array of $1 tasks, or a single job if $1 is 0.
submit_job() {
    if (( DRY_RUN )); then
        echo "--- job.sh ---"
        cat "$RUN_DIR/job.sh"
        echo "--- settings ---"
        cat "$RUN_DIR/settings"
        echo "--- submit ---"
    fi
    "submit_$BACKEND" "$1"
}

# ---------- backends: submit_<name> NTASKS ------------------------------------

submit_slurm() {
    local cmd=(sbatch --parsable -J "$JOB_NAME")
    if (( $1 )); then
        local spec="1-$1"
        [[ -n $PARALLEL ]] && spec+="%$PARALLEL"
        cmd+=(--array="$spec" -o "$RUN_DIR/%a.out")
    else
        cmd+=(-o "$RUN_DIR/job.out")
    fi
    cmd+=(${SCHED_ARGS[@]+"${SCHED_ARGS[@]}"} "$RUN_DIR/job.sh")
    if (( DRY_RUN )); then
        printf '%q ' "${cmd[@]}"
        echo
        return
    fi
    local jobid
    jobid=$("${cmd[@]}") || die "sbatch failed."
    echo "$jobid" > "$RUN_DIR/jobid"
    echo "Submitted job $jobid; logs in $RUN_DIR"
}

# Runs here and now, one task after another; scheduler arguments are ignored.
submit_local() {
    local i out
    if (( DRY_RUN )); then
        echo "would run $RUN_DIR/job.sh here ($1 array tasks, 0 = single job)"
        return
    fi
    if (( $1 == 0 )); then
        echo "Running locally (log: $RUN_DIR/job.out)"
        bash "$RUN_DIR/job.sh" > "$RUN_DIR/job.out" 2>&1 || echo "  job failed"
        return
    fi
    for (( i = 1; i <= $1; i++ )); do
        out=$RUN_DIR/$i.out
        echo "Running task $i/$1 (log: $out)"
        ARRAY_TASK_ID=$i bash "$RUN_DIR/job.sh" > "$out" 2>&1 || echo "  task $i failed"
        tail -n 1 "$out"
    done
}
