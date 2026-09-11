# Reference: layer conventions, packaging, and runtime

Detail for [SKILL.md](SKILL.md) — read the section for a layer before implementing it.
Decision references (D1–D7) point to the decision log in SKILL.md.

## Web layer

One controller per contract interface, and it is boring on purpose:

```java
@RestController
public class WidgetController implements WidgetApi {

    private final WidgetService service;

    public WidgetController(WidgetService service) { this.service = service; }

    @Override
    public ResponseEntity<WidgetResponse> create(WidgetRequest request) {
        WidgetResponse created = service.create(request);
        return ResponseEntity
                .created(linkTo(created.id()))       // only if the spec declares Location
                .body(created);
    }

    private static URI linkTo(UUID id) {                     // a path, not an absolute URL
        String collection = ServletUriComponentsBuilder.fromCurrentRequestUri().build().getPath();
        return URI.create(collection + "/" + id);
    }
}
```

Hard rules:

- No `@RequestMapping`, `@Operation`, or validation annotations on the class — everything
  is inherited from the interface. Adding any re-opens the contract in a second place.
- No `try/catch`, no `if` that chooses a status code. Every non-2xx outcome exits the
  service as a domain exception and becomes a problem in the advice. A controller with a
  branch is a review reject.
- Status codes match the interface's `@ResponseStatus`; the controller sets the same code
  on the `ResponseEntity` (201 via `.created(...)`, 204 via `.noContent()`, 202 via
  `.accepted()`).
- The mount prefix is the scaffold's — chosen when the interfaces were written and held in
  one constant they concatenate (`ApiPaths.V1 + "/widgets"`), so read it off the interfaces
  rather than a property. Nothing here re-decides it. Two rules survive into deployment:
  never configure prefix stripping at a proxy or gateway, so a request against the service
  directly and one through the edge exercise the same routes; and any property of yours
  that repeats the prefix —
  `springdoc.api-docs.path` — cannot read the constant, so keep it in step by hand and say
  so where it is written.
- `Location` is a path unless the spec demands an absolute URL. Deriving an origin from
  the request means advertising the internal `http://host:port` behind a TLS-terminating
  proxy, and echoing a client-supplied `Host` header straight back into a response header.
  Where the spec does demand absolute, set `server.forward-headers-strategy=framework`
  behind a trusted proxy rather than trusting `Host`. Contract tests usually assert only
  that the header exists, so neither problem shows up in the suite.

The `GlobalExceptionHandler` from the scaffold is completed, not replaced — "Error
translation" below lists what the implementation adds to it.

## The auth boundary (kept out of the scaffold's way)

The scaffold documents the spec's `securitySchemes` but adds no enforcement; that stays
true here, because enforcement is an organization-level choice (Spring Security's
resource server, a gateway, a custom token filter). Whatever the org uses, three rules
keep it from corrupting the layers above:

- Enforcement lives in a filter/security layer registered before MVC — never in
  controllers or services, which stay principal-agnostic behind whatever
  context-propagation mechanism the auth layer provides.
- Anything a filter rejects must still answer in the spec's error shape.
  `@RestControllerAdvice` does **not** cover filters — easy to forget, discovered in
  production — so the filter writes its own `application/problem+json` (mirroring the
  shared `ProblemDetail` components, `WWW-Authenticate` on 401) via one small helper the
  advice shape cannot drift from.
- The contract tests run under a permissive profile (`@ActiveProfiles("test")` on the
  scaffold's base class) so they pass unchanged; auth gets its own tests.

## Service layer

Services own transactions, domain validation, and orchestration.

```java
@Service
public class WidgetService {

    @Transactional
    public WidgetResponse create(WidgetRequest request) {
        validator.validate(request);                      // domain rules → ValidationException
        Instant now = clock.instant();
        WidgetRow row = WidgetRow.of(UUID.randomUUID(), request, now);
        repository.insert(row);                           // unique violation → advice → 409/400 per spec
        return row.toResponse();
    }
}
```

Rules:

- `@Transactional` on every public service method; `readOnly = true` on queries. One
  transaction per request is the norm.
- **Validation is split.** Structural rules (`required`, `maxLength`, enum membership)
  are Bean Validation's, already asserted by the scaffold via `@Valid` on the interface.
  Domain rules — value grammars, append-only lists, immutable members, cross-field
  constraints — live in the service and throw `ValidationException` whose problem
  `detail` (or `errors[]`, if the spec has one) uses the spec's own field-path style.
  The service is the authority; the DB is the authority only for uniqueness and
  referential integrity (D5), whose violations are *translated*, not pre-checked. A
  pre-check `SELECT` for a nicer error message is allowed as an optimization, but the
  constraint translation must exist regardless, because the pre-check races.
- **Not-found discipline:** repositories return `Optional`; services use one
  `getOrThrow(id)` helper per resource so 404s are uniform.
- Mutations return the post-state DTO built from what the service wrote (D3/D4) — no
  re-read after insert/update. `updated_at` bumps on every successful mutation, from the
  same injected `Clock` that tests can fix.
- Merge-PATCH semantics (present = set, absent = unchanged, explicit-null policy per
  spec) were settled at the boundary by the scaffold (its `RequestBodyAdvice`, when the
  spec rejects nulls). The service applies a present-member merge onto the loaded row —
  never a blind full update.
- Concurrency: last-write-wins, stated plainly, unless the spec has ETag/`If-Match` —
  only then add optimistic checks on `updated_at`.

## Error translation — completing the scaffold's advice

The scaffold shipped `GlobalExceptionHandler` for domain exceptions. The implementation
adds the mappings that only exist once there is a database and real binding:

- **Constraint-name registry.** Deliberately named constraints ("DDL pattern" below) are
  the join point between SQL and the API. One map per service:

  ```java
  Map.of(
      "uq_widgets_name",       conflict("/name", "a widget with this name already exists"),
      "fk_edges_type",         conflict(null,    "the type is still in use"))
  ```

  The advice catches `DataIntegrityViolationException`, extracts the constraint name from
  the `SQLException` chain (SQLState 23xxx), looks it up, and renders the spec's status
  with the registered detail. Where the problem `detail` needs request context the
  registry cannot know (the colliding name, the dangling id), the owning service catches
  the violation at the call site and throws the domain exception itself — the registry
  stays the generic backstop. An unregistered constraint name is a bug: log it at ERROR
  and return 500 — never leak raw SQL messages into a problem body. Corollary:
  **constraint names are API.** Renaming one in a migration without updating the registry
  is a breaking change; name them deliberately (`uq_`/`fk_`/`ck_` prefixes, table,
  columns).
- `MethodArgumentTypeMismatchException` handled at `@Order(Ordered.HIGHEST_PRECEDENCE)` —
  so it wins over Spring's built-in problem-details advice — branching on
  `ex.getParameter().hasParameterAnnotation(PathVariable.class)` when the spec makes a
  malformed path id a 404 while the same failure in a query filter stays a 400.
- Interface-parameter constraint failures (`@Min`/`@Max` on `@RequestParam`) surface as
  `HandlerMethodValidationException` — `spring.mvc.problemdetails.enabled=true` renders
  them as 400 problems; the contract tests confirm.
- 4xx logged at DEBUG, 5xx left to Spring's default handling — the scaffold's stance,
  unchanged. Resist the broad `@ExceptionHandler(Exception.class)`; it eats stack traces
  your error reporting would otherwise catch.
- **The container's error path needs its own problem+json.** An advice only covers what
  fails inside handler dispatch, so an infrastructure failure — or anything thrown by a
  filter — falls through to `/error` and is rendered by `BasicErrorController` as
  `{"timestamp":…,"error":…}` under `application/json`. That contradicts the spec's
  "every error uses this media type" in the one case nobody tests, and it means the same
  status answers in two shapes depending on cause. Replace it with an `ErrorController`
  returning a `ProblemDetail`: the exception still reaches the container and is still
  logged with its stack trace, and nothing about the cause reaches the body. This also
  gives the auth boundary's filter rejections the right shape for free. `MockMvc` does not
  exercise error dispatch, so verify it against a running server. Annotate that controller
  `@Hidden`: it is a forward target, not an operation, and springdoc will otherwise publish
  it as a path — which a contract-conformance gate will dutifully call and score against a
  document that never described it. Hide the class rather than excluding a path, so it
  follows `server.error.path` wherever that is configured.
- **Framework-worded 4xx leak implementation.** Spring answers an unmatched path with
  `NoResourceFoundException`, whose detail reads "No static resource …" — it describes how
  the request fell through, means nothing to a client, and makes one 404 distinguishable
  from another where the spec usually wants them uniform. Handle it in the advice and give
  it the same wording as the not-found the services throw.

## Persistence (`repository/`)

### Choosing the access style (per service, once)

Read the spec's semantics before picking:

- **Hand SQL (`JdbcClient` + Flyway)** when the contract leans on database-native
  behavior: embedded ordered documents (jsonb), keyset/cursor pagination, delete
  semantics declared as CASCADE/RESTRICT, containment or partial-index queries,
  streaming exports. With record DTOs already in place there is no entity model to
  protect, and the ORM would be bypassed for exactly the queries that matter.
- **JPA** when the service is entity-graph CRUD, the team already operates it well, and
  none of the above applies. Keep entities strictly inside `repository/`
  (never as wire types), and keep Flyway — never `ddl-auto` — as the schema authority.

Do not mix styles inside one service. The rest of this section assumes hand SQL; the
layering and translation rules apply identically under JPA.

### Dependencies

Boot keeps each technology's auto-configuration in a module of its own, so depending on the
library alone leaves it inert. `org.flywaydb:flyway-core` by itself runs no migrations and
says nothing about it; the first symptom is every test failing on a table that does not
exist, which reads like a broken migration rather than a missing dependency. Depend on
Boot's module and let it pull the library:

- `org.springframework.boot:spring-boot-starter-jdbc` — `JdbcClient`, `DataSource`,
  transaction management
- `org.springframework.boot:spring-boot-flyway` — Flyway *and* its auto-configuration
- the JDBC driver at `runtime` scope (e.g. `org.postgresql:postgresql`)
- the engine's Flyway dialect at `runtime` scope where it ships separately
  (e.g. `org.flywaydb:flyway-database-postgresql`)
- at `test` scope: `org.springframework.boot:spring-boot-testcontainers` plus the engine's
  Testcontainers module, or the embedded-server artifacts for the Docker-less fallback (D6)

The same rule applies to everything added later — actuator, JPA, security: take the Boot
module, not the library it wraps.

### Repository conventions

`JdbcClient`, one repository per aggregate table, row records beside it:

```java
public record WidgetRow(UUID id, String name, Instant createdAt, Instant updatedAt) {

    static final RowMapper<WidgetRow> MAPPER = (rs, i) -> new WidgetRow(
            rs.getObject("id", UUID.class),
            rs.getString("name"),
            rs.getObject("created_at", OffsetDateTime.class).toInstant(),
            rs.getObject("updated_at", OffsetDateTime.class).toInstant());
}
```

```java
public Optional<WidgetRow> find(UUID id) {
    return jdbc.sql("SELECT * FROM widgets WHERE id = :id")
            .param("id", id)
            .query(WidgetRow.MAPPER).optional();
}
```

### Pagination

Implement whichever flavor the scaffold's DTOs already encode — the envelope was fixed at
scaffold time, so this is read, not chosen:

- **Offset (`PageResponse<T>`):** `LIMIT :size OFFSET :offset` (offset computed in Java)
  plus a `COUNT(*)` under the same WHERE, both in the same read-only transaction.
  Whether an out-of-range `size` clamps or rejects is the spec's call — mirror it.
- **Cursor:** keyset on the spec's ordering, e.g. `(created_at, id)`:

  ```sql
  WHERE (created_at, id) > (:afterCreatedAt, :afterId)
  ORDER BY created_at, id LIMIT :size + 1
  ```

  Fetch `size + 1` to learn whether a next page exists without a count. The cursor is
  `base64url(payload || HMAC-SHA256(secret, payload))` over the keyset values, MACed
  together with a **scope** naming both the listing and its filters — opaque per spec,
  tamper-evident, stateless. Scope by filters alone is not enough: every unfiltered
  listing then shares one scope, and since they all key on `(created_at, id)` a cursor
  from one resource silently pages another instead of failing closed. The secret is configuration: a
  random per-boot key would silently invalidate every cursor on deploy and across
  instances. Undecodable or bad-MAC cursors → 400 (or the spec's wording). The
  supporting index matches the keyset exactly.

### Text the engine cannot store

PostgreSQL rejects U+0000 in `text` and in `jsonb`, but it is legal JSON and sits well
inside a spec that says "any Unicode text". Unhandled it becomes a 500 on a well-formed
request. Reject it at the body boundary — the same `RequestBodyAdvice` that walks the tree
for explicitly null members can check strings on the way past — so it is a 400 naming the
member rather than a driver error. Any other engine-level encoding limit belongs in the
same place.

### Embedded documents

When the spec embeds ordered, wholesale-replaced structures inside a resource (rather
than modeling them as sub-resources), store them as a single `jsonb` column written
whole on every update — matching the replacement semantics 1:1, no diffing. Serialize
through the app's `ObjectMapper` to a `PGobject`; validate contents in the service
("Service layer" above); answer "is this referenced?" checks with containment queries
(`fields @> :probe`) backed by a `GIN (… jsonb_path_ops)` index, and surface them as the
spec's 409s through the registry or the owning service.

### Large responses (CSV and other streams)

Stream, never buffer: the service exposes a method taking a `Writer`/`OutputStream` and
runs the query with a `ResultSetExtractor`, writing as it reads (set `fetchSize`; most
engines stream only inside a transaction). The controller returns
`StreamingResponseBody` — which executes **after** the request thread is done, so
everything request-bound is gone by then: the open transaction, security context, any
ThreadLocal. Capture what the callback needs while still on the request thread, and open
a fresh transaction inside:

```java
var params = exportParamsFromRequestContext();           // capture on the request thread
return ResponseEntity.ok().contentType(csv).body(out ->
        txTemplate.executeWithoutResult(tx ->
                exportService.writeCsv(params, out)));
```

If exports must be consistent snapshots and take more than one query, run the callback's
transaction at `REPEATABLE READ`. Keep the formatting algorithm (column planning,
quoting, row expansion) in one pure, isolated class — it is usually the most fiddly
pure-logic code in the service.

## Schema and migrations

### DDL pattern

Declare the spec's semantics in the schema — deliberately named constraints, delete
behavior as FK actions, indexes matching the list ordering:

```sql
CREATE TABLE widgets (
    id         uuid        NOT NULL,
    name       text        NOT NULL,
    created_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL,
    CONSTRAINT pk_widgets PRIMARY KEY (id),
    CONSTRAINT uq_widgets_name UNIQUE (name)
);
CREATE INDEX ix_widgets_page ON widgets (created_at, id);
```

```sql
CONSTRAINT fk_edges_from FOREIGN KEY (from_id)
    REFERENCES widgets (id) ON DELETE CASCADE,
CONSTRAINT fk_edges_type FOREIGN KEY (type_id)
    REFERENCES widget_types (id) ON DELETE RESTRICT
```

CASCADE where the spec says dependents die with the parent; RESTRICT where the spec says
deleting an in-use definition is a 409 — the RESTRICT violation surfaces through the
constraint registry ("Error translation" above) as exactly that 409, with no service
code. Constraint names are API; name every one.

### Flyway and the expand/contract rule

- `resources/db/migration/V001__baseline.sql` onward; the service migrates **only its
  own schema**.
- Execution (D7): `spring.flyway.enabled=false` in the default (prod-shaped) profile,
  `true` in `dev`/`test`/`migrate`. Production migrations run as a discrete deploy step
  using the same artifact — e.g. a `migrate` profile that also sets
  `spring.main.web-application-type=none`: the context starts, Flyway runs as bean
  initialization, the JVM exits. One artifact, two modes; whatever performs the deploy
  migrates before it ships traffic ("Packaging and runtime" below).
- **Expand/contract, always** — deploys overlap instances, so a schema change must be
  compatible with the previous release: add-and-backfill in release N, switch reads in
  N, drop in N+1. A destructive migration in the same release that stops using the
  column is the classic self-inflicted outage; make it a review rule, not a memory.

## Configuration and profiles

Prod-shaped by default so dev/test opt *out* of strictness rather than prod opting in:

```yaml
# application.yaml — the default IS production shape; only env vars vary
spring:
  threads.virtual.enabled: true               # sensible for IO-bound MVC services
  mvc.problemdetails.enabled: true
  flyway.enabled: false                       # prod migrates via the deploy step ("Flyway and the expand/contract rule")
  # No spring.datasource.* in any profile: the platform injects SPRING_DATASOURCE_URL /
  # _USERNAME / _PASSWORD (or its secretless equivalent) and Boot binds them natively.
app:
  cursor:
    secret: ${CURSOR_HMAC_SECRET}             # only if the spec paginates by cursor
  pagination: { default-size: 50, max-size: 200 }   # mirror the spec's numbers
---
spring.config.activate.on-profile: dev       # developer behaviour only; no datasource here either
spring.flyway.enabled: true
app.cursor.secret: dev-cursor-secret
---
spring.config.activate.on-profile: test      # mirrors dev; the DataSource comes from TestDatabase
spring.flyway.enabled: true
app.cursor.secret: test-cursor-secret
---
spring.config.activate.on-profile: migrate   # serves no traffic, so nothing signs a cursor
spring: { main.web-application-type: none, flyway.enabled: true }
app.cursor.secret: unused-in-migrate-mode
```

Where the database lives is a property of the machine, not of a profile, so no profile names
one — dev included. `TestDatabase` supplies it for the suite and for `spring-boot:test-run`;
a developer wanting durable data injects the same environment variables production uses.

Keeping the connection out of the default document is also what lets the test seam work.
Pinning `url: ${JDBC_URL}` with no default breaks it: `DataSourceProperties` is bound during
eager singleton initialization and dies on the unresolved placeholder before the test's own
`DataSource` is ever consulted. A static placeholder like `CURSOR_HMAC_SECRET` is fine by
contrast, because a profile can override it with a literal — the connection cannot, since its
port is only known once the test server starts.

All knobs live in validated `@ConfigurationProperties` records (`@Validated`, fail at
startup, not on first request). No `@Value` scattered through classes. Secrets arrive
through the environment or the platform's secret mechanism — never in files. Keep
springdoc on in dev, off in prod (`springdoc.api-docs.enabled=false`) unless the
document is deliberately public.

## Packaging and runtime

- **Image:** Jib (no Dockerfile, reproducible layers), `eclipse-temurin:<LTS>-jre` base,
  `-XX:MaxRAMPercentage=75` in `jvmFlags`. One image serves both modes (serve /
  `migrate`). Build once, promote the same digest through environments — never rebuild
  per environment.
- **Runtime:** wire orchestrator health checks to Actuator's liveness/readiness groups,
  with a startup window generous enough for JVM cold start. Structured JSON logs to
  stdout with trace correlation, carrying ids and counts — never payload values, never
  tokens.
- **Release order:** migrate, then ship traffic to the new version — whatever runs the
  deploy. Prefer a runtime whose rollback is a traffic shift to the previous version,
  which is exactly why the expand/contract rule above is absolute: the previous release
  must always still work against the current schema. There is no "rollback migration";
  there is forward-fix.

How the contract suite gets run outside a developer's machine, and whether anything gates
a merge on it, is left to the organization.

### Write down how to run it

A service completed this way has several run modes and none of them are guessable from the
source: a dev server backed by a throwaway database, a suite that provisions its own engine,
a migrate mode that is the same artifact with a profile, and an image built without a
Dockerfile. Put them in the repository's `README.md`, creating one if the scaffold left
none, and cover at least:

- **the live server** — the `spring-boot:test-run` command, that it needs no database of
  one's own, and that its data is gone on restart
- **the tests** — the command, and that the engine is provisioned automatically
- **bring your own database** — the environment variables to set, being the same ones
  production uses
- **migrations** — that they are a discrete step in the deployed environments, with the
  command for the `migrate` profile
- **the image** — the build command and what it produces

Run every command before writing it down. A README is worth having only if its commands
work, and these are exactly the ones a reader cannot verify by reading the code.

## Points the concrete spec decides (read these off the scaffold, don't re-decide)

The scheme above covers every structural decision. These leaf behaviors vary per
service and are answered by the ingested spec / the scaffold that encodes it:

| Point | Where to read it |
|---|---|
| Pagination flavor and its envelope | The scaffold's list DTO: `PageResponse` vs cursor envelope |
| Out-of-range page size: clamp vs 400 | The parameter's spec description + the scaffold's test |
| Explicit-null in merge-PATCH | Scaffold's `RequestBodyAdvice` presence + its tests |
| Malformed path id: 400 vs 404 | The scaffold's malformed-id test |
| Problem `type` values and field-error shape (`errors[]` vs `detail`) | `OpenApiConfig` components + the spec's error examples |
| Uniqueness violation status and case-sensitivity | Spec's conflict responses → constraint + registry entry |
| Dangling in-body reference status | Spec (400 vs 404 vs 409) → pre-check + FK backstop |
| Delete semantics: cascade vs refuse-in-use | Spec → FK actions ("DDL pattern") |
| Value grammars / immutable members | Spec prose → service validators ("Service layer") |
| Export/report formats | Spec's operation description → the pure formatter class ("Large responses") |
| Public URL prefix | Interfaces' `@RequestMapping`, from the spec's `servers` + paths |
