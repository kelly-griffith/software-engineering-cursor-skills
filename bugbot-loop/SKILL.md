---
name: bugbot-loop
description: Run Bugbot in a loop — assess each finding for legitimacy, search the codebase for similar bugs, fix them, and re-run until Bugbot reports no bugs or an iteration cap (default 5) is reached. Use when the user runs /bugbot-loop or asks to repeatedly run Bugbot and fix everything it finds.
disable-model-invocation: true
---

# Bugbot Loop

Repeatedly run Bugbot and fix legitimate findings until the review comes back clean.

## Parameters

- **Max iterations**: use the number the user provides (e.g. `/bugbot-loop 3`); default to 5 if unspecified.
- **Diff scope**: default `branch changes`, which covers committed, staged, and unstaged changes — so fixes from earlier iterations are included when re-reviewing. Use `uncommitted changes` only if the user asks to review only local, not-yet-committed work.

## Loop

Keep two running lists across iterations: **fixed** and **dismissed**, each entry with a one-line reason. For each iteration, up to the max:

**1. Run Bugbot.** Launch exactly one fresh `bugbot` subagent via the Task tool with `subagent_type: "bugbot"`, `description: "Bugbot"`, and `run_in_background: false`, using this prompt shape:

```text
Full Repository Path: <absolute repository path>
Diff: branch changes
```

Do not compute the diff yourself; the subagent does that. Bugbot is single-shot and cannot be resumed — launch a new subagent every iteration. If it fails before producing findings, retry once; if it fails again, stop the loop and report the error.

**2. Stop if clean.** If Bugbot reports no bugs (or no diff to review), exit the loop.

**3. Assess each finding for legitimacy.** Read the code the finding points at before judging it. A description of something factual is not enough to be legitimate, that which is reported also needs to be something that ought to be fixed to be legitimate. Dismiss findings that are accurate observations but not defects worth fixing — intentional behavior, style preferences, or scenarios that cannot actually occur. A finding that passes this test is a legitimate bug. If a finding matches one already on the dismissed list from an earlier iteration, skip it without re-assessing.

**4. Search for similar bugs.** For each legitimate bug, search the codebase for other instances of the same mistake — the same misused API, the same flawed logic in copy-pasted or sibling code — and add each instance found to the fix list.

**5. Fix.** Fix each legitimate bug and all similar instances. Check lints on edited files and fix any errors introduced.

**6. Continue or stop.** If no fixes were applied this iteration (every finding was dismissed or already on the dismissed list), exit the loop — re-running Bugbot on unchanged code would return the same findings. Otherwise go back to step 1.

## Final report

State how the loop ended — clean (Bugbot reported no bugs), stalled (all remaining findings dismissed), or iteration cap reached — then summarize:

- iterations run
- bugs fixed, including similar instances found in step 4, as `file:line` plus one line each
- findings dismissed, with the reason each was judged not legitimate
