#!/usr/bin/env bash
# Symlink every skill in this repo (any top-level dir containing SKILL.md)
# into ~/.cursor/skills. Symlinks track repo edits automatically; re-run
# this script when skills are added, removed, or renamed.
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
skills_dir="${HOME}/.cursor/skills"

mkdir -p "$skills_dir"

# Remove stale/broken symlinks that point into this repo
for link in "$skills_dir"/*; do
  [ -L "$link" ] || continue
  target="$(readlink "$link")"
  case "$target" in
    "$repo_dir"/*)
      if [ ! -f "$target/SKILL.md" ]; then
        rm "$link"
        echo "removed stale: $(basename "$link")"
      fi
      ;;
  esac
done

# Link each skill in the repo
for skill_md in "$repo_dir"/*/SKILL.md; do
  [ -f "$skill_md" ] || continue
  skill_dir="$(dirname "$skill_md")"
  name="$(basename "$skill_dir")"
  dest="$skills_dir/$name"

  if [ -L "$dest" ]; then
    [ "$(readlink "$dest")" = "$skill_dir" ] && { echo "ok: $name"; continue; }
    rm "$dest"
  elif [ -e "$dest" ]; then
    echo "skipped: $name ($dest exists and is not a symlink)" >&2
    continue
  fi

  ln -s "$skill_dir" "$dest"
  echo "linked: $name"
done
