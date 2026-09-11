# Software Engineering Cursor Skills

A collection of Cursor agent skills. Each top-level directory containing a `SKILL.md` is one skill.

## Setup

Clone the repo, then run once:

```bash
./sync-skills.sh
```

This symlinks every skill in the repo into `~/.cursor/skills`, where Cursor discovers them. Because they are symlinks, any edits you pull later take effect automatically — no re-run needed.

Re-run `./sync-skills.sh` only when skills are **added, removed, or renamed** in the repo (e.g. after a `git pull` that brings in a new skill). The script is idempotent and cleans up its own stale links; it never touches skills that didn't come from this repo.

Optional: to make that automatic, add a local git hook:

```bash
printf '#!/bin/sh\n"$(git rev-parse --show-toplevel)/sync-skills.sh"\n' > .git/hooks/post-merge
chmod +x .git/hooks/post-merge
```
