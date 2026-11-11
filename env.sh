# Environment of submit-tools, sourced from the shell rc file with
# SUBMIT_TOOLS_HOME set (see install.sh). Works in bash, zsh and sh.

case ":$PATH:" in
    *":$SUBMIT_TOOLS_HOME/bin:"*) ;;
    *) PATH=$SUBMIT_TOOLS_HOME/bin:$SUBMIT_TOOLS_HOME/vasp:$PATH ;;
esac
export PATH SUBMIT_TOOLS_HOME
