#!/bin/bash
# =============================================================================
# vasp_time.sh  <rootdir> [rootdir2 ...]
#
# Recursively finds all OUTCARs below given root dirs and prints a summary
# table of elapsed times. Also queries sacct for the slurm job wall time
# if a slurm-*.out file is found in the same directory.
# Defaults to current directory.
# =============================================================================

if [[ $# -eq 0 ]]; then
    set -- .
fi

printf "%-55s %6s %12s %16s %12s\n" "Directory" "MPI" "OUTCAR (s)" "OUTCAR (h:mm:ss)" "Slurm wall"
printf "%-55s %6s %12s %16s %12s\n" "---------" "---" "----------" "----------------" "----------"

for root in "$@"; do
    if [[ ! -d "$root" ]]; then
        echo "WARNING: $root is not a directory, skipping."
        continue
    fi

    find "$root" -name "OUTCAR" | sort | while IFS= read -r outcar; do
        dir="$(dirname "$outcar")"

        # --- Number of MPI ranks ---
        # Matches: "running  128 mpi-ranks, with    2 threads/rank, on    1 nodes"
        cores_line=$(grep -m1 "mpi-ranks" "$outcar")
        if [[ -n "$cores_line" ]]; then
            mpi=$(echo "$cores_line" | awk '{print $2}')
        else
            mpi="(?)"
        fi

        # --- OUTCAR elapsed time ---
        elapsed=$(grep "Elapsed time" "$outcar" | awk '{print $NF}')
        if [[ -z "$elapsed" ]]; then
            outcar_s="(unfinished)"
            outcar_hms=""
        else
            total=${elapsed%.*}
            hours=$(( total / 3600 ))
            minutes=$(( (total % 3600) / 60 ))
            seconds=$(( total % 60 ))
            outcar_s="$elapsed"
            outcar_hms="$(printf "%dh %02dm %02ds" "$hours" "$minutes" "$seconds")"
            # Accumulate: total_seconds, count, core_seconds
            cur_total=0; cur_count=0; cur_core_seconds=0
            [[ -f /tmp/vasp_time_total.tmp ]] && read cur_total cur_count cur_core_seconds < /tmp/vasp_time_total.tmp
            if [[ "$mpi" != "(?)" ]]; then
                job_core_seconds=$(( total * mpi ))
            else
                job_core_seconds=0
            fi
            echo "$(( cur_total + total )) $(( cur_count + 1 )) $(( cur_core_seconds + job_core_seconds ))" > /tmp/vasp_time_total.tmp
        fi

        # --- Slurm wall time via sacct ---
        slurm_file=$(ls "$dir"/slurm-*.out 2>/dev/null | head -1)
        if [[ -n "$slurm_file" ]]; then
            job_id=$(basename "$slurm_file" | sed 's/slurm-\(.*\)\.out/\1/')
            slurm_wall=$(sacct -j "$job_id" --format=Elapsed --noheader 2>/dev/null | head -1 | tr -d ' ')
            [[ -z "$slurm_wall" ]] && slurm_wall="(unavailable)"
        else
            slurm_wall="(no slurm file)"
        fi

        # Truncate dir if too long
        if [[ ${#dir} -gt 55 ]]; then
            dir="${dir:0:52}..."
        fi
        printf "%-55s %6s %12s %16s %12s\n" "$dir" "$mpi" "$outcar_s" "$outcar_hms" "$slurm_wall"
    done
done

# --- Print sum, avg, and core-hours rows ---
if [[ -f /tmp/vasp_time_total.tmp ]]; then
    read total_seconds count total_core_seconds < /tmp/vasp_time_total.tmp
    rm -f /tmp/vasp_time_total.tmp

    avg_seconds=$(( total_seconds / count ))
    total_core_hours=$(( total_core_seconds / 3600 ))

    fmt_hms() {
        local s=$1
        printf "%dh %02dm %02ds" $(( s / 3600 )) $(( (s % 3600) / 60 )) $(( s % 60 ))
    }

    printf "%-55s %6s %12s %16s %12s\n" "---------" "---" "----------" "----------------" "----------"
    printf "%-55s %6s %12s %16s\n"       "TOTAL ($count jobs)" "" "$total_seconds" "$(fmt_hms $total_seconds)"
    printf "%-55s %6s %12s %16s\n"       "AVERAGE" "" "$avg_seconds" "$(fmt_hms $avg_seconds)"
    printf "%-55s %6s %12s\n"            "TOTAL CORE-HOURS" "" "$total_core_hours"
fi
