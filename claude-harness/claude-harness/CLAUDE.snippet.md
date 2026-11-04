## Git policy (enforced by .claude/hooks/guard-git.sh)

* **Never push.** No `git push`, `gh pr create/merge`, remote-writing `gh api`, GitHub MCP writes, or scripts that do it.
  A hook blocks these; do not try to work around it (aliases, scripts, editing `.claude/` or `.git/hooks`).
  When work is ready, tell the user which branch/commits exist and let them push.
* **Always ask before committing.** Before any `git commit` (also merge, cherry-pick, revert, am, rebase, pull) call
  `AskUserQuestion` with the proposed commit message and the list of files, and commit only after an explicit yes.
  The hook additionally forces a permission prompt for these commands.
* Never commit secrets (`accounts.json`, `.env*`, keys). Stage files explicitly, not `git add -A`.
