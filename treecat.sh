#!/usr/bin/env bash
# treecat.sh (portable version)
# Create a snapshot of a directory structure and its file contents.
# Combines a 'tree' view with concatenated file contents, with smart
# filtering, size/line limits, and full OS portability.

set -euo pipefail

VERSION="1.4.0"

usage() {
  cat <<'EOF'
Usage: treecat [OPTIONS] [--] [PATH1 [PATH2 ...]]

Description:
  Creates a comprehensive text snapshot of a project. It combines a
  directory tree view with the content of text files, making it easy to
  share, document, or feed into AI models.

Options:
  -t, --tree                  Print directory tree before file contents.
  -y, --only-tree             Only print the tree (no file contents), respecting bloat exclusions.
  -T, --no-tree               Skip the tree view (default).
  -b, --bloat                 Exclude common bloat (node_modules, .git, build, dist, .venv, target, etc.).
  -i, --include PATTERN       Include only files matching shell PATTERN (can be repeated).
  -x, --exclude PATTERN       Exclude files matching shell PATTERN (can be repeated).
  -n, --no-header             Omit BEGIN/END markers around each file's content.
  -o, --output FILE           Write snapshot to FILE instead of stdout.
      --max-bytes N           Truncate each file after N bytes (per-file limit). 0 = unlimited.
      --max-lines N           Truncate each file after N lines (per-file limit). 0 = unlimited.
      --binary MODE           How to handle non-text files: skip (default) | hex | base64
      --summary               Print an AI-context size summary instead of file contents.
      --tokens                Print token estimates instead of file contents (same output as --summary).
      --follow-symlinks       Follow symlinks when scanning.
      --git                   List files from Git (respects .gitignore); falls back to find if not a repo.
      --no-sort               Do not sort file list; keep discovery order.
      --version               Print version and exit.
  -h, --help                  Show this help and exit.

Notes:
  - Pattern matching uses shell globs against relative paths (e.g., 'src/**/*.ts', '*/.venv/*').
  - Excludes match directory prefixes as well (e.g., '-x .venv' also excludes '.venv/...').
  - Requires 'tree' for the tree view (install via your package manager).
EOF
}

########################################
# Defaults
show_tree=false
only_tree=false
headers=true
exclude_bloat=false
follow_symlinks=false
use_git=false
no_sort=false
max_bytes=0
max_lines=0
binary_mode="skip" # skip|hex|base64
summary_mode=false

declare -a includes=()
declare -a excludes=()
output=""
declare -a search_dirs=()

die() {
  echo "Error: $*" >&2
  exit 1
}

need_arg() {
  local opt="$1"
  local value="${2-}"
  [[ -n "$value" && "$value" != -* ]] || die "$opt requires an argument"
}

is_nonnegative_int() {
  [[ ${1-} =~ ^[0-9]+$ ]]
}

########################################
# Parse options
while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -t|--tree)              show_tree=true; shift ;;
    -y|--only-tree)         only_tree=true; shift ;;
    -T|--no-tree)           show_tree=false; shift ;;
    -b|--bloat)             exclude_bloat=true; shift ;;
    -i|--include)           need_arg "$1" "${2-}"; includes+=("$2"); shift 2 ;;
    -x|--exclude)           need_arg "$1" "${2-}"; excludes+=("$2"); shift 2 ;;
    -n|--no-header)         headers=false; shift ;;
    -o|--output)            need_arg "$1" "${2-}"; output="$2"; shift 2 ;;
        --max-bytes)        need_arg "$1" "${2-}"; max_bytes="$2"; shift 2 ;;
        --max-lines)        need_arg "$1" "${2-}"; max_lines="$2"; shift 2 ;;
        --binary)           need_arg "$1" "${2-}"; binary_mode="$2"; shift 2 ;;
        --summary|--tokens) summary_mode=true; shift ;;
        --follow-symlinks)  follow_symlinks=true; shift ;;
        --git)              use_git=true; shift ;;
        --no-sort)          no_sort=true; shift ;;
        --version)          echo "$VERSION"; exit 0 ;;
    -h|--help)              usage; exit 0 ;;
    --)                     shift; search_dirs+=("$@"); break ;;
    -*)                     echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)                      search_dirs+=("$1"); shift ;;
  esac
done
[[ ${#search_dirs[@]} -eq 0 ]] && search_dirs=(".")

is_nonnegative_int "$max_bytes" || die "--max-bytes must be a non-negative integer"
is_nonnegative_int "$max_lines" || die "--max-lines must be a non-negative integer"
case "$binary_mode" in
  skip|hex|base64) ;;
  *) die "--binary must be one of: skip, hex, base64" ;;
esac

# Redirect output early
if [[ -n "$output" ]]; then
  exec >"$output"
fi

########################################
# Define bloat patterns
# Patterns are bash globs evaluated against relative paths like 'src/file.js'.
declare -a bloat_patterns=()
if [[ "$exclude_bloat" == true ]]; then
  bloat_patterns=(
    # General
    '.git' '.DS_Store' 'logs' 'tmp'

    # IDEs & Editors
    '.idea' '.vscode' '*.sublime-project' '*.sublime-workspace'

    # Build & Cache Outputs
    'build' 'dist' 'out' 'coverage' '.next' '__pycache__'

    # Dependencies
    'node_modules' 'vendor'

    # Language & Framework Specific
    'target' '.venv' 'venv' 'env' '.pytest_cache' '.mypy_cache' '.gradle' 'bin' 'obj' '*.tfstate*' '.terraform'

    # Sensitive Files
    '.env*' '*.env'
  )
fi

########################################
# Helpers
is_text_like() {
  local f="$1"
  case "$f" in
    *.txt|*.md|*.markdown|*.rst|*.adoc|*.py|*.js|*.jsx|*.ts|*.tsx|*.mjs|*.cjs|*.go|*.rs|*.c|*.cc|*.cpp|*.h|*.hh|*.hpp|*.java|*.kt|*.kts|*.rb|*.php|*.sh|*.bash|*.zsh|*.fish|*.ps1|*.json|*.jsonc|*.xml|*.yaml|*.yml|*.toml|*.ini|*.conf|*.config|*.log|*.csv|*.tsv|*.sql|*.html|*.htm|*.css|*.scss|*.sass|*.less|*.vue|*.svelte|*.swift|*.m|*.mm|*.pl|*.pm|*.r|*.R|*.lua|*.ex|*.exs|*.erl|*.hrl|*.clj|*.cljs|*.edn|*.fs|*.fsx|*.fsi|*.ml|*.mli|*.nim|*.zig|*.dockerfile|Dockerfile|Makefile|makefile|GNUmakefile|*.mk|*.gradle|*.properties|*.env|*.gitignore|*.gitattributes|*.editorconfig)
      return 0 ;;
  esac

  # Check if file command exists
  if ! command -v file >/dev/null 2>&1; then
    # Fallback: check common text extensions
    case "$f" in
      *.txt|*.md|*.py|*.js|*.ts|*.go|*.rs|*.c|*.cpp|*.h|*.hpp|*.java|*.rb|*.sh|*.bash|*.zsh|*.fish|*.json|*.xml|*.yaml|*.yml|*.toml|*.ini|*.conf|*.config|*.log|*.csv|*.sql|*.html|*.css|*.scss|*.sass|*.less)
        return 0 ;;
      *)
        # Try to detect binary content by checking for null bytes in first 512 bytes
        if head -c 512 "$f" 2>/dev/null | grep -q $'\x00'; then
          return 1
        else
          return 0
        fi ;;
    esac
  else
    local mt
    mt=$(file -b --mime-type -- "$f" 2>/dev/null || true)
    [[ $mt == text/* || $mt == application/json || $mt == application/xml || $mt == application/javascript || $mt == application/x-shellscript || $mt == application/x-empty ]] && return 0 || return 1
  fi
}

print_tree() {
  if command -v tree >/dev/null 2>&1; then
    local tree_opts=(-a)
    local tree_files=()
    local target parent base

    # Merge bloat + user excludes for the tree ignore list
    local tree_ignores=()
    if [[ ${#bloat_patterns[@]} -gt 0 ]]; then
      tree_ignores+=("${bloat_patterns[@]}")
    fi
    if [[ ${#excludes[@]} -gt 0 ]]; then
      tree_ignores+=("${excludes[@]}")
    fi

    if [[ ${#tree_ignores[@]} -gt 0 ]]; then
      # Convert to alternation for `tree -I`
      local ignore_pattern
      ignore_pattern=$(printf "|%s" "${tree_ignores[@]}")
      ignore_pattern=${ignore_pattern:1}
      tree_opts+=(-I "$ignore_pattern")
    fi

    echo "### Directory structure (generated by treecat on $(date +%Y-%m-%d\ %H:%M:%S))"
    for target in "${search_dirs[@]}"; do
      if [[ -d "$target" ]]; then
        if [[ "$target" == /* ]]; then
          parent=$(dirname -- "$target")
          base=$(basename -- "$target")
          (cd -- "$parent" && tree "${tree_opts[@]}" "$base")
        else
          tree "${tree_opts[@]}" "$target"
        fi
      elif [[ -f "$target" ]]; then
        tree_files+=("$(path_for_matching "$target")")
      fi
    done

    if [[ ${#tree_files[@]} -gt 0 ]]; then
      printf '%s\n' "${tree_files[@]}"
      if [[ ${#tree_files[@]} -eq 1 ]]; then
        printf '\n0 directories, 1 file\n'
      else
        printf '\n0 directories, %d files\n' "${#tree_files[@]}"
      fi
    fi
    echo
  else
    echo "WARNING: 'tree' command not found; skipping directory tree view." >&2
    echo "         On macOS: brew install tree" >&2
    echo "         On Debian/Ubuntu: sudo apt-get install -y tree" >&2
    echo "         On RHEL/CentOS: sudo yum install -y tree" >&2
    echo "         On Alpine: apk add tree" >&2
  fi
}

get_size_bytes() {
  # Cross-platform file size in bytes (Linux/BSD/macOS)
  local f="$1"
  if stat -f%z "$f" >/dev/null 2>&1; then
    # BSD/macOS style
    stat -f%z "$f"
  else
    # GNU/Linux style
    stat -c%s "$f" 2>/dev/null || stat --format=%s "$f"
  fi
}

count_lines() {
  local f="$1"
  wc -l < "$f" | tr -d '[:space:]'
}

estimate_tokens() {
  local bytes="$1"
  printf '%d\n' $(( (bytes + 3) / 4 ))
}

text_emitted_bytes() {
  local f="$1"
  local size
  size=$(get_size_bytes "$f")
  if (( max_bytes > 0 )); then
    if (( size < max_bytes )); then
      printf '%d\n' "$size"
    else
      printf '%d\n' "$max_bytes"
    fi
  elif (( max_lines > 0 )); then
    head -n "$max_lines" "$f" | wc -c | tr -d '[:space:]'
  else
    printf '%d\n' "$size"
  fi
}

text_emitted_lines() {
  local f="$1"
  local lines
  if (( max_bytes > 0 )); then
    dd if="$f" bs=1 count="$max_bytes" 2>/dev/null | wc -l | tr -d '[:space:]'
  else
    lines=$(count_lines "$f")
    if (( max_lines > 0 && lines > max_lines )); then
      printf '%d\n' "$max_lines"
    else
      printf '%d\n' "$lines"
    fi
  fi
}

binary_emitted_bytes() {
  local f="$1"
  local size
  size=$(get_size_bytes "$f")
  case "$binary_mode" in
    hex) printf '%d\n' $(( size * 2 )) ;;
    base64) printf '%d\n' $(( ((size + 2) / 3) * 4 )) ;;
    *) printf '%d\n' 0 ;;
  esac
}

print_file_with_limits() {
  local f="$1"
  local label="${2:-$f}"
  if [[ "$headers" == true ]]; then
    printf '\n===== BEGIN %s =====\n' "$label"
  fi

  if (( max_bytes > 0 )); then
    # Print up to max_bytes safely (dd is POSIX)
    dd if="$f" bs=1 count="$max_bytes" 2>/dev/null || head -c "$max_bytes" "$f"
  elif (( max_lines > 0 )); then
    # Use head instead of awk for better portability
    head -n "$max_lines" "$f"
  else
    cat -- "$f"
  fi

  if [[ "$headers" == true ]]; then
    printf '\n===== END %s =====\n' "$label"
  fi
}

should_skip_by_patterns() {
  # $1: relative path
  local p="$1"; shift
  local -a pats=("$@")
  local pat
  for pat in "${pats[@]}"; do
    # Match exact
    # shellcheck disable=SC2053 # Intentional glob matching for user-supplied patterns.
    [[ $p == $pat ]] && return 0
    # Match as directory prefix (treat bare names as prefixes too)
    [[ $p == $pat/* ]] && return 0
    # If the pattern has no slash, allow matching anywhere in the path
    if [[ $pat != */* ]]; then
      [[ $p == */$pat || $p == */$pat/* ]] && return 0
    fi
    # Plain glob match already covered by [[ $p == $pat ]]
  done
  return 1
}

# Portable array reading function (replaces mapfile)
read_array_from_pipe() {
  local -n arr=$1  # nameref to the array variable
  local line
  arr=()  # Clear the array
  while IFS= read -r line; do
    arr+=("$line")
  done
}

path_for_matching() {
  local f="$1"
  local d abs_d abs_file base parent cwd

  case "$f" in
    ./*) f="${f#./}" ;;
  esac

  if [[ "$f" != /* ]]; then
    printf '%s\n' "$f"
    return
  fi

  for d in "${search_dirs[@]}"; do
    if [[ -d "$d" ]]; then
      abs_d=$(cd -- "$d" 2>/dev/null && pwd -P) || continue
      if [[ "$f" == "$abs_d"/* ]]; then
        printf '%s\n' "${f#"$abs_d"/}"
        return
      fi
    elif [[ -f "$d" ]]; then
      base=$(basename -- "$d")
      parent=$(dirname -- "$d")
      abs_file="$(cd -- "$parent" 2>/dev/null && pwd -P)/$base" || continue
      if [[ "$f" == "$abs_file" ]]; then
        printf '%s\n' "$base"
        return
      fi
    fi
  done

  cwd=$(pwd -P)
  if [[ "$f" == "$cwd"/* ]]; then
    printf '%s\n' "${f#"$cwd"/}"
  else
    printf '%s\n' "$f"
  fi
}

########################################
# (1) Directory tree
if [[ "$show_tree" == true || "$only_tree" == true ]]; then
  print_tree
  [[ "$only_tree" == true ]] && exit 0
fi

########################################
# (2) Build raw file list
raw_files=()

if [[ "$use_git" == true ]] && command -v git >/dev/null 2>&1; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Use git ls-files to respect .gitignore and include submodules
    while IFS= read -r -d '' f; do 
      raw_files+=("$f")
    done < <(git ls-files -z --recurse-submodules -- "${search_dirs[@]}" 2>/dev/null || true)
  fi
fi

if [[ ${#raw_files[@]} -eq 0 ]]; then
  # Fallback to find
  # Build find options
  find_cmd=(find)
  $follow_symlinks && find_cmd+=(-L)
  find_cmd+=("${search_dirs[@]}")

  # Prune bloat early for performance (best effort)
  if [[ ${#bloat_patterns[@]} -gt 0 ]]; then
    find_cmd+=(\()
    for pat in "${bloat_patterns[@]}"; do
      find_cmd+=(-path "*/$pat" -o -name "$pat" -o)
    done
    unset 'find_cmd[${#find_cmd[@]}-1]'
    find_cmd+=(\) -prune -o)
  fi

  find_cmd+=(-type f -print0)

  while IFS= read -r -d '' f; do 
    raw_files+=("$f")
  done < <("${find_cmd[@]}" 2>/dev/null)
fi

# Build sortable entries as: match-path<TAB>file-path
file_entries=()
for f in "${raw_files[@]}"; do
  match_path=$(path_for_matching "$f")
  case "$f" in
    ./*) file_entries+=("$match_path"$'\t'"${f#./}") ;;
    *)   file_entries+=("$match_path"$'\t'"$f") ;;
  esac
done

# Sort if requested (portable replacement for mapfile)
if [[ "$no_sort" == false ]]; then
  # Create temporary array for sorted files
  sorted_entries=()
  while IFS= read -r line; do
    sorted_entries+=("$line")
  done < <(printf '%s\n' "${file_entries[@]}" | LC_ALL=C sort)
  file_entries=("${sorted_entries[@]}")
fi

########################################
# (3) Apply include/exclude patterns
files=()
for entry in "${file_entries[@]}"; do
  match_path="${entry%%$'\t'*}"
  file_path="${entry#*$'\t'}"
  # Bloat exclusions
  if (( ${#bloat_patterns[@]} )); then
    if should_skip_by_patterns "$match_path" "${bloat_patterns[@]}"; then
      continue
    fi
  fi
  # User excludes
  if (( ${#excludes[@]} )); then
    if should_skip_by_patterns "$match_path" "${excludes[@]}"; then
      continue
    fi
  fi
  # User includes (if any, must match)
  if (( ${#includes[@]} )); then
    if ! should_skip_by_patterns "$match_path" "${includes[@]}"; then
      continue
    fi
  fi
  files+=("$file_path"$'\t'"$match_path")
done

print_summary() {
  local entry p label kind bytes lines tokens
  local text_files=0
  local binary_files=0
  local binary_skipped=0
  local skipped=0
  local total_files=0
  local total_bytes=0
  local total_lines=0
  local total_tokens=0

  echo "### AI context summary"
  echo
  printf '%-8s %-10s %10s %10s %10s  %s\n' "Kind" "Status" "Bytes" "Lines" "Tokens" "Path"
  printf '%-8s %-10s %10s %10s %10s  %s\n' "--------" "----------" "----------" "----------" "----------" "----"

  for entry in "${files[@]}"; do
    p="${entry%%$'\t'*}"
    label="${entry#*$'\t'}"

    if [[ ! -f "$p" || ! -s "$p" ]]; then
      ((skipped += 1))
      continue
    fi

    if is_text_like "$p"; then
      kind="text"
      bytes=$(text_emitted_bytes "$p")
      lines=$(text_emitted_lines "$p")
      tokens=$(estimate_tokens "$bytes")
      ((text_files += 1))
      ((total_files += 1))
      ((total_bytes += bytes))
      ((total_lines += lines))
      ((total_tokens += tokens))
      printf '%-8s %-10s %10d %10d %10d  %s\n' "$kind" "included" "$bytes" "$lines" "$tokens" "$label"
    else
      if [[ "$binary_mode" == "skip" ]]; then
        ((binary_skipped += 1))
        printf '%-8s %-10s %10s %10s %10s  %s\n' "binary" "skipped" "-" "-" "-" "$label"
      else
        kind="binary"
        bytes=$(binary_emitted_bytes "$p")
        lines=0
        tokens=$(estimate_tokens "$bytes")
        ((binary_files += 1))
        ((total_files += 1))
        ((total_bytes += bytes))
        ((total_tokens += tokens))
        printf '%-8s %-10s %10d %10d %10d  %s\n' "$kind" "$binary_mode" "$bytes" "$lines" "$tokens" "$label"
      fi
    fi
  done

  echo
  echo "Files included: $total_files"
  echo "Text files: $text_files"
  echo "Binary files included: $binary_files"
  echo "Binary files skipped: $binary_skipped"
  echo "Empty/missing files skipped: $skipped"
  echo "Estimated emitted bytes: $total_bytes"
  echo "Estimated emitted lines: $total_lines"
  echo "Estimated tokens: $total_tokens"
  echo
  echo "Token estimate uses a rough 4 bytes/token heuristic."
}

if [[ "$summary_mode" == true ]]; then
  print_summary
  exit 0
fi

########################################
# (4) Output file contents
for entry in "${files[@]}"; do
  p="${entry%%$'\t'*}"
  label="${entry#*$'\t'}"
  # Skip if file doesn't exist or is empty
  [[ -f "$p" ]] || continue
  [[ -s "$p" ]] || continue

  if is_text_like "$p"; then
    print_file_with_limits "$p" "$label"
  else
    case "$binary_mode" in
      skip)   ;; # do nothing
      hex)
        if command -v xxd >/dev/null 2>&1; then
          if [[ "$headers" == true ]]; then printf '\n===== BEGIN %s (hex) =====\n' "$label"; fi
          xxd -p -c 16 -- "$p"
          if [[ "$headers" == true ]]; then printf '\n===== END %s (hex) =====\n' "$label"; fi
        elif command -v hexdump >/dev/null 2>&1; then
          if [[ "$headers" == true ]]; then printf '\n===== BEGIN %s (hex) =====\n' "$label"; fi
          hexdump -C "$p"
          if [[ "$headers" == true ]]; then printf '\n===== END %s (hex) =====\n' "$label"; fi
        else
          echo "WARNING: Neither xxd nor hexdump found for hex output" >&2
        fi
        ;;
      base64)
        if command -v base64 >/dev/null 2>&1; then
          if [[ "$headers" == true ]]; then printf '\n===== BEGIN %s (base64) =====\n' "$label"; fi
          base64 -- "$p" 2>/dev/null || base64 "$p"  # Some versions don't support --
          if [[ "$headers" == true ]]; then printf '\n===== END %s (base64) =====\n' "$label"; fi
        else
          echo "WARNING: base64 command not found" >&2
        fi
        ;;
      *) echo "Unknown --binary mode: $binary_mode" >&2; exit 1 ;;
    esac
  fi
done
