# review-restore.sh — the one restore-and-harden choreography every
# step runs after the shell-capable model step (ADR-0603): the scripted
# stellar post, the per-kind posts and the Enforce verdict gate all
# re-enter the workspace through this script. Sourced, never executed —
# the PATH and git-config pins must reach the calling step's own
# commands (python3, gh, jq, the poster scripts, its git calls), and a
# child process cannot export them back.
#
#   . .github/scripts/review-restore.sh [--no-clean] <findings-file>...
#   env: RESTORE_SHA — the event-payload SHA the reset targets
#        (required; the caller passes the merge SHA github.sha)
#
# Always source it with an explicit argument list: a bare `.` source
# inherits the caller's positional parameters.
#
# Source it from trusted content, never the worktree copy: the calling
# step stages the committed PR-head copy — git show of the head SHA the
# event payload carries — into a fresh mktemp file and sources that,
# because the model step could have rewritten any worktree file, this
# one included, before a token-bearing step runs.
#
# The model step runs with shell access, so nothing it left behind is
# trusted:
#   - PATH is pinned to the system directories: the model step could
#     have poisoned later steps' PATH through $GITHUB_PATH.
#   - Git configuration is neutralized at every source the model shell
#     can write: the global (shared HOME) and system gitconfigs are
#     pinned to /dev/null and the env-numbered config channel is
#     zeroed (the GIT_CONFIG_* exports below), while every git
#     invocation the choreography itself performs pins the repository
#     config's code-execution knobs off with -c core.fsmonitor=
#     -c core.pager=cat — a model-written .git/config (or
#     worktree-scoped config) cannot steer code execution through
#     fsmonitor or a pager.
#   - Hooks are neutralized before any git command runs:
#     core.hooksPath is unset in the repository, and the global-config
#     pin above keeps a model-written global hooksPath from ever
#     applying to a git command in the step.
#   - Tracked files are reset to RESTORE_SHA, the event-payload SHA of
#     the commit the checkout started from — reset --hard, not
#     checkout --: the model can stage files, and checkout restores
#     from the INDEX; and never local HEAD: the model can commit and
#     move it, so only the event payload's SHA is trusted.
#   - Untracked shadow files outside .stellar are removed, ignored ones
#     included (-x: a gitignored droplet must not survive either, and a
#     planted .opencode-verdict.txt must NOT survive — the poster
#     writes it). .stellar is the model-output channel and survives.
#   - Every findings file named as an argument is accepted only as a
#     REGULAR, UNTRACKED file: a symlink (pointing anywhere, runner
#     files included), a file tracked at HEAD, or any other
#     non-regular file (a model-created FIFO, socket or device at a
#     findings path would stall the poster's read) is deleted before
#     validation and treated as no output — a PR force-adding
#     .stellar/findings.json would survive the reset and pose as model
#     output, steering the poster onto the pass-capable branch
#     (OPLANE_REQ-00333782). The model cannot place a tracked file
#     here: its commits never reach this checkout's HEAD.
#   - The timeout fact is read from the run step's marker file in
#     $RUNNER_TEMP — written after the model process exited, never an
#     env var the model could have forged into $GITHUB_ENV
#     (OPLANE_REQ-00333784) — and left in TIMED_OUT for the caller: 1
#     when the run timed out, 0 when it did not. A missing marker
#     means the run step never reached its wrapper write: no timeout
#     salvage, the generic fail path decides.
#
# --no-clean skips the untracked-file sweep alone (PATH and git-config
# pins, hooks and reset still run): the Enforce verdict gate takes the
# choreography that way because its verdict file is untracked and must
# survive.
set -euo pipefail

NO_CLEAN=0
if [ "${1:-}" = "--no-clean" ]; then
  NO_CLEAN=1
  shift
fi
if [ "$NO_CLEAN" -ne 1 ] && [ "$#" -eq 0 ]; then
  echo "review-restore.sh: source it with --no-clean or the findings file list as arguments" >&2
  return 1 2>/dev/null || exit 1
fi
for arg in "$@"; do
  case "$arg" in
    --*)
      echo "review-restore.sh: unknown flag: $arg" >&2
      return 1 2>/dev/null || exit 1
      ;;
  esac
done

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Model-written git configuration is inert from the first git call in
# this step on (the round-5 finding: the model shell can write
# .git/config and the shared HOME gitconfig, and every git command the
# post steps run parses them): the global and system gitconfigs are
# pinned to /dev/null, and the env-numbered config channel —
# GIT_CONFIG_KEY_n/GIT_CONFIG_VALUE_n pairs, plantable into this
# step's environment through the runner env file under RUNNER_TEMP —
# is zeroed by GIT_CONFIG_COUNT=0. Exported like the PATH pin, and for
# the same reason: the calling step's own later git calls must run
# under them, and a child process cannot export them back. The
# workflow's step env pins the same values from process start
# (ADR-0603), covering the staging git show that runs before this
# script is sourced.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_COUNT=0
# The repository's own .git/config still parses, so the git
# invocations below pin its code-execution knobs per invocation: an
# empty core.fsmonitor disables a model-written fsmonitor hook on
# every index-refreshing command here (reset, clean, ls-files), and
# core.pager=cat can never spawn a model-written pager. core.hooksPath
# is unset outright, so the step's later git calls are covered there
# too.
git config --unset core.hooksPath 2>/dev/null || true
: "${RESTORE_SHA:?review-restore.sh: RESTORE_SHA required — the trusted reset target from the event payload (local HEAD is model-moveable)}"
git -c core.fsmonitor= -c core.pager=cat reset --hard "$RESTORE_SHA"
if [ "$NO_CLEAN" -ne 1 ]; then
  git -c core.fsmonitor= -c core.pager=cat clean -fdx -- . ':(exclude).stellar'
fi

for f in "$@"; do
  if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; } || git -c core.fsmonitor= -c core.pager=cat ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
    echo "post: rejecting non-model output $f (symlink or tracked at HEAD) — deleting"
    rm -f "$f"
  fi
done

: "${RUNNER_TEMP:?review-restore.sh: RUNNER_TEMP is required (the run step timeout marker lives there)}"
TIMED_OUT=0
if [ -f "$RUNNER_TEMP/review_timed_out" ]; then
  TIMED_OUT=$(cat "$RUNNER_TEMP/review_timed_out")
fi
