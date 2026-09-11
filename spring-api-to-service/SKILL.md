---
name: spring-api-to-service
description: Completes a contract-first Spring Boot scaffold — api/ contract interfaces, api/dto/ record DTOs, shared problem+json components, and red MockMvc contract tests, however they were produced — by implementing the web, service, and repository layers plus Flyway migrations under fixed cross-cutting decisions (hand SQL via JdbcClient vs JPA by criteria, server-assigned UUIDs, Clock-driven timestamps, database-enforced uniqueness translated through a constraint-name registry, Testcontainers on the deployed engine, migrations as a discrete deploy step) until the contract tests pass unchanged, then wires configuration and packaging. Use when a project contains that scaffold (api/ contract interfaces, api/dto/ records, red contract tests) and the user asks to implement or complete the service, make the contract tests pass or go green, add persistence, controllers, or migrations behind the contract, or take the scaffold to production.
---

# Completing a scaffolded service

The input is a Spring Boot project whose contract layer is already complete and stops
there: `api/` interfaces carrying every mapping, validation, and OpenAPI annotation,
`api/dto/` records as the wire types, an `OpenApiConfig` declaring shared RFC 9457
problem schemas and responses, a `GlobalExceptionHandler` translating domain exceptions,
and MockMvc contract tests (`XxxApiTest` over a shared base class, `AbstractWebApiTest`
by convention) that are **red** because nothing implements the interfaces yet. That
collection is called **the scaffold** throughout; how it came to exist — generated from
an OpenAPI spec or written by hand — changes nothing below.

This skill is the general scheme for everything after it — the middle and bottom layers,
and packaging the result — written to apply to **any** such service, whatever platform it
ships to. Platform concerns (authentication scheme, multi-tenancy, cloud runtime, and
whatever runs builds and deploys) are deliberately out of scope; layer them on per
organization.

Ground rules the scaffold imposes, restated because everything below depends on them:

- The scaffold is **frozen input**. `api/` and `api/dto/` are edited only to fix a proven
  contract bug, never to make the implementation easier.
- The contract tests are the definition of done: they pass **unchanged**. The one
  sanctioned edit to the test tree is additive infrastructure on the shared base class
  (test database wiring, `@ActiveProfiles("test")`) — never an assertion.
- Where the concrete OpenAPI spec pins a behavior this skill leaves open, **the spec
  wins**. Those points are collected under "Points the concrete spec decides" in
  [reference.md](reference.md) so you can resolve them by reading the scaffold, without
  re-deriving the whole design.

## Decision log

Decisions the contract layer leaves open, made here once so every service completed
this way answers them the same way. Rationale is one line each; the sections that
follow — here and in [reference.md](reference.md) — carry the detail.

| # | Decision | Choice | Why |
|---|---|---|---|
| D1 | Persistence access style | Criteria-driven, decided per service (reference.md, "Choosing the access style"): hand SQL via `JdbcClient` + Flyway when the spec's semantics are database-native (embedded documents, keyset pagination, cascade/restrict rules, containment queries); JPA is legitimate for entity-graph CRUD in a shop that already speaks it | The wrong default is fighting your tool — either an ORM you bypass constantly, or hand SQL for what an ORM does for free |
| D2 | What services accept/return | The scaffold's DTO records directly; row records (or entities) stay in the repository layer; a separate domain model **only where behavior demands it** | Contract-first means the wire shape *is* the source of truth; a mapping layer per service is ceremony until a service has real domain logic |
| D3 | Ids | Server-assigned `UUID.randomUUID()` in the service layer | Available before insert (response needs no re-read); UUIDv7 is an optional later upgrade for index locality |
| D4 | Timestamps | `created_at`/`updated_at` set in the service from an injected `Clock`, stored as `timestamptz` (or the engine's zone-aware type) | One authority, testable; no triggers to keep in sync with code |
| D5 | Uniqueness & referential rules | Enforced by the **database**, translated to problems via a constraint-name registry | Check-then-insert races; the DB verdict is the only correct one |
| D6 | Test database | The same engine you deploy, via Testcontainers (singleton container, `@ServiceConnection`); zonky embedded-postgres as a Docker-less fallback for Postgres | A substitute engine (H2 for Postgres) tests a different database; use one only if you would deploy it |
| D7 | Migration execution | Flyway **off** at app startup in production — run migrations as a discrete deploy step (a job or init step using the same artifact); **on** at startup in dev/test | N instances racing migrations at startup is the failure mode; a serialized step removes it |

## Layering and package layout

Extend the scaffold's layout with the implementation packages. Everything lives under
the service's package root:

```
api/            Contract interfaces (scaffold-owned, frozen)
api/dto/        Record DTOs (scaffold-owned, frozen)
web/            @RestController implementations + GlobalExceptionHandler
service/        Application services (transactions, domain rules)
service/exception/  NotFoundException, ValidationException, ConflictException, …
repository/     Repositories + row records
config/         OpenApiConfig (scaffold-owned) + properties records + wiring
resources/db/migration/   Flyway V###__*.sql
```

Dependency rules, enforced by review (or ArchUnit if you want it mechanical):

- `web/` depends on `api/` and `service/` only. No SQL, no repositories, no business
  decisions.
- `service/` depends on `repository/`. It never imports servlet, Spring MVC, or
  springdoc types — services must be callable from tests (and any non-HTTP entry
  point) without a request.
- `repository/` sees only the persistence API and its own row records. It throws
  Spring's `DataAccessException` family and returns `Optional.empty()` — never web or
  domain exceptions.

Two shapes deliberately do not exist by default: JPA entities used as wire types (the
scaffold's records are the wire types, and that holds regardless of D1's outcome), and a
mapper layer between DTOs and "domain objects" (D2). A service earns an internal domain
type only when a concept has behavior the wire shape doesn't express; the translation
then lives inside that service, invisible to layers above.

The per-layer conventions — web layer, auth boundary, service layer, error translation,
persistence, schema and migrations, configuration, packaging and runtime — are in
[reference.md](reference.md). Read the section for a layer before implementing it; the
decision log above tells you which choices are already made.

## Turning the contract suite green

### Test infrastructure (the one sanctioned test edit)

The scaffold's `AbstractWebApiTest` gains real-database wiring and the permissive
profile — infrastructure only, assertions untouched:

```java
@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
@Import(TestDatabase.class)
public abstract class AbstractWebApiTest { ... }
```

`TestDatabase` is a `@TestConfiguration` exposing a **singleton** Testcontainers
container for the engine you deploy (e.g. `postgres:16-alpine`, matching the production
major) registered via `@ServiceConnection` (dependencies: `spring-boot-testcontainers` +
the engine's Testcontainers module, test scope). Container-per-suite, Flyway once per
context, tests share the schema — which the scaffold's tests already tolerate because
they were written black-box against ids they create themselves. In a Docker-less
environment, substitute an embedded build of the same engine (zonky embedded-postgres)
behind the same `@TestConfiguration`; nothing else changes. Do not substitute a
different engine (D6).

That same `@TestConfiguration` is also a dev server, for free — a test-scoped launcher
gives `./mvnw spring-boot:test-run` a live service on the engine the suite uses, so
trying the API by hand needs no database of one's own:

```java
public static void main(String[] args) {
    SpringApplication.from(WidgetApplication::main)
            .with(TestDatabase.class)
            .withAdditionalProfiles("dev")
            .run(args);
}
```

It lives in test sources because `TestDatabase` does — one definition of the engine you
develop against, for both the suite and the live server — and being test-scoped it cannot
reach the production artifact. The data dies with the JVM, so every start is an empty,
freshly migrated schema; developers who want durable data point the service at their own
through the environment, exactly as production does.

### Order of work

Implement resource by resource, bottom-up, using that resource's `XxxApiTest` as the
spec: migration → row record + repository → service → controller → run the class → next
resource. Start with the resources others depend on (referenced types before their
referrers). Two rules hold throughout: never weaken an assertion to get green, and if a
test seems wrong, treat it as a contract question (check the spec) — not an obstacle.

### Tests the implementation adds — none that stay

The contract suite is the only test tree that ships. Do **not** add permanent tests
alongside it. A test written now comes from the same reading of the spec as the code it
covers, so it proves the implementation self-consistent, not correct: a misread value
grammar yields a matching validator and a matching test, both green, both wrong.

Temporary probes are a different thing and are encouraged, on one condition — something
other than your own reading supplies the answer. The database is the usual third party:
a probe asserting what `fields @> :probe` matches, or how a keyset tuple comparison
orders rows at equal sort keys, goes red on a wrong mental model and teaches you
something. Write the probe, run it, believe the engine over your expectation, fix the
code, **delete the probe** — it exists to answer one question, not to ship.

A probe is not worth writing when the behavior is observable over HTTP, because that is
the contract suite's job and it already covers it from the spec: a tampered or
undecodable cursor is just a request. Never add controller tests (controllers have no
logic), service tests re-asserting what a contract test proves, or anything mocking the
persistence API.

## Per-service completion checklist

Copy per service; order matters (it is the bottom-up order of "Order of work" above):

```
- [ ] V001 migration: named constraints, FK actions per spec, list-ordering indexes
- [ ] Row records + repositories
- [ ] Domain validators (pure, isolated) + services: tx boundaries, getOrThrow,
      Clock-driven timestamps, merge-PATCH per spec
- [ ] Constraint-name registry covering every uq_/fk_ the migrations declare
- [ ] Advice completed: registry, path-vs-query mismatch branch, parameter-validation 400s
- [ ] Controllers: bare `implements`, Location where the spec declares it, streaming
      exports with capture-then-fresh-transaction
- [ ] Test infra: singleton container for the deployed engine + @ActiveProfiles("test")
      on the scaffold base — the only test edit
- [ ] Contract suite green — zero assertion edits, no tests added
- [ ] Temporary probes deleted; the test tree is the scaffold's plus the base-class wiring
- [ ] Auth boundary per org scheme: filter-level problems, permissive test profile
- [ ] Image with serve + migrate modes; health probes wired; build once, promote digest
- [ ] README: dev server, tests, bring-your-own database, migrate step, image — every
      command run before it is written down
```

## Additional resources

- [reference.md](reference.md) — web layer, auth boundary, service layer, error
  translation (constraint-name registry), persistence (access style, dependencies,
  repository conventions, pagination, embedded documents, streaming), schema and
  migrations (DDL pattern, Flyway, expand/contract), configuration and profiles,
  packaging and runtime, and the table of points the concrete spec decides.

---

### Contract vs implementation, in one line

The scaffold freezes *what the service says*; this skill standardizes *how a service does
it* — take the contract as given and walk the checklist until the suite is green and the
artifact is ready to ship.
