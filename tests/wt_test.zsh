#!/usr/bin/env zsh

set -eu

WT_SOURCE="${0:A:h:h}/wt.sh"
TEST_ROOT="$(realpath "$(mktemp -d "${TMPDIR:-/tmp}/wt-test.XXXXXX")")"
trap 'rm -rf -- "$TEST_ROOT"' EXIT

fail() {
  print -u2 -- "FAIL: $*"
  exit 1
}

assert_eq() {
  [[ "$1" == "$2" ]] || fail "expected <$2>, got <$1>"
}

BASE="$TEST_ROOT/repo"
mkdir -p "$BASE"
git -C "$BASE" init -q
git -C "$BASE" config user.name wt-test
git -C "$BASE" config user.email wt-test@example.invalid
git -C "$BASE" config commit.gpgsign false
git -C "$BASE" config wt.ai false
git -C "$BASE" config wt.default-branch main
git -C "$BASE" commit --allow-empty -qm initial
git -C "$BASE" branch -M main

source "$WT_SOURCE"
cd "$BASE"

# Existing behavior remains: a positional branch creates a worktree and does not cd.
start_dir="$PWD"
wt new compatible >/dev/null
assert_eq "$PWD" "$start_dir"
assert_eq "$(wt path compatible)" "$TEST_ROOT/repo@compatible"

# Prompt input creates the requested branch; --cd changes the sourced shell.
wt new --prompt --cd --no-ai <<< 'issue/123' >/dev/null 2>"$TEST_ROOT/prompt.err"
assert_eq "$PWD" "$TEST_ROOT/repo@issue-123"
assert_eq "$(wt path)" "$TEST_ROOT/repo@issue-123"
assert_eq "$(wt path issue/123)" "$TEST_ROOT/repo@issue-123"
assert_eq "$(wt home-path)" "$BASE"

# home-path is identical from the base checkout.
cd "$BASE"
assert_eq "$(wt home-path)" "$BASE"
assert_eq "$(wt path)" "$BASE"

# Empty input, EOF, invalid refs, and duplicates fail without creating worktrees.
if wt new --prompt <<< '' >/dev/null 2>&1; then fail 'empty prompt input succeeded'; fi
if wt new --prompt </dev/null >/dev/null 2>&1; then fail 'cancelled prompt succeeded'; fi
if wt new 'bad..branch' >/dev/null 2>&1; then fail 'invalid branch succeeded'; fi
if wt new compatible >/dev/null 2>&1; then fail 'duplicate branch succeeded'; fi

# --cd also works with an explicit slash-containing branch.
wt new feature/nested --cd --no-ai >/dev/null
assert_eq "$PWD" "$TEST_ROOT/repo@feature-nested"
assert_eq "$(wt path feature/nested)" "$PWD"

print -- 'ok: wt tests passed'
