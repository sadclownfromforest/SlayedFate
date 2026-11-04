#!/usr/bin/env bash
# Self-test for hooks/guard-git.sh. Usage: ./test.sh [path/to/guard-git.sh]
set -u
HOOK="${1:-$(dirname "$0")/hooks/guard-git.sh}"
HOOK="$(cd "$(dirname "$HOOK")" && pwd)/$(basename "$HOOK")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work" || exit 1
git init -q . 2>/dev/null
git config alias.p 'push origin' 2>/dev/null
git config alias.st 'status' 2>/dev/null
printf '#!/bin/sh\necho build\ngit push origin main\n' >release.sh
printf 'ok:\n\tgit -C . push\n' >Makefile.bad
printf '#!/bin/sh\necho hello\n' >fine.sh
export CLAUDE_PROJECT_DIR="$work"

pass=0
fail=0

run() { # run <json> -> sets $rc and $out
  out="$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)"
  rc=$?
}
bash_json() { printf '{"session_id":"s","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"%s","description":"d"}}' "$1"; }
file_json() { printf '{"tool_name":"%s","tool_input":{"file_path":"%s","content":"%s"}}' "$1" "$2" "$3"; }

check() { # check <expect: deny|ask|allow> <label> <json>
  run "$3"
  local got=allow
  if [ "$rc" = 2 ]; then got=deny; elif printf '%s' "$out" | grep -q '"permissionDecision":"ask"'; then got=ask; fi
  if [ "$got" = "$1" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL expected %-5s got %-5s : %s\n' "$1" "$got" "$2"
  fi
}

# ---- must be DENIED
for c in \
  'git push' 'git push origin main' 'git push --force-with-lease' 'git  push' \
  'git -C /tmp/x push' 'git -c user.name=a push origin' 'git --no-pager push' 'git --git-dir=.git push' \
  'git -C \"my dir\" push' "git -C 'my dir' push" '/usr/bin/git push' 'cd x && git push' 'echo hi; git push' \
  'true | git push' "bash -c 'git push'" 'sh -c \"git push origin\"' 'git \"push\"' "g''it push" "git pu''sh" \
  'git send-pack origin' 'git http-push x' 'git lfs push origin main' 'git subtree push --prefix=a b c' \
  'git svn dcommit' 'gh pr create --fill' 'gh pr merge 3' 'gh api -X POST repos/o/r/git/refs' \
  'gh api repos/o/r/contents/a -f message=x' 'gh release create v1' \
  'git config alias.pp push' 'git -c alias.x=push x' 'git p' 'git -C . p origin' \
  'bash release.sh' 'sh ./release.sh' 'source release.sh' './release.sh' \
  'sed -i s/a/b/ .claude/hooks/guard-git.sh' 'rm .claude/settings.json' 'echo x > .claude/settings.json' \
  'chmod -x .claude/hooks/guard-git.sh' 'rm .git/hooks/pre-push'; do
  check deny "$c" "$(bash_json "$c")"
done
mv Makefile.bad Makefile
check deny "make (Makefile contains push)" "$(bash_json 'make deploy')"
rm Makefile

check deny "Write release.sh with push" "$(file_json Write /x/release.sh '#!/bin/sh\ngit push origin main\n')"
check deny "Write Makefile with push" "$(file_json Write /x/Makefile 'deploy:\n\tgit push\n')"
check deny "Edit .claude/settings.json" "$(file_json Edit /p/.claude/settings.json 'x')"
check deny "Write .claude/hooks/guard-git.sh" "$(file_json Write /p/.claude/hooks/guard-git.sh 'exit 0')"
check deny "Write .git/hooks/pre-commit" "$(file_json Write /p/.git/hooks/pre-commit 'x')"
check deny "MCP push_files" '{"tool_name":"mcp__github__push_files","tool_input":{}}'
check deny "MCP create_or_update_file" '{"tool_name":"mcp__github__create_or_update_file","tool_input":{}}'

# ---- must ASK
for c in \
  'git commit -m x' 'git commit' 'git -C . commit -m x' 'git -c user.name=a commit -m x' 'git commit --amend' \
  'git add -A && git commit -m x' '/usr/bin/git commit -m x' 'git merge dev' 'git cherry-pick abc' 'git revert HEAD' \
  'git commit-tree HEAD^{tree}' 'git am x.patch' 'git rebase main' 'git pull' "bash -c 'git commit -m x'"; do
  check ask "$c" "$(bash_json "$c")"
done

# ---- must be ALLOWED
for c in \
  'git status' 'git log --oneline -5' 'git log -S push' 'git log --grep=push' 'git diff' 'git add -A' 'git checkout -b x' \
  'git stash' 'git branch -m push-fix' 'git remote -v' 'git fetch' 'git st' 'echo pushing the limits' 'make test' \
  'ls -la' 'bash fine.sh' 'docker build -t x .' 'mix test' 'gh pr view 3' 'gh api repos/o/r' 'cat .claude/settings.json' \
  'git status && echo push' 'git show HEAD' 'git diff --stat'; do
  check allow "$c" "$(bash_json "$c")"
done
check allow "Write README mentioning push" "$(file_json Write /x/README.md 'Never git push here.')"
check allow "Write fine.sh" "$(file_json Write /x/fine.sh '#!/bin/sh\necho hi\n')"
check allow "Edit lib file" "$(file_json Edit /x/lib/a.ex 'x')"
check allow "Read tool" '{"tool_name":"Read","tool_input":{"file_path":"/x/y"}}'
check allow "MCP read tool" '{"tool_name":"mcp__github__get_file_contents","tool_input":{}}'

printf '\nguard-git self-test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
