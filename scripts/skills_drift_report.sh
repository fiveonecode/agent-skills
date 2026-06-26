#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
projects_root="${PROJECTS_ROOT:-$HOME/Projects}"
check_upstream=0
show_local_paths="${SKILLS_REPORT_SHOW_PATHS:-0}"

if [ "${1:-}" = "--check-upstream" ]; then
  check_upstream=1
elif [ "${1:-}" != "" ]; then
  echo "usage: $0 [--check-upstream]" >&2
  exit 2
fi

count_files() {
  dir="$1"
  depth="$2"
  pattern="$3"
  if [ ! -d "$dir" ]; then
    echo 0
    return
  fi
  find "$dir" -maxdepth "$depth" -name "$pattern" -type f 2>/dev/null | wc -l | tr -d ' '
}

count_files_following_symlinks() {
  dir="$1"
  depth="$2"
  pattern="$3"
  if [ ! -d "$dir" ]; then
    echo 0
    return
  fi
  find -L "$dir" -maxdepth "$depth" -name "$pattern" -type f 2>/dev/null | wc -l | tr -d ' '
}

display_path() {
  path="$1"
  if [ "$show_local_paths" = "1" ]; then
    printf '%s\n' "$path"
    return
  fi
  case "$path" in
    "$HOME"/*)
      printf '~/%s\n' "${path#"$HOME"/}"
      ;;
    "$HOME")
      printf '~\n'
      ;;
    /*)
      printf '<absolute-path>\n'
      ;;
    *)
      printf '%s\n' "$path"
      ;;
  esac
}

repo_skill_entrypoints() {
  root="$1"
  find "$root" -maxdepth 6 -path '*/.agents/skills/*/SKILL.md' -type f -print 2>/dev/null |
    while IFS= read -r file; do
      skill_dir="$(dirname "$file")"
      skills_dir="$(dirname "$skill_dir")"
      agents_dir="$(dirname "$skills_dir")"
      if [ "$(basename "$skills_dir")" = "skills" ] && [ "$(basename "$agents_dir")" = ".agents" ]; then
        printf '%s\n' "$file"
      fi
    done
}

count_symlink_entries() {
  dir="$1"
  if [ ! -d "$dir" ]; then
    echo 0
    return
  fi
  find "$dir" -mindepth 1 -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' '
}

skill_version() {
  file="$1"
  awk '
    /^[[:space:]]*version:/ {
      value=$0
      sub(/^[[:space:]]*version:[[:space:]]*/, "", value)
      gsub(/"/, "", value)
      print value
      found=1
      exit
    }
    END {
      if (!found) {
        print "unknown"
      }
    }
  ' "$file"
}

echo "# Skill Drift Snapshot"
echo
echo "Registry: $(display_path "$repo_root")"
echo "Projects root: $(display_path "$projects_root")"
echo "Registry skill folders: $(count_files "$repo_root" 2 SKILL.md)"
echo

echo "## Consumer Roots"
for root in "$HOME/.codex/skills" "$HOME/.agents/skills" "$HOME/.claude/skills"; do
  if [ -d "$root" ]; then
    echo "- $(display_path "$root"): $(count_files_following_symlinks "$root" 2 SKILL.md) SKILL.md files, $(count_symlink_entries "$root") symlink entries"
  else
    echo "- $(display_path "$root"): missing"
  fi
done
echo

echo "## Repo-Local Skill Entry Points"
if [ -d "$projects_root" ]; then
  repo_skill_entrypoints "$projects_root" |
    wc -l | tr -d ' ' | sed 's/^/- total: /'
  echo "- top repeated skill names:"
  repo_skill_entrypoints "$projects_root" |
    sed 's|.*/.agents/skills/||; s|/SKILL.md||' |
    sort | uniq -c | sort -nr | head -20 |
    sed 's/^/  /'
else
  echo "- missing projects root"
fi
echo

echo "## Known Adapter Checks"
adapter="$HOME/.codex/skills/code-review"
if [ -L "$adapter" ]; then
  target="$(readlink "$adapter" 2>/dev/null || true)"
  if [ -n "$target" ] && [ -e "$adapter" ]; then
    echo "- $(display_path "$adapter") -> $(display_path "$target")"
  elif [ -n "$target" ]; then
    echo "- $(display_path "$adapter") -> $(display_path "$target") (broken)"
  else
    echo "- $(display_path "$adapter"): broken symlink"
  fi
elif [ -e "$adapter" ]; then
  echo "- $(display_path "$adapter"): exists but is not a symlink"
else
  echo "- ~/.codex/skills/code-review: missing"
fi
echo

echo "## swiftui-pro Copies"
if [ -d "$projects_root" ]; then
  swiftui_files="$(repo_skill_entrypoints "$projects_root" | grep '/\.agents/skills/swiftui-pro/SKILL\.md$' | sort || true)"
  if [ -z "$swiftui_files" ]; then
    echo "- no repo-local swiftui-pro copies found"
  else
    copy_index=0
    printf '%s\n' "$swiftui_files" | while IFS= read -r file; do
      copy_index=$((copy_index + 1))
      if [ "$show_local_paths" = "1" ]; then
        echo "- $(display_path "$file"): version $(skill_version "$file")"
      else
        echo "- repo-local copy $copy_index: version $(skill_version "$file")"
      fi
    done
    if [ "$show_local_paths" != "1" ]; then
      echo "- paths hidden; set SKILLS_REPORT_SHOW_PATHS=1 to print local paths"
    fi
  fi
fi
echo

if [ "$check_upstream" -eq 1 ]; then
  echo "## Upstream swiftui-pro Tags"
  git ls-remote --tags https://github.com/twostraws/SwiftUI-Agent-Skill.git |
    sed 's/^/- /'
else
  echo "## Upstream Checks"
  echo "- skipped; rerun with --check-upstream to make network calls"
fi
