# Behavioral tests for review-restore.sh — the sourced post-step
# restore-and-harden choreography of the opencode review lanes
# (opencode-review-reusable.yml's two post steps and the Enforce
# verdict step; ADR-0603). Each choreography element the helper owns
# is pinned here: PATH pin, git-configuration neutralization (the
# GIT_CONFIG_* source pins and the per-invocation fsmonitor/pager
# overrides), hooks neutralization, the reset to the event-payload
# RESTORE_SHA (never the model-moveable local HEAD), the untracked
# sweep outside .stellar, findings-file rejection, the timeout marker
# read, and the --no-clean shape the enforce gate uses. The
# trusted-source staging the workflow wraps around every sourcing
# (git show of the PR head SHA into a fresh mktemp file) is pinned by
# the tamper fixture and the round-5 config payloads at the bottom:
# a model step with shell access can write .git/config, the
# worktree-scoped config and the shared HOME gitconfig, and every git
# command the post steps run parses them.
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
  # Hermetic HOME/XDG: the config-payload tests below write a
  # model-written global gitconfig, and no test may touch the
  # developer's real one.
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

# A model-written "hook" script and its observable marker: the config
# payloads below point git's code-execution knobs (fsmonitor, pager,
# aliases, hooks) at it and assert the marker never appears.
plant_marker_hook() {
  EVIL="${TEST_TMP}/model-payload.sh"
  MARKER="${TEST_TMP}/payload-ran"
  printf '#!/bin/sh\ntouch "%s"\n' "${MARKER}" > "${EVIL}"
  chmod +x "${EVIL}"
}

# The trusted-source fixture: a stand-in runner checkout whose one
# commit — the event-payload SHA the workflow stages and resets from —
# carries the real helper at .github/scripts/review-restore.sh. The
# tamper and config-payload tests below plant model-step output on top
# of it. Exports PR_HEAD (the stand-in head SHA) and RESTORE_SHA.
make_helper_repo() {
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
}

# The workflow's trusted-source path (opencode-review-reusable.yml's
# post steps): stage the committed PR-head copy of the helper with the
# pinned git invocation, verify the staged bytes are the trusted
# commit's, then source the staged copy — all inside a stand-in for
# the post step's shell, so the helper's exported pins land there.
run_trusted_staging() {
  run bash -c '
    cd "$1" || exit 1
    RESTORE="$(mktemp)"
    git -c core.fsmonitor= -c core.pager=cat show "$2:.github/scripts/review-restore.sh" > "$RESTORE"
    if cmp -s "$RESTORE" "$3"; then
      printf "STAGED_TRUSTED=yes\n"
    else
      printf "STAGED_TRUSTED=no\n"
    fi
    . "$RESTORE" "${@:4}"
    printf "TIMED_OUT=%s\n" "${TIMED_OUT:-unset}"
    printf "PATH=%s\n" "${PATH}"
  ' _ "${REPO}" "${PR_HEAD}" "${SCRIPT}" "$@"
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

@test "a model-created FIFO at the findings path is rejected without ever being opened — the post step cannot stall on it" {
  # A FIFO is the cheapest non-regular file the model can plant: the
  # poster's open() would block until a writer appears, stalling the
  # post step. The gate must delete it on sight — stat only, never an
  # open — so reaching the assertions below at all proves the helper
  # did not hang on it.
  make_repo
  mkfifo "${REPO}/.stellar/findings.json"
  run_helper .stellar/findings.json
  [ "$status" -eq 0 ]
  [[ "$output" == *"rejecting non-model output .stellar/findings.json (symlink or tracked at HEAD) — deleting"* ]]
  [ ! -e "${REPO}/.stellar/findings.json" ]
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
  make_helper_repo
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
  run_trusted_staging .stellar/findings.json
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
# Model-written git configuration (the round-5 finding and the round-4
# model experiments: the model step can write .git/config with
# core.fsmonitor and aliases, and the shared HOME gitconfig — and
# every git command the post steps run parses that config)
# ---------------------------------------------------------------------------

@test "a model-written .git/config core.fsmonitor executes nothing — the restore's git calls pin fsmonitor and pager off per invocation" {
  make_helper_repo
  plant_marker_hook
  # the round-5 payload: core.fsmonitor (and a pager) in .git/config
  # pointing at a marker script — without the per-invocation -c
  # overrides, every index-refreshing git command in the restore
  # (reset --hard, clean, ls-files) runs the model's fsmonitor hook
  # with the write token
  git -C "${REPO}" config core.fsmonitor "${EVIL}"
  git -C "${REPO}" config core.pager "${EVIL}"
  echo tampered > "${REPO}/tracked.txt"
  run_trusted_staging .stellar/findings.json
  [ "$status" -eq 0 ]
  # no model-written fsmonitor or pager ever executed
  [ ! -e "${MARKER}" ]
  # the restore itself still ran: tracked content back to the trusted base
  [ "$(cat "${REPO}/tracked.txt")" = "base" ]
  # the staged helper is the trusted commit's bytes, not a steered read
  [[ "$output" == *"STAGED_TRUSTED=yes"* ]]
}

@test "a model-written global gitconfig (the shared HOME) is ignored, not obeyed or edited — GIT_CONFIG_GLOBAL pins it to /dev/null" {
  make_helper_repo
  plant_marker_hook
  # the round-4 experiment payload: the model shell wrote the shared
  # HOME gitconfig — fsmonitor, a pager and a hooks dir of its own
  mkdir -p "${TEST_TMP}/model-githooks"
  printf '#!/bin/sh\ntouch "%s"\n' "${MARKER}" > "${TEST_TMP}/model-githooks/post-checkout"
  chmod +x "${TEST_TMP}/model-githooks/post-checkout"
  {
    echo "[core]"
    echo "	fsmonitor = ${EVIL}"
    echo "	pager = ${EVIL}"
    echo "	hooksPath = ${TEST_TMP}/model-githooks"
  } > "${HOME}/.gitconfig"
  echo tampered > "${REPO}/tracked.txt"
  run_trusted_staging .stellar/findings.json
  [ "$status" -eq 0 ]
  # no model-written global fsmonitor, pager or hook ever executed
  [ ! -e "${MARKER}" ]
  [ "$(cat "${REPO}/tracked.txt")" = "base" ]
  [[ "$output" == *"STAGED_TRUSTED=yes"* ]]
  # the model-written global gitconfig is untouched — ignored under
  # the GIT_CONFIG_GLOBAL pin, never rewritten
  grep -q "hooksPath = ${TEST_TMP}/model-githooks" "${HOME}/.gitconfig"
}

@test "a planted object-store alias attempt stays inert — builtins win, the trusted SHA still resolves to the trusted bytes" {
  make_helper_repo
  plant_marker_hook
  # the model step's redirect attempts on the object-store read the
  # post steps stage from: config aliases shadowing the four git
  # commands of the restore path, and an alternates entry aliasing a
  # model-controlled directory into the object store
  git -C "${REPO}" config alias.show "!${EVIL}"
  git -C "${REPO}" config alias.reset "!${EVIL}"
  git -C "${REPO}" config alias.clean "!${EVIL}"
  git -C "${REPO}" config alias.ls-files "!${EVIL}"
  mkdir -p "${TEST_TMP}/model-objects" "${REPO}/.git/objects/info"
  echo "${TEST_TMP}/model-objects" > "${REPO}/.git/objects/info/alternates"
  echo tampered > "${REPO}/tracked.txt"
  run_trusted_staging .stellar/findings.json
  [ "$status" -eq 0 ]
  # no alias ever executed: git builtins take precedence over alias
  # definitions, so the planted names never run
  [ ! -e "${MARKER}" ]
  [ "$(cat "${REPO}/tracked.txt")" = "base" ]
  # the staged helper came from the real git show builtin reading the
  # event-payload SHA — the trusted-commit bytes, not an alias's
  # output; an object-store write the model can perform cannot
  # redirect a full-SHA object read
  [[ "$output" == *"STAGED_TRUSTED=yes"* ]]
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

@test "hooks are neutralized: local core.hooksPath unset, the global config pinned away" {
  make_repo
  # the model step planted a local hooks path AND wrote a global
  # gitconfig naming its own hooks dir
  git -C "${REPO}" config core.hooksPath .githooks
  mkdir -p "${TEST_TMP}/model-githooks"
  printf '#!/bin/sh\nexit 0\n' > "${TEST_TMP}/model-githooks/post-checkout"
  git config --global core.hooksPath "${TEST_TMP}/model-githooks"
  run_helper .stellar/findings.json
  [ "$status" -eq 0 ]
  # local core.hooksPath unset: --get must find nothing
  ! git -C "${REPO}" config --get core.hooksPath >/dev/null 2>&1
  # the model-written global gitconfig is untouched — ignored under
  # the GIT_CONFIG_GLOBAL pin, never rewritten
  grep -q "hooksPath = ${TEST_TMP}/model-githooks" "${HOME}/.gitconfig"
}
