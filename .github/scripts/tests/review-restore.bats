# Behavioral tests for review-restore.sh — the sourced post-step
# restore-and-harden choreography of the opencode review lanes
# (opencode-review-reusable.yml's two post steps and the Enforce
# verdict step; ADR-0603). Each choreography element the helper owns
# is pinned here: PATH pin, hooks neutralization, the reset to the
# event-payload RESTORE_SHA (never the model-moveable local HEAD), the
# untracked sweep outside .stellar, findings-file rejection, the
# timeout marker read, and the --no-clean shape the enforce gate uses.
# The trusted-source staging the workflow wraps around every sourcing
# (git show of the PR head SHA into a fresh mktemp file) is pinned by
# the tamper fixture at the bottom.
#
# Local run:
#   bats .github/scripts/tests/review-restore.bats
#
# Requirements:
#   bats-core >= 1.5.0  (brew install bats-core)
#   git

bats_require_minimum_version 1.5.0

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/review-restore.sh"
PINNED_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

setup() {
  TEST_TMP="$(mktemp -d)"
  # Hermetic HOME/XDG: the choreography's global core.hooksPath write
  # must land in a throwaway gitconfig, never the developer's.
  export HOME="${TEST_TMP}/home"
  export XDG_CONFIG_HOME="${TEST_TMP}/xdg"
  mkdir -p "${HOME}" "${XDG_CONFIG_HOME}" "${TEST_TMP}/runner-tmp"
  # RUNNER_TEMP stands in for the runner's temp dir (the timeout
  # marker's channel); every test gets one, marker absent by default.
  export RUNNER_TEMP="${TEST_TMP}/runner-tmp"
}

teardown() {
  rm -rf "${TEST_TMP}"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# A scratch repo standing in for the runner checkout: one tracked file,
# an ignore rule for the droplet, and .stellar/ (ignored, as in the
# real repo) as the model-output channel. Exports RESTORE_SHA — the
# event-payload SHA every call site passes: the commit the checkout
# started from (the fixture's only commit, i.e. its HEAD at birth).
make_repo() {
  REPO="${TEST_TMP}/repo"
  mkdir -p "${REPO}/.stellar"
  git -C "${REPO}" init -q
  git -C "${REPO}" config user.email review-restore@test
  git -C "${REPO}" config user.name "review-restore test"
  echo base > "${REPO}/tracked.txt"
  printf 'droplet.txt\n.stellar/\n' > "${REPO}/.gitignore"
  git -C "${REPO}" add tracked.txt .gitignore
  git -C "${REPO}" commit -qm base
  RESTORE_SHA="$(git -C "${REPO}" rev-parse HEAD)"
  export RESTORE_SHA
}

# Source the helper the way the workflow steps do — inside the scratch
# repo, with the helper's arguments — and report TIMED_OUT and PATH
# from the sourcing shell afterwards.
run_helper() {
  run bash -c '
    cd "$1" || exit 1
    . "$2" "${@:3}"
    printf "TIMED_OUT=%s\n" "${TIMED_OUT:-unset}"
    printf "PATH=%s\n" "${PATH}"
  ' _ "${REPO}" "${SCRIPT}" "$@"
}

# ---------------------------------------------------------------------------
# Interface guards
# ---------------------------------------------------------------------------

@test "sourcing without arguments fails loudly (a bare source would inherit the caller's positionals)" {
  make_repo
  run bash -c '
    helper=$1
    shift
    . "$helper"
    echo "should not reach here"
  ' _ "${SCRIPT}"
  [ "$status" -ne 0 ]
  [[ "$output" != *"should not reach here"* ]]
  [[ "$output" == *"source it with --no-clean or the findings file list"* ]]
}

@test "an unknown flag fails loudly instead of being treated as a findings file" {
  make_repo
  run_helper --bogus
  [ "$status" -ne 0 ]
  [[ "$output" == *"unknown flag: --bogus"* ]]
}

# ---------------------------------------------------------------------------
# Findings-file rejection
# ---------------------------------------------------------------------------

@test "a findings symlink is deleted and reported, its target untouched" {
  make_repo
  secret="${TEST_TMP}/runner-secret"
  echo token > "${secret}"
  ln -s "${secret}" "${REPO}/.stellar/findings.json"
  run_helper .stellar/findings.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"rejecting non-model output .stellar/findings.json (symlink or tracked at HEAD) — deleting"* ]]
  [ ! -e "${REPO}/.stellar/findings.json" ]
  [ -f "${secret}" ]
}

@test "a findings file force-added into the merge ref survives the reset and is still rejected" {
  # The poster inline comment's threat (OPLANE_REQ-00333782): a PR
  # force-adds .stellar/findings.json into its merge ref, so the event
  # payload's SHA — the RESTORE_SHA the reset targets — points at a
  # commit that tracks the planted file. It genuinely survives the
  # reset and would pose as model output, steering the poster onto
  # the pass-capable branch; the fixture mirrors that world by
  # re-pointing RESTORE_SHA at the force-adding commit.
  make_repo
  echo '{"forced": true}' > "${REPO}/.stellar/findings.json"
  git -C "${REPO}" add -f .stellar/findings.json
  git -C "${REPO}" commit -qm "force-add findings"
  RESTORE_SHA="$(git -C "${REPO}" rev-parse HEAD)"
  export RESTORE_SHA
  run_helper .stellar/findings.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"rejecting non-model output .stellar/findings.json (symlink or tracked at HEAD) — deleting"* ]]
  [ ! -e "${REPO}/.stellar/findings.json" ]
}

# ---------------------------------------------------------------------------
# Reset and clean
# ---------------------------------------------------------------------------

@test "staged and unstaged edits reset to the trusted RESTORE_SHA; untracked and ignored shadows outside .stellar removed, .stellar kept" {
  make_repo
  # the model can edit AND stage — checkout -- would restore from the index
  echo tampered > "${REPO}/tracked.txt"
  git -C "${REPO}" add tracked.txt
  echo shadow > "${REPO}/shadow.txt"
  echo droplet > "${REPO}/droplet.txt"
  echo keep > "${REPO}/.stellar/keep.txt"
  echo partial > "${REPO}/.stellar/findings.partial.json"
  run_helper .stellar/findings.json .stellar/findings.partial.json
  [ "$status" -eq 0 ]
  [ "$(cat "${REPO}/tracked.txt")" = "base" ]
  [ -z "$(git -C "${REPO}" status --porcelain)" ]
  [ ! -e "${REPO}/shadow.txt" ]
  [ ! -e "${REPO}/droplet.txt" ]
  [ -f "${REPO}/.stellar/keep.txt" ]
  # a regular untracked findings file is model output, not a shadow: kept
  [ -f "${REPO}/.stellar/findings.partial.json" ]
}

@test "--no-clean keeps untracked files outside .stellar while the reset still runs (the enforce gate's verdict file)" {
  make_repo
  echo tampered > "${REPO}/tracked.txt"
  echo pass > "${REPO}/.opencode-verdict.txt"
  echo shadow > "${REPO}/shadow.txt"
  run_helper --no-clean
  [ "$status" -eq 0 ]
  [ "$(cat "${REPO}/tracked.txt")" = "base" ]
  [ -f "${REPO}/.opencode-verdict.txt" ]
  [ -f "${REPO}/shadow.txt" ]
}

# ---------------------------------------------------------------------------
# Trusted reset target
# ---------------------------------------------------------------------------

@test "sourcing without RESTORE_SHA fails loudly — no fallback to local HEAD, which the model can move" {
  make_repo
  RESTORE_SHA= run_helper .stellar/findings.json
  [ "$status" -ne 0 ]
  [[ "$output" == *"RESTORE_SHA required"* ]]
}

@test "the reset targets RESTORE_SHA, never a locally moved HEAD (the model can commit and move HEAD)" {
  make_repo
  # the model commits its tampered tree and moves HEAD: a reset to HEAD
  # would restore the model's tree instead of the reviewed one
  echo moved > "${REPO}/tracked.txt"
  git -C "${REPO}" add tracked.txt
  git -C "${REPO}" commit -qm "model commit moves HEAD"
  [ "$(git -C "${REPO}" rev-parse HEAD)" != "$RESTORE_SHA" ]
  run_helper .stellar/findings.json
  [ "$status" -eq 0 ]
  [ "$(cat "${REPO}/tracked.txt")" = "base" ]
  [ "$(git -C "${REPO}" rev-parse HEAD)" = "$RESTORE_SHA" ]
}

# ---------------------------------------------------------------------------
# Trusted-source staging (the workflow's sourcing path)
# ---------------------------------------------------------------------------

@test "a model-rewritten worktree copy of the helper cannot alter what a token-bearing step executes — the trusted source wins" {
  # The tamper fixture: the PR head commit (the stand-in for the
  # event payload's head SHA) holds the real helper at
  # .github/scripts/review-restore.sh, and the model step has
  # rewritten the worktree copy. The workflow path stages the
  # committed copy via git show into a fresh mktemp file and sources
  # that — the worktree copy is never consulted.
  REPO="${TEST_TMP}/repo"
  mkdir -p "${REPO}/.github/scripts" "${REPO}/.stellar"
  git -C "${REPO}" init -q
  git -C "${REPO}" config user.email review-restore@test
  git -C "${REPO}" config user.name "review-restore test"
  cp "${SCRIPT}" "${REPO}/.github/scripts/review-restore.sh"
  echo base > "${REPO}/tracked.txt"
  printf 'droplet.txt\n.stellar/\n' > "${REPO}/.gitignore"
  git -C "${REPO}" add .github/scripts/review-restore.sh tracked.txt .gitignore
  git -C "${REPO}" commit -qm base
  PR_HEAD="$(git -C "${REPO}" rev-parse HEAD)"
  RESTORE_SHA="$PR_HEAD"
  export RESTORE_SHA
  # the model step rewrites the worktree copy of the helper (and the
  # tracked file, to prove the real choreography really ran) — the
  # tamper is maximally observable: a stderr banner, a marker file, a
  # poisoned PATH, and no reset
  {
    echo 'echo "TAMPER_RAN" >&2'
    echo 'touch .tamper-ran'
    echo 'export PATH=/tmp/model-bin:$PATH'
    echo 'return 0'
  } > "${REPO}/.github/scripts/review-restore.sh"
  echo tampered > "${REPO}/tracked.txt"
  # the workflow's path: stage the committed PR-head copy, source it
  run bash -c '
    cd "$1" || exit 1
    RESTORE="$(mktemp)"
    git show "$2:.github/scripts/review-restore.sh" > "$RESTORE"
    . "$RESTORE" "${@:3}"
    printf "TIMED_OUT=%s\n" "${TIMED_OUT:-unset}"
    printf "PATH=%s\n" "${PATH}"
  ' _ "${REPO}" "${PR_HEAD}" .stellar/findings.json
  [ "$status" -eq 0 ]
  # the trusted copy ran: the reset restored the reviewed tree, the
  # PATH pin and the timeout-marker read reached the sourcing shell
  [ "$(cat "${REPO}/tracked.txt")" = "base" ]
  [[ "$output" == *"PATH=${PINNED_PATH}"* ]]
  [[ "$output" == *"TIMED_OUT=0"* ]]
  # the tampered copy never executed, and its rewrite did not survive
  [[ "$output" != *"TAMPER_RAN"* ]]
  [ ! -e "${REPO}/.tamper-ran" ]
  cmp -s "${SCRIPT}" "${REPO}/.github/scripts/review-restore.sh"
}

# ---------------------------------------------------------------------------
# Timeout marker read
# ---------------------------------------------------------------------------

@test "TIMED_OUT is 1 when the run step's marker says so" {
  make_repo
  printf 1 > "${RUNNER_TEMP}/review_timed_out"
  run_helper .stellar/findings.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"TIMED_OUT=1"* ]]
}

@test "a missing marker means no timeout: TIMED_OUT is 0" {
  make_repo
  run_helper .stellar/findings.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"TIMED_OUT=0"* ]]
}

# ---------------------------------------------------------------------------
# PATH pin and hooks neutralization
# ---------------------------------------------------------------------------

@test "the PATH pin reaches the sourcing shell" {
  make_repo
  run_helper .stellar/findings.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"PATH=${PINNED_PATH}"* ]]
}

@test "hooks are neutralized: local core.hooksPath unset, global pointed at /dev/null" {
  make_repo
  git -C "${REPO}" config core.hooksPath .githooks
  run_helper .stellar/findings.json
  [ "$status" -eq 0 ]
  # local core.hooksPath unset: --get must find nothing
  ! git -C "${REPO}" config --get core.hooksPath >/dev/null 2>&1
  grep -q "hooksPath = /dev/null" "${HOME}/.gitconfig"
}
