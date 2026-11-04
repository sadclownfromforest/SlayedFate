#!/usr/bin/env bash
# Install the git guard into a project.
#   ./install.sh /path/to/project            copy hook + settings, append policy to CLAUDE.md
#   ./install.sh /path/to/project --git-hook additionally install a git pre-push hook that always refuses
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
target="${1:?usage: install.sh <project-dir> [--git-hook]}"
[ -d "$target" ] || { echo "no such directory: $target" >&2; exit 1; }
target="$(cd "$target" && pwd)"

mkdir -p "$target/.claude/hooks"
cp "$here/hooks/guard-git.sh" "$target/.claude/hooks/guard-git.sh"
chmod +x "$target/.claude/hooks/guard-git.sh"

if [ -e "$target/.claude/settings.json" ]; then
  if cmp -s "$here/settings.json" "$target/.claude/settings.json"; then
    echo "settings.json already up to date"
  else
    echo "!! $target/.claude/settings.json already exists and differs - not overwritten."
    echo "   Merge the \"permissions\" and \"hooks\" blocks from $here/settings.json by hand."
  fi
else
  cp "$here/settings.json" "$target/.claude/settings.json"
  echo "installed .claude/settings.json"
fi

if [ -f "$target/CLAUDE.md" ]; then
  if ! grep -q '^## Git policy' "$target/CLAUDE.md"; then
    printf '\n' >>"$target/CLAUDE.md"
    cat "$here/CLAUDE.snippet.md" >>"$target/CLAUDE.md"
    echo "appended Git policy to CLAUDE.md"
  fi
else
  cp "$here/CLAUDE.snippet.md" "$target/CLAUDE.md"
  echo "created CLAUDE.md with the Git policy"
fi

if [ "${2:-}" = "--git-hook" ]; then
  if [ -d "$target/.git/hooks" ]; then
    printf '#!/bin/sh\necho "push is disabled in this clone (pre-push hook)" >&2\nexit 1\n' >"$target/.git/hooks/pre-push"
    chmod +x "$target/.git/hooks/pre-push"
    echo "installed .git/hooks/pre-push (refuses every push from this clone, also yours)"
  else
    echo "$target is not a git repository - skipped --git-hook"
  fi
fi

echo "done. Verify with: $here/test.sh \"$target/.claude/hooks/guard-git.sh\""
