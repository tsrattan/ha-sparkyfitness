#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'HELP'
Usage: ./scripts/release-git.sh [--dry-run] [--backup PATH] [--message MESSAGE]

Runs fresh-install and upgrade validation, then optionally commits and pushes.
  --dry-run          Run both tests and show intended Git changes; no commit/push
  --backup PATH      Pre-upgrade SparkyFitness backup archive
  --message MESSAGE  Git commit message (prompted if omitted)
  --help             Show this help

Only explicitly listed project paths are staged. No git add -A.
HELP
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
confirm() {
  local response
  read -r -p "$1 [y/N] " response
  [[ "$response" == [yY] || "$response" == [yY][eE][sS] ]]
}

dry_run=0
backup="${SPARKYFITNESS_UPGRADE_BACKUP:-$HOME/docker/sparkyfitness-backups/sparkyfitness-20261017-180410.tar.gz}"
message=""
while (($#)); do
  case "$1" in
    --dry-run) dry_run=1; shift ;;
    --backup) (($# >= 2)) || die '--backup requires a path'; backup=$2; shift 2 ;;
    --message) (($# >= 2)) || die '--message requires text'; message=$2; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

repo="$(git rev-parse --show-toplevel 2>/dev/null)" || die 'Run inside a Git repository'
cd "$repo"
[[ -x scripts/test-upgrade.sh ]] || die 'scripts/test-upgrade.sh is missing or not executable'
[[ -f "$backup" ]] || die "Backup not found: $backup"
[[ "$backup" == *.tar.gz ]] || die 'Backup must be a .tar.gz file'
[[ "$(git branch --show-current)" == main ]] || die 'Release from main branch only'
[[ -z "$(git diff --cached --name-only)" ]] || die 'Index already has staged changes; unstage/review first'

printf '\n=== Fresh-install validation ===\n'
./scripts/test-upgrade.sh --fresh
printf '\n=== Upgrade validation ===\n'
./scripts/test-upgrade.sh --upgrade "$backup"
printf '\nBoth validation commands succeeded.\n'

# Explicit allowlist: extend deliberately as the repository evolves.
paths=(.gitignore README.md repository.yaml scripts/test-upgrade.sh scripts/release-git.sh sparkyfitness)
printf '\n=== Proposed changes (allowlisted project files only) ===\n'
git status --short -- "${paths[@]}"
printf '\n=== Existing tracked changes outside allowlist ===\n'
git status --short -- . ':!/.gitignore' ':!/README.md' ':!/repository.yaml' ':!/scripts/test-upgrade.sh' ':!/scripts/release-git.sh' ':!/sparkyfitness'

if ((dry_run)); then
  printf '\nDRY RUN COMPLETE: no files staged, no commit, no push.\n'
  exit 0
fi

confirm 'Stage the listed project files for review?' || die 'Cancelled before staging'
git add -- "${paths[@]}"
git diff --cached --check || die 'Staged changes failed whitespace check'
if git diff --cached --quiet; then
  printf 'No staged changes to commit.\n'
  exit 0
fi
printf '\n=== Staged diff summary ===\n'
git diff --cached --stat
printf '\n=== Staged filenames ===\n'
git diff --cached --name-only
confirm 'Commit exactly these staged files?' || { git reset --quiet; die 'Cancelled; staged files reset'; }
if [[ -z "$message" ]]; then
  read -r -p 'Commit message: ' message
fi
[[ -n "$message" ]] || { git reset --quiet; die 'Commit message cannot be empty'; }
git commit -m "$message"
printf '\nCommit created.\n'
if confirm 'Push main to origin now?'; then
  git push origin main
else
  printf 'Push skipped. Commit remains local.\n'
fi
