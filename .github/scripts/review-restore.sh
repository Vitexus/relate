# review-restore.sh — the one restore-and-harden choreography every
# step runs after the shell-capable model step (ADR-0603): the scripted
# stellar post, the per-kind posts and the Enforce verdict gate all
# re-enter the workspace through this script. Sourced, never executed —
# the PATH pin must reach the calling step's own commands (python3, gh,
# jq, the poster scripts), and a child process cannot export it back.
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
#   - Hooks are neutralized before any git command runs: a
#     model-written post-checkout hook would fire on the restore
#     itself (core.hooksPath unset in the repository, pointed at
#     /dev/null in the global config).
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
# --no-clean skips the untracked-file sweep alone (PATH pin, hooks and
# reset still run): the Enforce verdict gate takes the choreography
# that way because its verdict file is untracked and must survive.
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
git config --unset core.hooksPath 2>/dev/null || true
git config --global core.hooksPath /dev/null
: "${RESTORE_SHA:?review-restore.sh: RESTORE_SHA required — the trusted reset target from the event payload (local HEAD is model-moveable)}"
git reset --hard "$RESTORE_SHA"
if [ "$NO_CLEAN" -ne 1 ]; then
  git clean -fdx -- . ':(exclude).stellar'
fi

for f in "$@"; do
  if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; } || git ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
    echo "post: rejecting non-model output $f (symlink or tracked at HEAD) — deleting"
    rm -f "$f"
  fi
done

: "${RUNNER_TEMP:?review-restore.sh: RUNNER_TEMP is required (the run step timeout marker lives there)}"
TIMED_OUT=0
if [ -f "$RUNNER_TEMP/review_timed_out" ]; then
  TIMED_OUT=$(cat "$RUNNER_TEMP/review_timed_out")
fi
