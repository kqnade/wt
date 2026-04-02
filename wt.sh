# wt.sh — git worktree manager
# source this file from your shell rc
#
# Usage: source /path/to/wt.sh

# ─────────────────────────────────────────────────────────────────────────────
# Internal helpers
# ─────────────────────────────────────────────────────────────────────────────

# Return absolute path of the base (main) repository root
_wt_base() {
  command -v realpath > /dev/null 2>&1 \
    || { printf 'error: realpath is required but not found\n' >&2; return 1; }
  local common_dir
  common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" \
    || { printf 'error: not a git repository\n' >&2; return 1; }
  dirname "$(realpath "$common_dir")"
}

# True when cwd is a linked worktree (not the main checkout)
_wt_in_worktree() {
  local git_dir git_common_dir
  git_dir="$(git rev-parse --git-dir 2>/dev/null)"              || return 1
  git_common_dir="$(git rev-parse --git-common-dir 2>/dev/null)" || return 1
  [[ "$git_dir" != "$git_common_dir" ]]
}

# Translate branch name to a directory-safe string (/ → -)
_wt_branch_to_dir() {
  printf '%s\n' "${1//\//-}"
}

# Return the default branch name (origin/HEAD > wt.default-branch config)
_wt_default_branch() {
  git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's|refs/remotes/origin/||' \
    || git config wt.default-branch 2>/dev/null \
    || { printf 'error: cannot detect default branch; set wt.default-branch\n' >&2; return 1; }
}

# Guard: must be in a git repo
_wt_require_git() {
  git rev-parse --git-dir > /dev/null 2>&1 \
    || { printf 'error: not a git repository\n' >&2; return 1; }
}

# Guard: must be in a linked worktree (not base)
_wt_require_worktree() {
  _wt_in_worktree \
    || { printf 'error: run this command from inside a worktree, not the base repo\n' >&2; return 1; }
}

# ─────────────────────────────────────────────────────────────────────────────
# Main dispatcher
# ─────────────────────────────────────────────────────────────────────────────
wt() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] && shift

  case "$cmd" in
    *)
      printf '%s\n' \
        "usage: wt <command> [args]" \
        "" \
        "commands:" \
        "  new [branch] [--ai|--no-ai]  create a new worktree" \
        "  ls [--full-path]             list worktrees for this repo" \
        "  cd [branch]                  cd into a worktree (fzf if no arg)" \
        "  del [-f]                     delete current worktree and branch" \
        "  home                         cd to base repository" \
        "  use                          checkout this branch in the base repo" \
        "  extract                      move current branch into a new worktree" \
        "  copy <path> [...]            copy file/dir from base into this worktree" \
        "  link <path> [...]            symlink file/dir from base into this worktree" \
        "  invoke <hook>                manually run a hook" \
        "  clean [--dry-run]            remove merged/prunable worktrees" >&2
      return 1
      ;;
  esac
}
