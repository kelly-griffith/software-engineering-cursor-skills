---
name: openapi-to-full-stack
description: Orchestrates openapi-to-spring-api, spring-api-to-service, and openapi-to-web-ui into one sequential pipeline that turns an OpenAPI spec into a complete, tested backend service and frontend web app in a single run. Expects three inputs — an OpenAPI spec (file, URL, or pasted), a backend directory, and a frontend directory — and runs each phase as its own subagent so the orchestrating context stays small. Verifies the running service's generated OpenAPI document against the source spec before handing that document to the frontend, and finishes with e2e tests against the live backend. Use when the user provides an OpenAPI spec and asks for a full stack, a backend plus frontend, or an end-to-end app built from the spec in one shot.
---

# OpenAPI to full stack (orchestrated)

Run three sibling skills as a sequential pipeline: contract scaffold → completed
service → conformance gate → web UI with e2e tests. Two principles keep the cost down,
and every rule below serves one of them:

1. **The orchestrator does no phase work.** Each phase runs as one subagent that reads
   its own skill and burns its own context. The orchestrator only prepares inputs,
   launches phases, checks gates, and relays questions.
2. **Artifacts travel on disk, never through context.** Subagents end with a compact
   fixed-format report; file contents, diffs, and logs stay out of it.

The sibling skills live in the same directory as this skill; `{SKILLS_DIR}` below means
that directory. `{SPEC}`, `{BACKEND}`, `{FRONTEND}` are absolute paths.

## Inputs and preflight

Collect three inputs, asking the user for any that are missing: the OpenAPI spec (file
path, URL, or pasted text), the backend directory, the frontend directory. Then, before
launching anything:

1. Resolve both directories to absolute paths; create them if absent. They must be
   distinct. If the frontend directory already contains an app, stop and ask.
2. Resolve the **canonical spec** to an absolute path **outside both** project
   directories; `{SPEC}` means that path from here on, and every phase references it by
   path. Given a file path, use it in place. Given a URL or pasted text, write it to a
   temp file outside both directories; delete that file when the pipeline succeeds, keep
   it while blocked or failed so resume can reuse it. Never save a spec copy into
   `{BACKEND}` — a residual copy there becomes a stale second source of truth, and the
   running service can always regenerate its document at `/v3/api-docs.yaml`.
3. Fail fast on a broken spec: `npx @redocly/cli@latest lint {SPEC}`. Hard errors go
   back to the user before any subagent is spent; style warnings are fine.
4. Toolchain: confirm a current-LTS JDK (`java -version`) and Node (`node -v`); check
   Docker (`docker info`). No JDK or Node → ask the user before installing. No Docker →
   don't block; pass "Docker unavailable — use the Docker-less embedded-engine fallback
   (D6)" as a note to phases 2–4.

## Pipeline

Four phases, strictly sequential, each exactly one subagent. Never run phases in
parallel; never start a phase before the previous gate passes.

| # | Phase | Subagent reads | Works in | Gate |
|---|---|---|---|---|
| 1 | Contract scaffold | `{SKILLS_DIR}/openapi-to-spring-api/SKILL.md` | `{BACKEND}` | Scaffold files exist; suite compiles; contract tests red-as-intended; generated document verified against `{SPEC}` (its step 8); stubs deleted |
| 2 | Complete the service | `{SKILLS_DIR}/spring-api-to-service/SKILL.md` | `{BACKEND}` | `./mvnw test` green with zero assertion edits; skill checklist complete |
| 3 | Conformance gate + handoff | rules from `{SKILLS_DIR}/spring-api-to-service/SKILL.md` | `{BACKEND}` | Runtime document semantically matches `{SPEC}` (accepted gaps listed); suite still green; document written to `{FRONTEND}/openapi/openapi.yaml` |
| 4 | Web UI + e2e | `{SKILLS_DIR}/openapi-to-web-ui/SKILL.md` | `{FRONTEND}` | Build, typecheck, lint green; Playwright (smoke + axe) green against the live backend |

Phase 3 exists even though phase 1 already diffed the document: the implementation
changes what the service serves (real controllers, error controller, springdoc config),
and phase 3's output — the document the service actually serves — is what the frontend
is generated from. The frontend is therefore guaranteed to match the running service,
not merely the spec.

## Orchestrator rules

- Do not read the sibling skills or their reference files yourself; only subagents read
  them.
- Verify gates cheaply: the phase report, plus existence checks on the artifact paths it
  names, plus — only if the report is ambiguous — rerunning that phase's single gate
  command (`./mvnw test`, `npx playwright test`). Never read source files to verify.
- Every subagent prompt is self-contained: absolute paths, the preflight notes, answers
  the user has given. Subagents have no conversation context.
- Keep your own messages to the user short; the full story arrives in the final report.

## Report protocol

Every phase prompt embeds this template. A report longer than ~25 lines, or containing
code, diffs, or logs, is a protocol violation — if a relaunch is needed, distill facts
into the new prompt instead of forwarding bulk.

```
PHASE REPORT — <phase name>
Status: COMPLETE | BLOCKED
Gate evidence: <one line per gate criterion: what was run, what resulted>
Artifacts: <absolute paths created or updated, one per line>
Deviations / accepted gaps: <up to 5 bullets, or "none">
Questions for the user: <only when BLOCKED; exact questions, with the options you see>
```

## Blocked and failed phases

- **BLOCKED** (the underlying skills demand "ask the user — never invent surface", and a
  subagent cannot ask): relay the report's questions to the user, then relaunch the
  *same phase* as a fresh subagent with the answers added to its prompt. Completed
  phases are not rerun.
- **Failed gate or crashed subagent**: relaunch that phase once, fresh, with a short
  factual summary of what failed. If it fails again, stop the pipeline and report —
  never fall forward into the next phase on a failed gate.

## Resuming

Gates are recomputable from disk, so a fresh session never redoes finished work: check
gates in order (scaffold files present and suite red → phase 1 done; `./mvnw test` green
→ phase 2 done; `{FRONTEND}/openapi/openapi.yaml` present with green suite → phase 3
done; frontend builds and Playwright passes → phase 4 done) and start at the first
phase whose gate fails. Re-resolve `{SPEC}` the same way preflight did (the user's file,
or the kept temp copy); there is no spec copy in `{BACKEND}` to fall back on.

## Phase prompts

Prepend the shared preamble to each phase prompt, substituting paths and appending the
preflight notes and any user answers.

### Shared preamble

```
You are one phase of a spec-to-full-stack pipeline and have no other context; everything
you need is in this prompt. Work only inside the directories named below. First read the
skill file(s) named below and follow them exactly. If the skill would have you ask the
user something, or you hit an ambiguity you cannot resolve from the spec or the code,
stop and set Status: BLOCKED with the exact question — never invent an answer. Do not
paste file contents, diffs, or logs into your final message. End with exactly this
report:
<report template>
```

### Phase 1 — Contract scaffold

```
Read {SKILLS_DIR}/openapi-to-spring-api/SKILL.md and follow its workflow end to end.
Spec: {SPEC} (lint-clean; read it in place — do not copy it into the project).
Project directory: {BACKEND}.
Toolchain already confirmed: <JDK/Node versions from preflight>.
Done when its checklist is complete: scaffold written, generated document verified
against the spec per its step 8 with throwaway stubs deleted, suite compiling with
contract tests red-as-intended. Report red/green test counts and any spec constructs
left unmapped as deviations.
```

### Phase 2 — Complete the service

```
Read {SKILLS_DIR}/spring-api-to-service/SKILL.md and follow it end to end. The scaffold
from a previous phase is in {BACKEND}; the source spec is {SPEC}. <Docker note if any.>
Done when the skill's per-service completion checklist is complete and ./mvnw test is
green with zero assertion edits and no tests added. Report the final test count and
each checklist item's state.
```

### Phase 3 — Conformance gate + handoff

```
You verify that the service in {BACKEND} serves an OpenAPI document matching its source
spec, then hand that document to the frontend. Read
{SKILLS_DIR}/spring-api-to-service/SKILL.md first — its ground rules bind any fix you
make (api/ and api/dto/ are frozen except for proven contract bugs; contract tests pass
unchanged; no assertion edits).

1. Boot the service with ./mvnw spring-boot:test-run (test-scoped launcher, throwaway
   database) and poll until it answers.
2. Fetch the runtime document as YAML — default http://localhost:8080/v3/api-docs.yaml,
   unless springdoc.api-docs.path in the config moved it.
3. Write a small script at {BACKEND}/scripts/ that takes two document paths as
   arguments (source spec, runtime document — no spec file lives in {BACKEND}), parses
   both, and compares them semantically — paths, operations, parameters and their
   facets, request/response schemas, required arrays, enums, status codes, media types,
   response headers.
   Normalize before comparing: resolve each document's effective base path (servers URL
   path + path keys) so a prefix carried in servers on one side and in path keys on the
   other does not read as a wholesale mismatch; ignore server host/port and key order;
   compare schemas structurally through $refs, so a pure component-name difference
   (e.g. a derived generic name like PageResponseWidget) is reported as benign, not a
   failure.
4. Classify each real discrepancy and fix it in the backend: implementation/config bugs
   (a leaked /error path means a missing @Hidden; wrong media types mean produces/
   consumes; a moved document means the springdoc path property) or scaffold annotation
   bugs (a sanctioned contract-bug fix). Known springdoc expressiveness gaps that cannot
   be fixed are accepted and listed in the report — do not loop on them. After every
   fix: ./mvnw test must be green; then re-fetch and re-diff.
5. When the diff is clean modulo accepted gaps, write the fetched document byte-for-byte
   to {FRONTEND}/openapi/openapi.yaml (create the directory), stop the server, and keep
   the comparison script in {BACKEND}/scripts/ so it can serve as a CI drift gate —
   CI supplies the two paths (its source of truth, a freshly fetched runtime document).

Source spec: {SPEC}. Done when: diff clean modulo accepted gaps, suite green, document
in place. Report each discrepancy found and how it was resolved (one line each).
```

### Phase 4 — Web UI with e2e

```
Read {SKILLS_DIR}/openapi-to-web-ui/SKILL.md and follow its workflow end to end.
Project directory: {FRONTEND}. The spec is already at {FRONTEND}/openapi/openapi.yaml —
it is the document the backend actually serves; do not re-fetch or replace it (its step
1 saving is done; still run its lint). Heed its known first-run failures before
scaffolding — create-next-app will refuse a directory containing the openapi/ folder.

Run its verification (step 10) end to end against the LIVE backend, not mocks:
- Start the backend first: cd {BACKEND} && ./mvnw spring-boot:test-run (throwaway,
  freshly migrated, EMPTY database on http://localhost:8080). <Docker note if any.>
- Point the app's API base at it via env per the skill's client config.
- The dev backend enforces no auth even where the spec declares securitySchemes; tests
  may call it without credentials.
- Because the database starts empty, Playwright must seed its own fixtures over the API
  (request in test setup) rather than assuming records exist.
- Stop the backend when done.

Done when build, typecheck, lint, and the full Playwright suite (smoke + axe scans) are
green against the live backend. Report the page map summary, excluded operations,
indexable routes, and test results.
```

## Final report to the user

Aggregate the four phase reports into one short summary: what was built and where, the
commands to run each piece (backend dev server, backend tests, frontend dev, e2e),
every accepted gap and excluded operation, and open follow-ups (auth enforcement,
deployment) that the underlying skills deliberately leave to the organization.
