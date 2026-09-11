# Reference: conventions and mapping tables

## Package layout

Under a single package root (e.g. `com.example.widgets`):

```
api/            Contract interfaces (XxxApi) — the only place with HTTP annotations
api/dto/        Record DTOs (XxxRequest, XxxResponse, XxxDto for shared/nested, PageResponse)
web/            @RestController implementations + GlobalExceptionHandler (not scaffolded by default)
service/        Application logic + service/exception/ domain exceptions (not scaffolded by default)
config/         OpenApiConfig (API metadata + shared error components)
```

## Contract interface rules

All annotations sit on the interface; implementations inherit the mappings.

```java
@Tag(name = "Widgets", description = "One sentence on the resource.")
@RequestMapping("/api/v1/widgets")
public interface WidgetApi {

    @Operation(summary = "Create a widget", description = "Longer prose from the spec.")
    @ApiResponse(responseCode = "201", description = "The widget was created.",
            content = @Content(mediaType = "application/json",
                    schema = @Schema(implementation = WidgetResponse.class)))
    @ApiResponse(responseCode = "400", ref = "#/components/responses/ValidationFailed")
    @ResponseStatus(HttpStatus.CREATED)
    @PostMapping
    ResponseEntity<WidgetResponse> create(
            @io.swagger.v3.oas.annotations.parameters.RequestBody(
                    required = true, description = "The widget to create.")
            @Valid @RequestBody WidgetRequest request);
}
```

- **Method names** come from `operationId`, camelCased, with the resource stripped when
  the interface already scopes it (`createWidget` on `WidgetApi` → `create`). No
  `operationId`: derive from verb + path (`list`, `get`, `create`, `replace`, `delete`).
- **Return `ResponseEntity<T>`** (`ResponseEntity<Void>` for 204). Also declare
  `@ResponseStatus` for non-200 success codes — it is what springdoc reads as the
  success status; the implementation still sets it on the `ResponseEntity`.
- Swagger's request-body annotation clashes with Spring's `@RequestBody`; use the
  fully-qualified `@io.swagger.v3.oas.annotations.parameters.RequestBody(...)` inline,
  next to Spring's, as above.
- Every parameter gets `@Parameter(description = ...)` (with `example` where the spec
  has one) and an **explicit binding name**: `@PathVariable("id")`,
  `@RequestParam(name = "page", defaultValue = "0")`. Spec parameter defaults become
  `defaultValue`.
- Error responses are **never described inline** — always
  `@ApiResponse(responseCode = "404", ref = "#/components/responses/NotFound")` pointing
  at the shared components (below). Success responses are described inline.
- The mount prefix belongs in each interface's `@RequestMapping`, in full — the app's paths
  must be identical to its public paths, so nothing downstream ever strips a prefix.
- **Choosing that prefix is a deployment decision, and it has to be a safe one.** A spec
  that keeps the base path in its `servers` URL rather than its `paths` is saying so
  outright. If the API shares an origin with anything else — an SPA above all — mount it
  under a segment reserved for APIs and nothing else, never a bare resource-shaped path:
  `/widgets/v1` competes with every client-side route the app might want, and "the router
  may not use a path whose second segment is `v1`" is an unwritten rule nobody remembers.
  A reserved first segment also gives the origin one place to hang the rules that hold for
  every API and never for the app — cache directives, WAF scope, CSP `connect-src`, and
  whether an unknown path answers JSON or `index.html`. Keep the version inside the
  reservation and per service (`/api/<service>/v1`, not `/api/v1/<service>`) so
  independently deployed services never share a version number. A separate API subdomain
  also avoids the collisions, at the cost of same-origin and the price of CORS. Default to
  `/api/<service>/v1` when the spec gives you nothing.
- Hold the prefix in **one constant** the interfaces concatenate (`ApiPaths.V1 +
  "/widgets"`), never a literal repeated per interface: moving the mount point is not a
  contract change, so it should be a single edit. Not `server.servlet.context-path`, which
  drags actuator and the health probes along and hides the prefix from MockMvc, leaving the
  suite exercising paths no client can call. Properties that repeat the prefix —
  `springdoc.api-docs.path` — cannot read a Java constant, so keep them in step by hand and
  say so where they are written.

## OpenAPI schema → Java type mapping

| OpenAPI | Java |
| --- | --- |
| `string` | `String` |
| `string` format `uuid` | `java.util.UUID` |
| `string` format `date` | `java.time.LocalDate` |
| `string` format `date-time` | `java.time.OffsetDateTime` |
| `string` format `uri` | `java.net.URI` |
| `string` format `byte` | `byte[]` |
| `string` + `enum` | Java `enum` (see below) |
| `integer` format `int32` | `int` / `Integer` |
| `integer` format `int64` or no format | `long` / `Long` |
| `number` | `java.math.BigDecimal` (`double` only for format `double`) |
| `boolean` | `boolean` / `Boolean` |
| `array` | `List<T>` (`Set<T>` when `uniqueItems: true`) |
| `object` with `properties` | a record |
| `object` with `additionalProperties: S` | `Map<String, S>` |
| `oneOf` + `discriminator` | sealed interface, one record per branch, `@JsonTypeInfo`/`@JsonSubTypes` |
| `allOf` | flatten into a single record |
| `anyOf` | rarely maps cleanly — surface to the user |
| `$ref` | the referenced type |

Primitive vs boxed: primitive when the field is required and non-nullable, boxed
otherwise. Enum constants match the wire values when they are valid Java names;
otherwise annotate constants with `@JsonProperty("wire-value")`
(`com.fasterxml.jackson.annotation` — unchanged in Jackson 3).

## Record DTO rules

- Request body schema → `XxxRequest`; response schema → `XxxResponse`; shared/nested
  value objects keep their schema name or take a `Dto` suffix on collision. Never one
  record serving both directions — `readOnly` fields (server-assigned ids, timestamps)
  exist only in the response record.
- Class-level `@Schema(description = ...)` summarising the payload, including any
  cross-field validation rules from the spec's description.
- Field-level `@Schema` on **every** component:
  - `required` → `requiredMode = Schema.RequiredMode.REQUIRED`
  - optional with a default → `requiredMode = NOT_REQUIRED, defaultValue = "..."` (a spec
    default of `''` cannot be expressed — see "Generated-document pitfalls")
  - nullable (3.0 `nullable: true`; 3.1/3.2 `type: ["string", "null"]`) →
    `nullable = true` + a boxed/reference type
  - `readOnly` → `accessMode = Schema.AccessMode.READ_ONLY`
  - carry `description`, `example`, and structural facts (`maxLength`, `pattern`, …) so
    the generated document round-trips the spec.
- **Constraint enforcement** is a service-layer concern in this style: the service
  throws a domain `ValidationException` carrying field-level errors as JSON Pointers
  (`/values/1`), which the handler renders into the problem body's `errors[]` array.
  This keeps one uniform error shape for structural *and* domain rules. Keep `@Valid`
  on the interface's `@RequestBody` regardless — Bean Validation annotations on records
  are an acceptable complement for purely structural rules, but document the constraint
  in `@Schema` either way. The contract tests assert the 400 behaviour; the (future)
  implementation must honour it.

## Merge-style updates (PATCH)

A merge-patch spec ("a member present is set, a member absent is unchanged") forces a
three-way distinction that **records cannot express**: Jackson binds a missing creator
property and an explicitly null one identically, so `{}` and `{"name": null}` deserialize
to the same record. Verified on Jackson 3 — both
`DeserializationFeature.FAIL_ON_NULL_CREATOR_PROPERTIES` and
`@JsonSetter(nulls = Nulls.FAIL)` reject the *absent* case too, so neither implements the
rule; they turn a legal `{}` no-op into a 400.

Decide up front what the spec says about an explicitly null member:

- **Rejected (400)** — enforce it once at the request boundary, over the raw JSON tree, in
  a `RequestBodyAdvice` that buffers the body and names the offending member in the problem
  `detail` (`fields[0].value.price: …`, matching whatever path style the spec's own error
  examples use). This is **in scope**: without it the contract test asserting that 400
  cannot pass, which breaks this skill's promise that the tests pass unchanged once the
  middle layer lands. Let malformed JSON fall through to the message converter so it keeps
  reporting in its own terms.
- **Means "delete this member"** — a `JsonNullable`-style wrapper per member is the honest
  mapping; surface the extra dependency to the user before adding it.
- **Not mentioned** — leave the members plain-nullable and say so in the report.

Update DTOs stay plain records with nullable components either way: null-handling policy
never leaks into the record shape.

An immutable property the spec deliberately omits from its update schema but still
validates (`primitive` equal to the stored value tolerated, anything else a 409) has to be
bound to be checked. Bind it and mark it `@Schema(hidden = true)`, so the documented schema
still matches the spec, with a class javadoc saying why.

## Error model — RFC 9457 everywhere

Every error body is `application/problem+json` built on Spring's `ProblemDetail`.

- Set `spring.mvc.problemdetails.enabled=true` so framework-generated errors (malformed
  JSON, unparseable UUID/enum, 404 on unknown paths) are problem details too.
- When the project has no error model of its own (see the Deliverable in
  [SKILL.md](SKILL.md) — the test is the absence of a `@RestControllerAdvice`, not the age
  of the project): add one translating domain exceptions, handling client errors (4xx) only
  and logging them at `DEBUG`; leave 5xx to Spring's default handling (already logged)
  rather than a broad catch-all:

```java
@RestControllerAdvice
public class GlobalExceptionHandler {

    private static final String TYPE_BASE = "https://errors.example.com/";

    @ExceptionHandler(NotFoundException.class)
    ProblemDetail handleNotFound(NotFoundException ex) {
        return problem(HttpStatus.NOT_FOUND, "not-found", "Not Found", ex.getMessage());
    }

    @ExceptionHandler(ValidationException.class)
    ProblemDetail handleValidation(ValidationException ex) {
        ProblemDetail problem =
                problem(HttpStatus.BAD_REQUEST, "validation", "Validation failed", ex.getMessage());
        if (!ex.getErrors().isEmpty()) {
            problem.setProperty("errors", ex.getErrors());
        }
        return problem;
    }

    private static ProblemDetail problem(
            HttpStatus status, String typeSlug, String title, String detail) {
        ProblemDetail problem = ProblemDetail.forStatusAndDetail(status, detail);
        problem.setType(URI.create(TYPE_BASE + typeSlug));
        problem.setTitle(title);
        return problem;
    }
}
```

- Declare the problem shapes **once** in `OpenApiConfig` as `components.schemas`
  (`ProblemDetail`, plus `allOf` extensions like `ValidationProblemDetail` adding
  `errors[]`) and `components.responses` (`NotFound`, `BadRequest`, `ValidationFailed`,
  conflict responses per spec) — see the trimmed example in
  [examples.md](examples.md). Interfaces reference them by `ref`; if the ingested spec
  already defines equivalent components, mirror *its* names.
- Extra members (like `errors`) go on via `problem.setProperty(...)`.
- The snippet above is a default, not a mandate. If the spec pins the problem `type` — v1
  APIs commonly fix it at `about:blank` and distinguish cases in `detail` — mirror that and
  invent no type URIs; likewise carry field detail in `detail` rather than an `errors[]`
  array when that is what the spec's error examples show. Spring's `ProblemDetail` already
  defaults `type` to `about:blank`; set `title` from `status.getReasonPhrase()` if the spec
  says the title is the reason phrase.
- Framework client errors need policy the spec usually pins. Spring answers an unparseable
  id with 400, but many specs make an invalid path id indistinguishable from an unknown one,
  i.e. 404, while the same failure in a *query filter* stays a 400. To get both, handle
  `MethodArgumentTypeMismatchException` in an advice annotated
  `@Order(Ordered.HIGHEST_PRECEDENCE)` — so it wins over Spring's built-in problem-details
  advice — and branch on
  `ex.getParameter().hasParameterAnnotation(PathVariable.class)`.

## Pagination

Spec-defined `page`/`size` query parameters + a page envelope map to one shared record:

```java
public record PageResponse<T>(
        List<T> items, int page, int size, long totalElements, int totalPages) { }
```

(with `@Schema` on each field, but **no class-level `@Schema(name = ...)`** — naming a
generic envelope collapses all of its parameterizations into one schema; see
"Generated-document pitfalls"). Interfaces return
`ResponseEntity<PageResponse<XxxResponse>>`. Document clamping semantics from the spec
(e.g. "size defaults to 50, max 200 — clamped, not rejected") in `@Parameter`.
If the spec paginates differently (cursor, offset/limit), mirror the spec — do not
force this envelope.

## Contract tests

Full-context tests, one class per interface, named `XxxApiTest`, in the test-tree
`api/` package. Shared plumbing goes in an abstract base (see
[examples.md](examples.md)): `@SpringBootTest` + `@AutoConfigureMockMvc`, an
`ObjectMapper`, `postJson`/`putJson` builders, and a `createAndReturnId` helper.

Per-operation coverage:

| Operation | Assert |
| --- | --- |
| POST create | 201 + response body shape via `jsonPath` (id present, fields echoed, defaults applied); one 400 per violated required field/constraint; the spec's status for dangling `$ref`-style references in the body; `Location` when the spec declares it |
| GET by id | 200 + body shape; 404 for an unknown id; for a *malformed* id, whatever the spec says — 400 by Spring's default, but 404 when the spec makes an invalid id indistinguishable from an unknown one |
| GET list | 200 + the spec's own page envelope; out-of-range and undecodable pagination parameters |
| PUT replace | 200 + replaced fields visible; anything the spec says is *not* replaced stays unchanged |
| PATCH merge | 200 with present members set and absent ones unchanged; `{}` as a no-op if the spec says so; array-valued members replaced wholesale; the spec's verdict on an explicitly null member (see "Merge-style updates") |
| DELETE | 204, then re-GET returns 404; documented cascades (a deleted parent's dependents are gone, untouched neighbours still 200); spec-defined conflicts (409 + problem body members) |

The statuses above are defaults; where the spec disagrees, follow the spec.

Also assert `application/problem+json` as the content type on at least one error test.
Keep tests black-box: status, headers, JSON body — nothing else.

Some faithful tests send bodies no DTO can express — an explicitly null member, a
wrongly-typed value — so the shared base needs raw-string builders (`postRaw`, `patchRaw`)
beside the object-serializing ones.

That split only holds if the object-serializing path **omits null members**. A record
component has no way to say "absent" other than being null, so a `json()` helper that writes
`"member": null` collapses the two paths: every "member omitted" test silently becomes an
"explicit null" test. On a spec that rejects nulls — and this skill's own merge-PATCH advice
produces exactly that — the entire create suite is then unsatisfiable no matter how correct
the implementation, and the failure looks like an implementation bug rather than a helper bug.
Set the inclusion on the helper only ([examples.md](examples.md)), never on the application's
mapper: responses must still be able to carry an explicit null for a required-and-nullable
member such as a page envelope's `next_cursor`.

Cross-resource setup (an item that first needs a field type) goes through the API under test
rather than fixtures, which keeps the tests black-box and exercises more of the contract.

**Red is the intended starting state.** With no implementing controller the endpoints
404 and most tests fail. That is the test-first contract: they must pass *unchanged*
once the implementation lands. Never weaken an assertion, stub a controller, or skip a
test to force green; report the red state and its reason instead.

If the project has profile-scoped security, run the suite under the permissive profile
(`@ActiveProfiles("test")` on the base class). Greenfield scaffolds add **no** security
enforcement; the spec's `securitySchemes` are documented in `OpenApiConfig` (bearer
scheme + global security requirement) and enforcement is called out as a follow-up.

## Generated-document pitfalls

All of these were observed with springdoc 3.1 / swagger-core 2.2 while diffing a generated
document against its source spec. They fail *silently* — the code compiles, the runtime
behaves, only the document is wrong — which is why step 8 exists:

- **`@Schema(name = ...)` on a generic envelope** collapses every parameterization into a
  single schema, last one winning. Leave the name off `PageResponse<T>` / `CursorPage<T>`
  so the per-type names (`PageResponseWidget`, `CursorPageItem`) are derived.
- **`@ApiResponse` with `@Content(mediaType = ...)` but no `schema`** emits empty content
  and discards the inferred return type. For a generic return type you cannot name in
  `implementation`, drop the `@Content` and declare `produces` on the mapping instead —
  which also stops the response media type rendering as `*/*`. Declare `consumes` on
  POST/PATCH for the same reason.
- **`@Schema(ref = "#/components/schemas/X")` on a property** kills schema generation for
  the enclosing record *and* every schema referencing it: they vanish from `components`
  with no warning. Reference shared schemas by property *type*, not by `ref`.
- **A discriminator-less `oneOf` keeps only the branches swagger-core can resolve**; a
  branch whose Java type is a `@JsonValue` map is dropped, leaving a union that silently
  documents half the contract. Let the annotation generate the skeleton and finish the
  union in an `OpenApiCustomizer` bean that rewrites `oneOf` on that named schema.
- **`@Schema(defaultValue = "")` is indistinguishable from unset**, so a spec default of
  `''` cannot be expressed at all. Carry it in the description and report the gap.
- A benign `Json Processing Exception … HashSet … ('integer')` warning appears once per
  integer-typed query parameter during generation; the emitted parameter schema is complete
  regardless. Don't chase it.

## Spring Boot 4 gotchas

Verified against Boot 4.x / Spring Framework 7 — do not substitute Boot 3.x idioms:

- **Jackson 3**: `ObjectMapper` is `tools.jackson.databind.ObjectMapper` (not
  `com.fasterxml.jackson.databind`). Annotations (`@JsonProperty`, `@JsonTypeInfo`, …)
  remain in `com.fasterxml.jackson.annotation`.
- **MockMvc testing**: dependency `spring-boot-starter-webmvc-test`;
  `@AutoConfigureMockMvc` lives in `org.springframework.boot.webmvc.test.autoconfigure`.
- `@MockBean` is gone; the replacement is `@MockitoBean`
  (`org.springframework.test.context.bean.override.mockito`) — only relevant if the
  user asks for slice tests.
- **springdoc**: the 3.x line targets Boot 4 / Framework 7 / Jackson 3; the dependency
  is `org.springdoc:springdoc-openapi-starter-webmvc-ui`.
- **but springdoc's model resolution still runs on Jackson 2**: `swagger-core-jakarta`
  pulls `com.fasterxml.jackson.core:jackson-databind:2.x` alongside the app's Jackson 3, so
  the doc generator never sees the runtime `ObjectMapper`. Consequence: Jackson
  configuration does not reach the generated document — a
  `spring.jackson.property-naming-strategy=SNAKE_CASE` API documents itself as camelCase.
  Put wire names in `@JsonProperty`, which lives in the shared `jackson-annotations`
  artifact and is therefore the one thing both generations read, and keep the naming
  strategy as the runtime-wide rule for members added later.
- **Bean Validation on interface parameters works**: `@Min`/`@Max` declared on an
  interface method's `@RequestParam` yields a 400 with no `@Validated` anywhere, and
  `@Valid @RequestBody` cascades into records and their container elements
  (`List<@Valid Field>`).
- **Enum query parameters bind exact-case.** Spring's `String`-to-enum conversion is
  `Enum.valueOf`, and neither `@JsonProperty` nor `@JsonValue` affects parameter binding, so
  a spec enum with lowercase wire values (`role=from`) needs a `Converter<String, TheEnum>`
  bean — Boot registers converter beans into the MVC conversion service automatically.
  Pin the documented values with `@Parameter(schema = @Schema(allowableValues = {...}))`.

Greenfield `pom.xml` skeleton (resolve current stable versions first — see SKILL.md):

```xml
<parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version><!-- current stable Boot --></version>
    <relativePath/>
</parent>
<properties>
    <java.version><!-- latest LTS, e.g. 25 --></java.version>
    <springdoc.version><!-- current 3.x --></springdoc.version>
</properties>
<dependencies>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-web</artifactId></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-validation</artifactId></dependency>
    <dependency><groupId>org.springdoc</groupId><artifactId>springdoc-openapi-starter-webmvc-ui</artifactId><version>${springdoc.version}</version></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-test</artifactId><scope>test</scope></dependency>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-webmvc-test</artifactId><scope>test</scope></dependency>
</dependencies>
```

## Spec-version notes (3.0 / 3.1 / 3.2)

- **3.0**: nullability via `nullable: true`; no type arrays.
- **3.1**: full JSON Schema 2020-12 — nullability via `type: ["string", "null"]`;
  `webhooks` top-level (out of scope for an MVC scaffold; report it).
- **3.2**: adds `additionalOperations` (custom HTTP methods such as `QUERY`),
  streaming media types via `itemSchema` (SSE/JSONL), hierarchical tags (`parent` /
  `kind` — group by the leaf tag name), and `$self`. Map what Web MVC supports;
  list the rest as out of scope in the report rather than approximating.

The flow is identical across versions; only schema-detail handling differs.

## API versioning discipline (recommended)

Keep three version axes independent — bumping one implies nothing about the others:

| Axis | Where | Meaning |
| --- | --- | --- |
| URL major (`/api/v1`) | route prefix | namespace for an incompatible surface reshape; new `/v2` is added *alongside* (additive), removing an old prefix is the break |
| Contract version (semver) | OpenAPI `info.version` | backward-compatibility of everything the document currently serves |
| Build/artifact version | `pom.xml` `<version>` | which build is running; carries no compatibility meaning (CalVer works well) |

Seed `info.version` in `OpenApiConfig` from the ingested spec's `info.version`.

## When openapi-generator is the better tool

Prefer `openapi-generator-maven-plugin` (`spring` generator, `interfaceOnly=true`) over
this skill's hand-written flow only when the org **requires machine-enforced sync**
between spec and code on every build, or the spec is huge and churns constantly. Note the
cheaper middle option first: once controllers exist, a CI job that boots the app and diffs
`/v3/api-docs` against the checked-in spec catches drift without codegen.
Trade-off: non-idiomatic output (no records-with-`@Schema` style, no shared `$ref`
error components) and no tests — the contract-test conventions above still apply on
top. Ask the user before going that route.
