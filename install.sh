#!/usr/bin/env bash
# =============================================================================
# install.sh [--rc FILE] [--uninstall]
#
# Adds a block to the shell rc file that sources env.sh of this repo, which
# puts the commands on PATH. Running it again replaces the block, e.g. after
# moving the repo. The rc file defaults to ~/.zshrc or ~/.bashrc depending on
# $SHELL, else ~/.profile.
# =============================================================================

set -eo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
begin='# >>> submit-tools >>>'
end='# <<< submit-tools <<<'

rc=
uninstall=0
while (( $# )); do
    case $1 in
        --rc)        rc=$2; shift 2 ;;
        --uninstall) uninstall=1; shift ;;
        -h|--help)   sed -n '3,8s/^# \{0,1\}//p' "$0"; exit 0 ;;
        *)           echo "Unknown option $1" >&2; exit 2 ;;
    esac
done
if [[ -z $rc ]]; then
    case ${SHELL##*/} in
        zsh)  rc=$HOME/.zshrc ;;
        bash) rc=$HOME/.bashrc ;;
        *)    rc=$HOME/.profile ;;
    esac
fi

# Rewrites the file in place, so a symlinked rc file stays a symlink.
remove_block() {
    [[ -f $rc ]] || return 0
    local kept
    kept=$(awk -v b="$begin" -v e="$end" '$0 == b { skip = 1 } !skip { print } $0 == e { skip = 0 }' "$rc")
    printf '%s\n' "$kept" > "$rc"
}

remove_block
if (( uninstall )); then
    echo "Removed submit-tools from $rc"
    exit 0
fi

cat >> "$rc" <<EOF
$begin
export SUBMIT_TOOLS_HOME=$(printf %q "$repo")
. "\$SUBMIT_TOOLS_HOME/env.sh"
$end
EOF
echo "Added submit-tools to $rc; open a new shell or run: . $rc"

conf=${XDG_CONFIG_HOME:-$HOME/.config}/submit-tools/cluster.conf
if [[ ! -f $conf ]]; then
    echo "No cluster settings yet. Start from the example:"
    echo "  mkdir -p ${conf%/*} && cp $repo/examples/cluster.conf $conf"
fi
