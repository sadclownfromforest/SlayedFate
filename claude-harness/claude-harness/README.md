# Claude Code git guard

A small harness that keeps a Claude Code agent from pushing and makes it ask before committing.
Pure bash (no jq/python), one hook script and one settings file.

| What the agent tries | Result |
|---|---|
| `git push` in any spelling: `git -C dir push`, `/usr/bin/git push`, `git -c k=v push`, `bash -c 'git push'`, `git "push"`, `g''it push`, `send-pack`, `http-push`, `lfs push`, `subtree push`, `svn dcommit` | **blocked** |
| `gh pr create`, `gh pr merge`, `gh release create`, `gh api` with a method/field flag, `gh repo sync` | **blocked** |
| GitHub-style MCP tools (`push_files`, `create_or_update_file`, `merge_pull_request`, `create_branch`...) | **blocked** |
| running a script / Makefile / package.json that contains a push (`bash release.sh`, `./x.sh`, `make deploy`, `npm run ...`) | **blocked** |
| writing a `.sh` / `Makefile` that contains a push | **blocked** |
| git aliases that hide a push (defining one, or using an existing `alias.* = push`) | **blocked** |
| editing the guard itself (`.claude/settings*`, `.claude/hooks`, `.git/hooks`) by tool or by shell | **blocked** |
| `git commit`, `commit-tree`, `merge`, `cherry-pick`, `revert`, `am`, `rebase`, `pull` | **asks you** (permission prompt with a reason) |
| everything else (`git status/diff/log/add/checkout/stash/fetch`, builds, tests) | allowed |

It is layered: `permissions.deny/ask` in `settings.json` (simple forms), the `PreToolUse` hook (the thorough matching),
and a rule in `CLAUDE.md` telling the agent to use `AskUserQuestion` with the message and file list before a commit.

## Install

```sh
./install.sh /path/to/project            # hook + settings + CLAUDE.md policy
./install.sh /path/to/project --git-hook # also a git pre-push hook that refuses every push from this clone
./test.sh /path/to/project/.claude/hooks/guard-git.sh   # 94 allow/ask/deny checks
```

If the project already has `.claude/settings.json`, the installer will not overwrite it - merge the
`permissions` and `hooks` blocks by hand. Then restart Claude Code (or `/hooks` to review) so the hook is loaded.

## Honest limits

This is a guard rail against an agent that makes mistakes or takes shortcuts, **not a sandbox**.
It matches text, so a determined, obfuscated command (decoded payloads, a compiled helper, a script written
by some other tool, a different VCS client) can get past it. Matching is deliberately conservative:
a command that merely *mentions* `git push` (e.g. in an `echo`) is blocked too.

For a hard guarantee, remove the ability instead of detecting the attempt:

```sh
git remote set-url --push origin DISABLED   # pushes now fail in this clone
# and/or work with a clone that has no credentials / only a read-only deploy key
# and/or install the --git-hook pre-push refuser
```

Tip: keep the user's own pushes in a separate terminal/clone with credentials, and give the agent a clone without.

## Files

```
hooks/guard-git.sh   the PreToolUse hook (deny = exit 2 + stderr, ask = JSON permissionDecision)
settings.json        permissions + hook registration (matcher: Bash|Edit|Write|MultiEdit|NotebookEdit|mcp__.*)
CLAUDE.snippet.md    policy text appended to CLAUDE.md
install.sh, test.sh  installer and self-test
```
