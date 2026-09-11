---
name: openapi-to-spring-api
description: Ingests an OpenAPI specification (3.0/3.1/3.2, YAML or JSON, from a file, URL, or pasted text) and produces an idiomatic Spring Boot REST API contract — Java interfaces carrying all mapping and OpenAPI annotations, record DTOs, an RFC 9457 problem+json error model — plus test-first MockMvc contract tests against the interface. Targets the latest Java LTS and the current stable Spring Boot. Use when the user provides an OpenAPI or Swagger spec and asks to scaffold, generate, or implement a Spring Boot API from it, or asks for contract-first Spring Boot development.
---

# OpenAPI → Spring Boot API contract

Turn an OpenAPI spec into a hand-quality Spring Boot API surface: contract interfaces,
record DTOs, shared error components, and contract tests. Write the code directly —
do **not** use openapi-generator or other codegen tools (their output is non-idiomatic
and they cannot produce the tests). Mention openapi-generator to the user only if they
need build-time machine-enforced spec sync; see the note in [reference.md](reference.md).

## Deliverable

For each resource in the spec:

1. A contract interface in `api/` (`XxxApi`) carrying **all** mapping, validation, and
   OpenAPI annotations.
2. Record DTOs in `api/dto/` (`XxxRequest` / `XxxResponse`, shared `PageResponse<T>`
   for paginated lists).
3. A shared error model: `OpenApiConfig` declaring reusable RFC 9457 problem schemas and
   responses under `components`, plus — whenever the project has no error model of its
   own, judged by the absence of a `@RestControllerAdvice` rather than by the project
   being new — a `GlobalExceptionHandler` and the minimal domain exceptions it
   translates. Those exceptions are in scope even though `service/` otherwise is not.
4. Contract tests (`XxxApiTest`), one class per interface.
5. Whatever request-boundary enforcement the spec's wire rules demand but DTOs cannot
   express — see "Merge-style updates (PATCH)" in [reference.md](reference.md).

**Tests are part of this skill's contract** — invoking it is an explicit request for
tests, overriding any repo rule that says not to write tests unless asked. The tests
stay in the tree.

Controllers and services are **not** part of the deliverable unless the user asks.
Contract tests are written test-first: with no implementing `@RestController` the
endpoints return 404 and the tests are **red — that is the intended TDD state**, and
once the middle layer is implemented they should pass unchanged. Report this plainly;
never stub endpoints or weaken assertions to force green.

## Resolve the stack first

Before writing code, pin the versions (look them up; do not trust memory):

- **Java**: the latest LTS — Java 25 at time of writing; LTS releases land every two
  years (verify at https://www.oracle.com/java/technologies/java-se-support-roadmap.html
  or https://endoflife.date/java).
- **Spring Boot**: the current stable line for that LTS — Boot 4.x (4.1.x at time of
  writing; verify at https://spring.io/projects/spring-boot or via start.spring.io).
- **springdoc-openapi**: the line matching the Boot major — 3.x for Boot 4 (verify at
  https://springdoc.org).
- **Toolchain**: confirm a JDK for that LTS is installed and usable (`java -version`, or
  `./mvnw -v` in an existing project) *before* writing code — the last two steps have to
  boot the app and run the suite. If none is present, ask the user before installing one
  rather than discovering it later and skipping verification.

Boot 4 / Spring Framework 7 changed several APIs; do not reach for Boot 3.x idioms.
See "Spring Boot 4 gotchas" in [reference.md](reference.md).

## Workflow

Copy this checklist and track progress:

```
Task Progress:
- [ ] 1. Read and sanity-check the spec; confirm the toolchain
- [ ] 2. Plan the resources
- [ ] 3. Project skeleton (greenfield only)
- [ ] 4. Record DTOs
- [ ] 5. Contract interfaces
- [ ] 6. Error model
- [ ] 7. Contract tests
- [ ] 8. Verify the generated document against the spec
- [ ] 9. Run the suite and report
```

**Step 1 — Read and sanity-check the spec.** Accept a path, URL, or pasted text, YAML
or JSON. Confirm `openapi: 3.x` and resolve local `$ref`s while reading. If the spec is
ambiguous or contradictory (a response schema that contradicts its description, colliding
paths, an operation whose semantics you cannot determine), **ask the user — never invent
surface**. Constructs that do not map to a plain Web MVC scaffold (webhooks, callbacks,
3.2 `additionalOperations` / streaming `itemSchema`) are listed as out of scope in the
final report, not guessed at.

**Step 2 — Plan the resources.** Group operations by tag (fallback: first meaningful
path segment). One `XxxApi` interface and one `XxxApiTest` class per resource. Note the
base path and URL version prefix (`/api/v1` style) from `servers` + paths.

**Step 3 — Project skeleton (greenfield only).** If there is no Spring Boot project,
create a minimal Maven one: `spring-boot-starter-parent` at the current stable version,
`<java.version>` = the LTS, starters `web` + `validation`, springdoc, and the test
starters (`spring-boot-starter-test` and `spring-boot-starter-webmvc-test`, test scope).
Skeleton snippet in [reference.md](reference.md). Generate the wrapper
(`mvn wrapper:wrapper`) and use `./mvnw` from then on. In an **existing** project,
respect its package root, layering, and build setup; add only missing dependencies.

**Steps 4–7 — Write the code.** Follow the conventions in
[reference.md](reference.md) (layout, interface rules, OpenAPI→Java mapping tables,
error model, test conventions). A complete worked example — spec in, interface + DTOs +
tests out — is in [examples.md](examples.md).

**Step 8 — Verify the generated document against the spec.** Do not skip this: the
annotations *are* the deliverable and nothing has checked them yet. springdoc only
documents operations an actual controller exposes, so with no implementation the document
is empty — which is exactly when this skill would otherwise hand it over. Write
**throwaway** stub controllers implementing each interface with canned return values,
fetch `/v3/api-docs` (a temporary `@SpringBootTest` that prints it is enough), and diff it
against the ingested spec: paths, operation ids, property names, `required` arrays, media
types, `$ref`s to the shared error components, response headers, enum values, parameter
facets. Fix what the diff finds — the failures that actually bite are catalogued under
"Generated-document pitfalls" in [reference.md](reference.md). The same stubs are the only
chance to check runtime binding (an explicitly null member, a malformed path id, enum and
range validation, the response content type) before handover. **Delete the stubs and the
temporary test when the pass is done**, and report what was verified.

**Step 9 — Run the suite and report.** Run `./mvnw test`. Everything must compile; report
which tests are red and state explicitly that red-until-implemented is the intended
test-first state (or, if an implementation already existed, that they pass). List any spec
constructs left unmapped, and anything the generated document cannot express faithfully.

## Hard rules

- Annotations live on the **interface**; controllers (when they exist) are bare
  `@RestController implements XxxApi` with `@Override` methods delegating to a service.
- DTOs are records, one per direction (`XxxRequest` / `XxxResponse`) — never a single
  dual-purpose class, never JPA entities as wire types.
- Every field of every record gets `@Schema` with a description, carrying the spec's
  `required`/`nullable`/`readOnly`/default/constraint facts.
- Every error response is RFC 9457 `application/problem+json`, declared once as shared
  components and referenced with `@ApiResponse(ref = "#/components/responses/...")`.
- Use explicit names in `@PathVariable("id")` and `@RequestParam(name = "...")` —
  interface parameter names are not reliably available at runtime.
- Preserve the spec faithfully: do not invent endpoints, fields, or constraints that are
  not there, and do not drop any that are. Where the spec contradicts a default in this
  skill — a status code, the problem-body shape, a naming convention — the spec wins; note
  the deviation in the report.
- Tests assert observable HTTP behaviour only (status, headers, JSON body) — never
  implementation details.

## Additional resources

- [reference.md](reference.md) — layout and interface conventions, OpenAPI→Java mapping
  tables, merge-style updates, error model, test conventions, generated-document pitfalls,
  Spring Boot 4 gotchas, spec-version notes.
- [examples.md](examples.md) — complete worked example: widget spec → `WidgetApi`,
  records, `OpenApiConfig`, contract tests.
