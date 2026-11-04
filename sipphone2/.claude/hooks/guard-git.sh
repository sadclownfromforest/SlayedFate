#!/usr/bin/env bash
# Claude Code PreToolUse guard.
#   * DENY  every way of pushing to a remote (git push & friends, gh pr create/merge, GitHub MCP writes,
#           scripts/Makefiles that contain a push, aliases for push)
#   * DENY  tampering with this guard (.claude/settings*, .claude/hooks, .git/hooks)
#   * ASK   before anything that creates a commit (commit, merge, cherry-pick, revert, am, rebase, pull)
#
# Reads the hook JSON on stdin and matches on the raw text, so it needs no jq/python.
# This is a guard rail against an agent, not a sandbox: see README.md for hardening.
set -u
set -f # no globbing while we split words below

input="$(cat)"
# JSON escapes like \n and \t glue words together ("...sh\ngit push"); treat them as spaces for matching
norm="$(printf '%s' "$input" | sed 's/\\[ntr]/ /g')"

deny() {
  printf 'BLOCKED by guard-git: %s\n' "$1" >&2
  printf 'Pushing is disabled for the agent. Tell the user what you would push and let them do it.\n' >&2
  exit 2
}

ask() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$1"
  exit 0
}

tool="$(printf '%s' "$input" | sed -n 's/.*"tool_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"

# ---- building blocks -------------------------------------------------------
Q="[\"'\\\\]" # quote-ish characters that may wrap or split a word
GIT="(^|[^[:alnum:]_.-])g${Q}*i${Q}*t"
OPT_C="[[:space:]]+-[Cc][[:space:]]+(\\\\\"[^\"]*\\\\\"|'[^']*'|[^[:space:]]+)"
OPT_LONG="[[:space:]]+--(git-dir|work-tree|namespace|exec-path|super-prefix|config-env)[[:space:]]+[^[:space:]]+"
OPT_ANY="[[:space:]]+--?[^[:space:]]+"
OPTS="(${OPT_C}|${OPT_LONG}|${OPT_ANY})*"
PUSHW="p${Q}*u${Q}*s${Q}*h"
END="([^[:alnum:]_-]|\$)"

PUSH_RE="${GIT}${OPTS}[[:space:]]+${Q}*(${PUSHW}|send-pack|http-push|(subtree|lfs)[[:space:]]+${PUSHW}|svn[[:space:]]+dcommit|p4[[:space:]]+submit)${END}"
COMMIT_RE="${GIT}${OPTS}[[:space:]]+${Q}*(commit-tree|commit|cherry-pick|revert|merge|am|rebase|pull)${END}"
GH_RE="(^|[^[:alnum:]_.-])gh[[:space:]]+(pr[[:space:]]+(create|merge)|repo[[:space:]]+sync|release[[:space:]]+(create|upload)|api[[:space:]]+([^;&|]*[[:space:]])?(-X|--method|-f|-F|--field|--raw-field|--input)([^[:alnum:]]|\$))"
ALIAS_SET_RE="${GIT}[^;&|]*alias\\."
EXEC_PUSH_RE="[\"']git[\"'][[:space:]]*,[[:space:]]*[\"']push"
TAMPER_PATH_RE="\\.claude/(settings|hooks)|guard-git|\\.git/hooks"
TAMPER_VERB_RE="(>|(^|[^[:alnum:]_.-])(tee|mv|rm|cp|dd|ln|install|chmod|chattr|truncate)[[:space:]]|sed[[:space:]]+-[A-Za-z]*i|perl[[:space:]]+-[A-Za-z]*i|python|node[[:space:]]|ruby|awk)"

matches() { printf '%s' "$norm" | grep -Eqi -- "$1"; }
file_has_push() { grep -Eqi -- "$PUSH_RE" "$1" 2>/dev/null || grep -Eqi -- "$EXEC_PUSH_RE" "$1" 2>/dev/null; }

# ---- file edits: protect the guard, refuse scripts that push ----------------
case "$tool" in
Edit | Write | MultiEdit | NotebookEdit)
  if printf '%s' "$input" | grep -Eqi -- "\"(file_path|notebook_path)\"[[:space:]]*:[[:space:]]*\"[^\"]*(\\.claude/(settings[^\"]*|hooks/[^\"]*)|\\.git/hooks/[^\"]*)\""; then
    deny "editing the guard configuration (.claude/settings*, .claude/hooks, .git/hooks) is not allowed"
  fi
  if printf '%s' "$input" | grep -Eqi -- "\"(file_path|notebook_path)\"[[:space:]]*:[[:space:]]*\"[^\"]*(\\.(sh|bash|zsh|mk)|/Makefile|/GNUmakefile|/makefile)\""; then
    if matches "$PUSH_RE" || matches "$EXEC_PUSH_RE"; then
      deny "refusing to write a script or Makefile that contains a git push"
    fi
  fi
  exit 0
  ;;
mcp__*)
  if printf '%s' "$tool" | grep -Eqi -- '(push|create_or_update_file|delete_file|merge_pull_request|create_pull_request|create_branch|fork_repository)'; then
    deny "MCP tool '$tool' can write to a remote repository"
  fi
  exit 0
  ;;
Bash) ;;
*) exit 0 ;;
esac

# ---- Bash ---------------------------------------------------------------------
if matches "$TAMPER_PATH_RE" && matches "$TAMPER_VERB_RE"; then
  deny "this command would modify the guard configuration"
fi

matches "$PUSH_RE" && deny "git push (or an equivalent such as send-pack, lfs push, subtree push) is disabled"
matches "$GH_RE" && deny "gh command that writes to the remote (pr create/merge, api write, release create) is disabled"
matches "$ALIAS_SET_RE" && deny "defining git aliases is disabled because an alias could hide a push"

# existing aliases whose definition mentions push (git p -> push ...)
if command -v git >/dev/null 2>&1; then
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if matches "${GIT}${OPTS}[[:space:]]+${Q}*${name}${END}"; then
      deny "'git $name' is an alias for a push"
    fi
  done < <(git config --get-regexp '^alias\.' 2>/dev/null | grep -Ei 'push' | sed 's/^alias\.\([^[:space:]]*\).*/\1/')
fi

# scripts / Makefiles that are about to run and contain a push
cmd="$(printf '%s' "$norm" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' | head -c 20000 | tr '",:{}' '     ')"
root="${CLAUDE_PROJECT_DIR:-$PWD}"
for w in $cmd; do
  w="${w//[\\\"\';|&()<>]/}"
  [ -n "$w" ] || continue
  case "$w" in
  *.sh | *.bash | *.zsh | *.ksh | *.mk | *.py | *.js | *.rb | *.pl | ./*)
    for f in "$w" "$root/$w"; do
      if [ -f "$f" ] && [ "$(wc -c <"$f")" -lt 1048576 ] && file_has_push "$f"; then
        deny "script '$w' contains a git push"
      fi
    done
    ;;
  make | gmake | just | npm | yarn | pnpm)
    for f in Makefile makefile GNUmakefile justfile package.json "$root/Makefile" "$root/package.json"; do
      if [ -f "$f" ] && file_has_push "$f"; then
        deny "'$f' contains a git push and '$w' could run it"
      fi
    done
    ;;
  esac
done

# ---- commits need an explicit human yes ---------------------------------------
if matches "$COMMIT_RE"; then
  ask "This command creates or rewrites a commit. Confirm the message and files with the user first."
fi

exit 0
