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
# wt ls
# ─────────────────────────────────────────────────────────────────────────────
_wt_ls() {
  _wt_require_git || return 1

  local full_path=0
  [[ "${1:-}" == "--full-path" ]] && full_path=1

  local current_real
  current_real="$(realpath "$(pwd)" 2>/dev/null || pwd)"

  local worktree_path is_first=1

  while IFS= read -r line; do
    if [[ "$line" == "worktree "* ]]; then
      worktree_path="${line#worktree }"
    elif [[ -z "$line" && -n "$worktree_path" ]]; then
      local wt_real marker="" display

      wt_real="$(realpath "$worktree_path" 2>/dev/null || printf '%s' "$worktree_path")"

      if [[ "$wt_real" == "$current_real" ]]; then
        if (( is_first )); then
          marker=" [base]"
        else
          marker=" *"
        fi
      fi

      if (( full_path )); then
        printf '%s%s\n' "$worktree_path" "$marker"
      else
        display="$(basename "$worktree_path")"
        [[ "$display" == *@* ]] && display="${display#*@}"
        printf '%s%s\n' "$display" "$marker"
      fi

      is_first=0
      worktree_path=""
    fi
  done < <(git worktree list --porcelain)
}

# ─────────────────────────────────────────────────────────────────────────────
# wt new
# ─────────────────────────────────────────────────────────────────────────────
_wt_new() {
  _wt_require_git || return 1

  local branch=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ai|--no-ai) ;;  # handled in Phase 3
      -*)  printf 'error: unknown option: %s\n' "$1" >&2; return 1 ;;
      *)
        if [[ -z "$branch" ]]; then
          branch="$1"
        else
          printf 'error: unexpected argument: %s\n' "$1" >&2; return 1
        fi
        ;;
    esac
    shift
  done

  [[ -z "$branch" ]] && branch="wip-$RANDOM"

  # Validate branch name
  git check-ref-format --branch "$branch" > /dev/null 2>&1 \
    || { printf 'error: invalid branch name: %s\n' "$branch" >&2; return 1; }

  local dir_branch
  dir_branch="$(_wt_branch_to_dir "$branch")"

  local base_root
  base_root="$(_wt_base)" || return 1

  local wt_path
  wt_path="$(dirname "$base_root")/$(basename "$base_root")@${dir_branch}"

  # Conflict checks
  if [[ -e "$wt_path" ]]; then
    printf 'error: path already exists: %s\n' "$wt_path" >&2; return 1
  fi
  if git rev-parse --verify "$branch" > /dev/null 2>&1; then
    printf 'error: branch already exists: %s\n' "$branch" >&2; return 1
  fi

  git worktree add "$wt_path" -b "$branch" || return 1
  printf '✓ worktree created: %s\n' "$wt_path"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main dispatcher
# ─────────────────────────────────────────────────────────────────────────────
wt() {
  local cmd="${1:-}"
  [[ -n "$cmd" ]] && shift

  case "$cmd" in
    new)     _wt_new     "$@" ;;
    ls)      _wt_ls      "$@" ;;
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
