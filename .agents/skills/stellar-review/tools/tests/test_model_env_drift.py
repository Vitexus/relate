"""Drift guard for the review-model env vocabulary (ADR-0302): the four
`STELLAR_MODEL_<PASS>` names are the ones the generator reads
(`pass_models.pass_model_env()`, derived from the canonical production pass
registry `briefs.PASS_LAYOUT`), and every copy of the vocabulary — the
reusable workflow's pass-model step env and workflow_call secrets, its
callers' secrets blocks (every watched `opencode-review-*` workflow but the
reusable one), SKILL.md's MODEL TIERS rule, and the
review-scripts-test path filter — must agree with it. The pass names stay
out of the shared Run OpenCode step, whose only override is
OPENCODE_REVIEW_MODEL. The default model pin the override falls back to
must match ADR-0302's Decision table in both workflows that carry it.

The same file also pins the reusable workflow's three post-model hardening
guarantees (ADR-0603): the Run OpenCode step's env blanks the
`GITHUB_ENV`/`GITHUB_PATH` publish channels (a model shell must not
publish env vars or PATH entries — a BASH_ENV-style payload included —
into the later, token-bearing steps), the three restore call sites
(scripted post, per-kind post, enforce) stage review-restore.sh from the
PR head SHA's committed copy instead of the model-writable worktree,
and every token-bearing post step pins its process-start environment
at the step env level — the complete set of env channels the ELF
loader and the runner's interpreters document for loading code at
process start (PINNED_STARTUP_VARS below), each pinned to the empty
string and PATH pinned to the fixed system list review-restore.sh
pins — because the blanking stops only the model's own file-command
writes (the runner env file under RUNNER_TEMP stays writable by
path), while a step env entry, the most specific Actions env scope,
overrides anything published and holds from process start. The
guarded steps are enumerated from the workflow itself (every step
after the model step whose env maps GH_TOKEN), so adding a step or
renaming a pin in the workflow fails the drift test until every
token-bearing post step carries the full list.

The same step env pins git's configuration file sources (the round-5
finding: the model shell can write .git/config, the worktree-scoped
config and the shared HOME gitconfig, and every git command the post
steps run parses them) — GIT_CONFIG_GLOBAL/GIT_CONFIG_SYSTEM at
/dev/null, GIT_CONFIG_NOSYSTEM on, GIT_CONFIG_COUNT zeroed (the
env-numbered `GIT_CONFIG_KEY_n` pairs are git configuration too,
plantable through the same runner env file) — and every restore-path
git invocation (the staging `git show` and the helper's reset, clean
and ls-files) pins the repository config's code-execution knobs off
per invocation with `-c core.fsmonitor= -c core.pager=cat`.
review-restore.sh must export the same config-source pins in-script,
the PATH-pin defense-in-depth precedent.
"""

import glob
import os
import re
import unittest

from helpers import ROOT, read, region_between  # also puts tools/ on sys.path

import pass_models

WORKFLOWS = os.path.join(ROOT, ".github", "workflows")
REUSABLE = os.path.join(WORKFLOWS, "opencode-review-reusable.yml")
NIGHTSHIFT = os.path.join(WORKFLOWS, "stellar-nightshift.yml")
REVIEW_SCRIPTS_TEST = os.path.join(WORKFLOWS, "review-scripts-test.yml")
SKILL = os.path.join(ROOT, ".agents", "skills", "stellar-review", "SKILL.md")
ADR_0302 = os.path.join(ROOT, "docs", "adr", "0302-review-model-env-override.md")
RESTORE_HELPER = os.path.join(ROOT, ".github", "scripts", "review-restore.sh")

# Never re-typed: the four pass-tier names are exactly the ones the
# generator reads (pass_models.pass_model_env()), plus the run-level
# override every review shares.
PASS_TIER_NAMES = tuple(pass_models.pass_model_env().values())
SECRET_NAMES = ("OPENCODE_REVIEW_MODEL",) + PASS_TIER_NAMES

# A whole STELLAR_MODEL_* token: `\w+` runs to the end of the identifier, so
# a renamed name (`STELLAR_MODEL_STRUCTURE_`) is never truncated back into a
# registered one.
MODEL_TOKEN = re.compile(r"\bSTELLAR_MODEL_\w+")

# Each review run and the env var its `opencode run --model` reads; the
# var's env line carries the default pin.
MODEL_RUNS = (
    (REUSABLE, "OPENCODE_REVIEW_MODEL"),
    (NIGHTSHIFT, "STELLAR_NIGHTSHIFT_MODEL"),
)

# review-scripts-test.yml must run when any of these change, or this guard
# never executes in CI. REVIEW_GLOB is also the caller set's source.
REVIEW_GLOB = ".github/workflows/opencode-review-*.yml"
WATCHED_PATHS = (
    REVIEW_GLOB,
    ".github/workflows/stellar-nightshift.yml",
    ".agents/skills/stellar-review/SKILL.md",
)

# The reusable workflow's callers: every watched review workflow but the
# reusable one itself, so a new caller is guarded without being listed.
CALLERS = tuple(
    sorted(
        path
        for path in glob.glob(os.path.join(ROOT, REVIEW_GLOB))
        if path != REUSABLE
    )
)

# The complete set of process-start code-injection channels every
# token-bearing post step pins to the empty string — every env var the
# ELF loader and the runner's interpreters document for loading code
# at process start: the shell startup files (BASH_ENV — bash's
# non-interactive startup file; ENV — the POSIX sh counterpart), the
# ELF dynamic loader's channels (LD_PRELOAD — a library whose
# constructors run at process start, LD_LIBRARY_PATH — the search
# path that resolves every later dependency, LD_AUDIT — an audit
# object loaded into every process, ld.so(8)), python's startup file
# and search paths (PYTHONSTARTUP, PYTHONPATH — the module search
# path that shadows stdlib imports, PYTHONHOME — the relocated
# standard library itself, python(1)), node's per-process flags and
# module path (NODE_OPTIONS — flags may carry --require, NODE_PATH —
# the module search path, node(1)), perl's injected switches and
# module paths (PERL5OPT — switches may carry -M, PERL5LIB, PERLLIB —
# the @INC search paths, perlrun(1)), ruby's injected options and
# load path (RUBYOPT — options may carry -r, RUBYLIB — the $LOAD_PATH
# entries, ruby(1)), and RubyGems' gem-resolution paths (GEM_HOME,
# GEM_PATH — gem(1)). An empty value is inert for every one of them —
# an empty list has no entries and an empty startup-file name opens
# nothing — so no step behavior changes. PATH is pinned separately,
# to the fixed system list review-restore.sh pins.
PINNED_STARTUP_VARS = (
    "BASH_ENV",
    "ENV",
    "LD_PRELOAD",
    "LD_LIBRARY_PATH",
    "LD_AUDIT",
    "PYTHONSTARTUP",
    "PYTHONPATH",
    "PYTHONHOME",
    "NODE_OPTIONS",
    "NODE_PATH",
    "PERL5OPT",
    "PERL5LIB",
    "PERLLIB",
    "RUBYOPT",
    "RUBYLIB",
    "GEM_HOME",
    "GEM_PATH",
)

# The git configuration sources every token-bearing post step pins away
# (the round-5 finding: the model shell can write .git/config, the
# worktree-scoped config and the shared HOME gitconfig, and every git
# command the post steps run parses them): the global (shared HOME) and
# system gitconfigs point at /dev/null, the system file is skipped
# outright, and the env-numbered config channel is zeroed —
# GIT_CONFIG_KEY_n/GIT_CONFIG_VALUE_n pairs are git configuration too,
# plantable through the runner env file under RUNNER_TEMP. The values
# are the workflow's step env spellings; review-restore.sh exports the
# same pins in-script (defense-in-depth, the PATH-pin precedent).
PINNED_GIT_CONFIG = {
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_SYSTEM": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "'1'",
    "GIT_CONFIG_COUNT": "'0'",
}


def mapping_entry(region, name):
    """The lines of the `name:` entry inside a YAML mapping region, up to
    the next key at the same indentation (or the end of the region)."""
    m = re.search(r"^( *)" + re.escape(name) + r": *$", region, re.M)
    if m is None:
        return None
    rest = region[m.end():]
    nxt = re.search(r"^ {" + str(len(m.group(1))) + r"}\S", rest, re.M)
    return rest[: nxt.start()] if nxt else rest


def env_default(text, name):
    """The `|| '<literal>'` fallback on `name`'s env line."""
    m = re.search(r"(?m)^ *" + re.escape(name) + r":.*\|\| *'([^']+)'", text)
    if m is None:
        raise AssertionError(f"{name}: no `|| '<default>'` fallback on its env line")
    return m.group(1)


def env_value(step, name):
    """The value on `name`'s env line inside `step`, or None when absent."""
    m = re.search(r"^ *" + re.escape(name) + r": *(.*)$", step, re.M)
    return m.group(1) if m else None


def secrets_block(path):
    """`path`'s text after its one `secrets:` line; fails unless the file
    has exactly one."""
    text = read(path)
    starts = list(re.finditer(r"^ *secrets: *$", text, re.M))
    if len(starts) != 1:
        raise AssertionError(
            f"{path}: expected exactly one `secrets:` block, found {len(starts)}"
        )
    return text[starts[0].end():]


def model_step():
    """The reusable workflow's Run OpenCode step (the shared model run)."""
    return region_between(
        read(REUSABLE), r"^ *- name: Run OpenCode", r"^ *- name: ", REUSABLE
    )


def pass_model_step():
    """The reusable workflow's stellar-only step that turns the pass
    overrides into OpenCode agent config (pass_models.py)."""
    return region_between(
        read(REUSABLE),
        r"^ *- name: Apply stellar pass-model overrides",
        r"^ *- name: ",
        REUSABLE,
    )


def post_model_steps():
    """(name, region) of every step after the Run OpenCode step, in
    workflow order — the steps the shell-capable model step precedes.
    The step-entry indentation is taken from the model step's own
    line, so deeper `- name:`-shaped text inside a step never splits
    the enumeration."""
    text = read(REUSABLE)
    m = re.search(r"^( *- name:) Run OpenCode", text, re.M)
    if m is None:
        raise AssertionError(f"{REUSABLE}: no Run OpenCode step found")
    rest = text[m.start():]
    starts = list(re.finditer(r"^" + re.escape(m.group(1)) + r" ", rest, re.M))
    prefix = len(m.group(1)) + 1
    steps = []
    for i, s in enumerate(starts):
        end = starts[i + 1].start() if i + 1 < len(starts) else len(rest)
        block = rest[s.start():end]
        steps.append((block.split("\n", 1)[0][prefix:].rstrip(), block))
    return steps[1:]  # starts[0] is the model step itself


def token_bearing_post_steps():
    """(name, region) of the post-model steps whose env maps GH_TOKEN —
    the workflow's marker for a step that authenticates to GitHub as
    CI, i.e. every step the process-start pinning must cover. The set
    is derived from the workflow, never hand-listed, so a step added
    there fails the pin test until it carries the full pin list."""
    steps = [
        (name, region)
        for name, region in post_model_steps()
        if re.search(r"^ *GH_TOKEN: ", region, re.M)
    ]
    if not steps:
        raise AssertionError(
            f"{REUSABLE}: no post-model step maps GH_TOKEN — the "
            "token-bearing step derivation found nothing to guard"
        )
    return steps


def restore_pinned_path():
    """The fixed system PATH review-restore.sh pins — the one spelling
    the workflow's step-level PATH pins must match."""
    m = re.search(r"(?m)^export PATH=(\S+)$", read(RESTORE_HELPER))
    if m is None:
        raise AssertionError(f"{RESTORE_HELPER}: no `export PATH=` pin found")
    return m.group(1)


def model_tiers_rule():
    """SKILL.md's MODEL TIERS rule, through the next `## ` heading."""
    return region_between(read(SKILL), r"^#* *MODEL TIERS", r"^## ", SKILL)


class TestModelEnvDrift(unittest.TestCase):
    def assert_forwarded(self, step, label, name):
        value = env_value(step, name)
        self.assertIsNotNone(value, f"{REUSABLE}: {name} missing from the {label} env")
        self.assertIn(
            f"secrets.{name}",
            value,
            f"{REUSABLE}: {name} in the {label} env must read the secret",
        )
        self.assertIn(
            f"vars.{name}",
            value,
            f"{REUSABLE}: {name} in the {label} env must fall back to the repo variable",
        )

    def test_model_step_env_forwards_only_the_run_override(self):
        step = model_step()
        self.assert_forwarded(step, "Run OpenCode step", "OPENCODE_REVIEW_MODEL")
        self.assertEqual(
            MODEL_TOKEN.findall(step),
            [],
            f"{REUSABLE}: the Run OpenCode step must carry no STELLAR_MODEL_* "
            "name — pass overrides apply through the pass-model step's "
            "OpenCode config, never the shared model step env",
        )

    def test_model_step_env_blanks_the_publish_channels(self):
        # A shell-capable model must not publish environment variables or
        # PATH entries into later steps: with GITHUB_ENV/GITHUB_PATH set to
        # the empty string, the runner's env/PATH files are replaced by ''
        # — not a writable path — so every publish attempt fails and no
        # BASH_ENV-style payload is live in the post steps. PROMPT_FILE,
        # published as a fixed value by the earlier prompt step, still
        # reaches the model step as a normal env var.
        step = model_step()
        for name in ("GITHUB_ENV", "GITHUB_PATH"):
            with self.subTest(name=name):
                self.assertEqual(
                    env_value(step, name),
                    "''",
                    f"{REUSABLE}: the Run OpenCode step env must set {name} "
                    "to the empty string — the model shell must not publish "
                    "env or PATH entries into later steps",
                )
        self.assertIn(
            '"$PROMPT_FILE"',
            step,
            f"{REUSABLE}: the Run OpenCode step still reads $PROMPT_FILE — "
            "the fixed-value publish from the prompt-file step must keep "
            "reaching the model step as a normal env var",
        )

    def test_restore_call_sites_stage_the_helper_from_trusted_content(self):
        # The three hardening call sites (scripted post, per-kind post,
        # enforce) must never source the worktree copy of
        # review-restore.sh — the model step could have rewritten it
        # before any token-bearing step runs. Each stages the committed
        # PR-head copy (git show of the event payload's head SHA) into a
        # fresh mktemp file and sources that; the staging show carries
        # the per-invocation -c overrides, so a model-written .git/config
        # cannot steer even this first git call (the step env pins the
        # file sources, but the repository config still parses); the
        # helper then resets to RESTORE_SHA — the event payload's merge
        # SHA, never the model-moveable local HEAD.
        text = read(REUSABLE)
        self.assertNotIn(
            ". .github/scripts/review-restore.sh",
            text,
            f"{REUSABLE}: a restore call site sources the worktree copy of "
            "review-restore.sh — it must stage the committed PR-head copy "
            "via git show instead (ADR-0603)",
        )
        staging = (
            'git -c core.fsmonitor= -c core.pager=cat show '
            '"$HEAD_SHA:.github/scripts/review-restore.sh" > "$RESTORE"'
        )
        self.assertEqual(
            text.count(staging),
            3,
            f"{REUSABLE}: expected the three restore call sites to stage "
            "review-restore.sh with the pinned git show of the PR head SHA",
        )
        self.assertEqual(
            text.count('. "$RESTORE"'),
            3,
            f"{REUSABLE}: expected the three restore call sites to source "
            "the staged trusted copy",
        )
        self.assertEqual(
            text.count("RESTORE_SHA: ${{ github.sha }}"),
            3,
            f"{REUSABLE}: each restore call site must pass the event "
            "payload's merge SHA as RESTORE_SHA — the trusted reset target",
        )

    def test_post_steps_pin_process_start_env(self):
        # The blanked GITHUB_ENV/GITHUB_PATH stop the model's own
        # file-command writes, but the runner's env file for each later
        # step is still writable by path under RUNNER_TEMP — and the
        # restore script's PATH pin only lands once the run block is
        # already executing, after bash/loader startup consumed
        # BASH_ENV/LD_PRELOAD/…. A step env entry is the most specific
        # Actions env scope (workflow syntax, jobs.<job_id>.steps.env:
        # an env variable defined in a step "will override job and
        # workflow environment variables with the same name, while the
        # step executes"), so pinning there overrides anything the model
        # published — from process start, with fixed literals only.
        # The guarded steps are not hand-listed: they are enumerated
        # from the workflow itself (every post-model step whose env
        # maps GH_TOKEN), so a step added or a pin renamed in the
        # workflow fails here until every token-bearing post step
        # carries the full list.
        path = restore_pinned_path()
        for name, step in token_bearing_post_steps():
            for var in PINNED_STARTUP_VARS:
                with self.subTest(step=name, var=var):
                    self.assertEqual(
                        env_value(step, var),
                        "''",
                        f"{REUSABLE}: the '{name}' step must pin {var} to "
                        "the empty string — a model-published process-start "
                        "channel must be inert from process start",
                    )
            with self.subTest(step=name, var="PATH"):
                self.assertEqual(
                    env_value(step, "PATH"),
                    path,
                    f"{REUSABLE}: the '{name}' step must pin PATH to the "
                    "fixed system list review-restore.sh pins — the "
                    "workflow-fixed value, never model-published content",
                )

    def test_post_steps_pin_git_config_sources(self):
        # Model-written git configuration must be inert in every git
        # call a token-bearing post step runs (the round-5 finding):
        # the model shell can write the shared HOME gitconfig during
        # the model step, and GIT_CONFIG_KEY_n/GIT_CONFIG_VALUE_n pairs
        # planted through the runner env file under RUNNER_TEMP are
        # parsed as git configuration by every git command. The step
        # env pins the file sources from process start — before the
        # staging git show runs. The repository's own .git/config
        # survives the pin and is handled per invocation instead: the
        # -c core.fsmonitor= -c core.pager=cat overrides on the
        # staging git show and inside review-restore.sh. The guarded
        # steps are the same workflow-derived token-bearing set the
        # process-start pin test above iterates.
        for name, step in token_bearing_post_steps():
            for var, value in PINNED_GIT_CONFIG.items():
                with self.subTest(step=name, var=var):
                    self.assertEqual(
                        env_value(step, var),
                        value,
                        f"{REUSABLE}: the '{name}' step must pin {var} "
                        f"to {value} — model-written git configuration "
                        "must be inert in every git call the step runs",
                    )

    def test_restore_helper_exports_the_same_config_pins(self):
        # review-restore.sh re-exports the step env's config-source
        # pins in-script — the PATH-pin defense-in-depth precedent: the
        # sourced choreography must hold in any shell it is sourced
        # into, and the two spellings must never drift apart.
        for var, value in PINNED_GIT_CONFIG.items():
            expected = value.strip("'")
            with self.subTest(var=var):
                m = re.search(
                    r"(?m)^export " + re.escape(var) + r"=(\S+)$",
                    read(RESTORE_HELPER),
                )
                self.assertIsNotNone(
                    m,
                    f"{RESTORE_HELPER}: no `export {var}=` pin found — "
                    "the choreography must re-export the workflow's "
                    "config-source pins",
                )
                self.assertEqual(
                    m.group(1),
                    expected,
                    f"{RESTORE_HELPER}: the {var} pin drifted from the "
                    f"workflow's step env value ({expected})",
                )

    def test_pass_model_step_env_forwards_every_pass(self):
        step = pass_model_step()
        for name in PASS_TIER_NAMES:
            with self.subTest(name=name):
                self.assert_forwarded(step, "pass-model step", name)

    def test_pass_model_step_configures_the_scripted_run(self):
        step = pass_model_step()
        self.assertRegex(
            step,
            r"(?m)^ *if: inputs\.pipeline == 'scripted' *$",
            f"{REUSABLE}: the pass-model step must run only for the scripted pipeline",
        )
        self.assertRegex(
            step,
            r"(?m)^ *run: python3 \.agents/skills/stellar-review/tools/pass_models\.py *$",
            f"{REUSABLE}: the pass-model step must run pass_models.py",
        )
        text = read(REUSABLE)
        self.assertLess(
            text.index(step),
            text.index(model_step()),
            f"{REUSABLE}: the pass-model step must run before the Run OpenCode step",
        )

    def test_no_unregistered_model_token(self):
        # Negative assertion: every STELLAR_MODEL_* token present must be a
        # registered pass tier — a renamed or an extra name fails.
        for label, region in ((REUSABLE, pass_model_step()), (SKILL, model_tiers_rule())):
            with self.subTest(surface=label):
                found = set(MODEL_TOKEN.findall(region))
                self.assertEqual(
                    found,
                    set(PASS_TIER_NAMES),
                    f"{label}: STELLAR_MODEL_* tokens drifted from "
                    f"pass_models.pass_model_env() (extra: "
                    f"{sorted(found - set(PASS_TIER_NAMES))}, missing: "
                    f"{sorted(set(PASS_TIER_NAMES) - found)})",
                )

    def test_default_pin_matches_adr_0302(self):
        pins = {var: env_default(read(path), var) for path, var in MODEL_RUNS}
        distinct = set(pins.values())
        self.assertEqual(
            len(distinct),
            1,
            f"the {' and '.join(pins)} default pins drifted apart: {pins}",
        )
        (pin,) = distinct
        decision = region_between(read(ADR_0302), r"^## Decision", r"^## ", ADR_0302)
        self.assertIn(
            pin,
            decision,
            f"{ADR_0302}: default {pin!r} is not in the Decision table — "
            "bumping the default requires a new ADR (accepted ADRs are "
            "immutable)",
        )

    def test_reusable_declares_the_workflow_call_secrets(self):
        rest = secrets_block(REUSABLE)
        jobs = re.search(r"^jobs:", rest, re.M)
        self.assertIsNotNone(
            jobs, f"{REUSABLE}: no `jobs:` after the workflow_call secrets map"
        )
        declared = rest[: jobs.start()]
        for name in SECRET_NAMES:
            with self.subTest(name=name):
                entry = mapping_entry(declared, name)
                self.assertIsNotNone(
                    entry,
                    f"{REUSABLE}: {name} not declared under on.workflow_call.secrets",
                )
                self.assertRegex(
                    entry,
                    r"(?m)^ *required: false *$",
                    f"{REUSABLE}: {name} must be declared required: false",
                )
        entry = mapping_entry(declared, "FIREWORKS_API_KEY")
        self.assertIsNotNone(
            entry, f"{REUSABLE}: FIREWORKS_API_KEY not declared under on.workflow_call.secrets"
        )
        self.assertRegex(
            entry,
            r"(?m)^ *required: true *$",
            f"{REUSABLE}: FIREWORKS_API_KEY must be declared required: true",
        )

    def test_callers_call_the_reusable_workflow(self):
        # A REVIEW_GLOB match that is not a caller must fail here, not be
        # held to (or silently skip) the secrets contract below.
        self.assertTrue(CALLERS, f"no caller workflow matches {REVIEW_GLOB}")
        uses = "./" + os.path.relpath(REUSABLE, ROOT)
        for path in CALLERS:
            with self.subTest(caller=os.path.basename(path)):
                self.assertRegex(
                    read(path),
                    r"(?m)^ *uses: *" + re.escape(uses) + r" *$",
                    f"{path}: matches {REVIEW_GLOB} but has no `uses: {uses}`",
                )

    def test_callers_pass_every_secret(self):
        for path in CALLERS:
            block = secrets_block(path)
            for name in SECRET_NAMES:
                with self.subTest(caller=os.path.basename(path), name=name):
                    pat = (
                        r"(?m)^ *"
                        + re.escape(name)
                        + r": *"
                        + re.escape("${{ secrets." + name + " }}")
                        + r" *$"
                    )
                    self.assertRegex(
                        block,
                        pat,
                        f"{path}: {name} is not passed as ${{{{ secrets.{name} }}}}",
                    )

    def test_review_runs_use_variable_models(self):
        for path, var in MODEL_RUNS:
            with self.subTest(workflow=os.path.basename(path)):
                tokens = re.findall(r"opencode run --model +(\S+)", read(path))
                self.assertTrue(tokens, f"{path}: no `opencode run --model` invocation")
                for token in tokens:
                    self.assertEqual(
                        token,
                        f'"${var}"',
                        f'{path}: `opencode run --model` must read "${var}"',
                    )

    def test_review_scripts_test_watches_the_guarded_files(self):
        paths = region_between(
            read(REVIEW_SCRIPTS_TEST),
            r"^ *pull_request:",
            r"^ *workflow_dispatch:",
            REVIEW_SCRIPTS_TEST,
        )
        for entry in WATCHED_PATHS:
            with self.subTest(path=entry):
                self.assertRegex(
                    paths,
                    r'(?m)^ *- "?' + re.escape(entry) + r'"? *$',
                    f"{REVIEW_SCRIPTS_TEST}: pull_request paths must include {entry}",
                )


if __name__ == "__main__":
    unittest.main()
