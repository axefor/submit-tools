#!/bin/bash
# =============================================================================
# VASP two-step calculation script, run in the calculation directory
#   Step 1 (prerun): default ENCUT, lower EDIFF, PREC=Normal,
#                    ADDGRID=.FALSE., LREAL=A, runs in $SCRATCH
#   Step 2 (main):   original INCAR settings restored, seeded by prerun WAVECAR
#
# Both steps run in the same scratch directory to avoid quota issues, so the
# WAVECAR never leaves scratch. Only small output files are copied back. The
# scratch directory is deleted when the script exits (whether successful or not).
#
# The VASP module is expected to be loaded already (SETUP in the settings).
# VASP_CMD overrides the default "srun vasp_std", VASP_SCRATCH the scratch
# location (default $TMPDIR, else /tmp).
# =============================================================================

set -euo pipefail

# Threads > 1 make VASP force NCORE = 1
export OMP_NUM_THREADS=1

VASP_CMD="${VASP_CMD:-srun vasp_std}"
INCAR="INCAR"
SCRATCH="${VASP_SCRATCH:-${TMPDIR:-/tmp}}"

WORK_DIR="$(pwd)"
PRERUN_DIR="${SCRATCH}/vasp_prerun_${SLURM_JOB_ID:-local}_$$"

# ---------- cleanup trap: always delete the scratch directory ---------------
cleanup() {
    echo "  Cleaning up: removing scratch directory..."
    rm -rf "$PRERUN_DIR"
}
trap cleanup EXIT

# ---------- helper: set/add a tag in an INCAR file --------------------------
set_tag() {
    local file="$1"
    local tag="$2"
    local value="$3"
    if grep -qiE "^\s*${tag}\s*=" "$file"; then
        sed -i -E "s|^\s*${tag}\s*=.*|${tag} = ${value}|i" "$file"
    else
        echo "${tag} = ${value}" >> "$file"
    fi
}

# ---------- helper: remove a tag from an INCAR file -------------------------
remove_tag() {
    local file="$1"
    local tag="$2"
    sed -i -E "/^\s*${tag}\s*=/Id" "$file"
}

# =============================================================================
# Sanity checks
# =============================================================================
for f in INCAR POSCAR POTCAR KPOINTS; do
    [[ -f "$f" ]] || { echo "ERROR: $f not found in ${WORK_DIR}"; exit 1; }
done

echo "  Prerun scratch directory: ${PRERUN_DIR}"

# =============================================================================
# STEP 1: PRERUN (on scratch)
# =============================================================================
echo "=== PRERUN ==="

mkdir -p "$PRERUN_DIR"

# Build prerun INCAR
cp "$INCAR" "${PRERUN_DIR}/INCAR"

# 1a. Remove ENCUT so VASP falls back to its default (max ENMAX from POTCAR)
remove_tag "${PRERUN_DIR}/INCAR" "ENCUT"

# 1b. Lower EDIFF
set_tag "${PRERUN_DIR}/INCAR" "EDIFF" "1E-3"

# 1c. PREC = Normal
set_tag "${PRERUN_DIR}/INCAR" "PREC" "Normal"

# 1d. ADDGRID = .FALSE.
set_tag "${PRERUN_DIR}/INCAR" "ADDGRID" ".FALSE."

# 1e. LREAL = A
set_tag "${PRERUN_DIR}/INCAR" "LREAL" "A"

# 1f. LWAVE = .TRUE. so WAVECAR is written for the main run
set_tag "${PRERUN_DIR}/INCAR" "LWAVE" ".TRUE."

for f in POSCAR POTCAR KPOINTS; do
    cp "${WORK_DIR}/$f" "${PRERUN_DIR}/$f"
done

# Run VASP in prerun scratch directory
echo "  Running $VASP_CMD in ${PRERUN_DIR} ..."
cd "$PRERUN_DIR"
$VASP_CMD || { echo "ERROR: prerun $VASP_CMD failed."; exit 1; }
cd "$WORK_DIR"

echo "  Prerun complete."

# =============================================================================
# STEP 2: MAIN CALCULATION
# =============================================================================
echo "=== MAIN CALCULATION ==="

if [[ ! -f "${PRERUN_DIR}/WAVECAR" ]]; then
    echo "ERROR: WAVECAR not found in ${PRERUN_DIR} — prerun may not have written it."
    exit 1
fi

# Otherwise a crashed main run would copy back the prerun outputs
rm -f "${PRERUN_DIR}"/{OUTCAR,OSZICAR,CONTCAR,vasprun.xml,vaspout.h5}

# Main INCAR goes into scratch, so the original INCAR is left untouched
cp "$INCAR" "${PRERUN_DIR}/INCAR"
set_tag "${PRERUN_DIR}/INCAR" "ISTART" "1"

echo "  Running $VASP_CMD in ${PRERUN_DIR} ..."
cd "$PRERUN_DIR"
main_status=0
$VASP_CMD || main_status=$?

# Copy results back even on failure, for diagnosis
for f in OUTCAR OSZICAR CONTCAR vasprun.xml vaspout.h5; do
    if [[ -f "$f" ]]; then cp "$f" "${WORK_DIR}/$f"; fi
done
cd "$WORK_DIR"
[[ $main_status -eq 0 ]] || { echo "ERROR: main $VASP_CMD failed."; exit 1; }

echo "=== DONE ==="
# trap fires here: PRERUN_DIR is removed

