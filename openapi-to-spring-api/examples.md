# Worked example: widget spec → contract + tests

One small resource end to end. The input is OpenAPI 3.2.0; the flow is identical for
3.0/3.1 (only nullability syntax differs — see reference.md).

## Input spec

```yaml
openapi: 3.2.0
info:
  title: Widget Service API
  version: 1.0.0
tags:
  - name: Widgets
    description: Widgets and their lifecycle.
paths:
  /api/v1/widgets:
    get:
      operationId: listWidgets
      tags: [Widgets]
      summary: List widgets
      parameters:
        - name: page
          in: query
          schema: { type: integer, format: int32, default: 0 }
        - name: size
          in: query
          description: Page size; values above 200 are clamped, not rejected.
          schema: { type: integer, format: int32, default: 50, maximum: 200 }
      responses:
        "200":
          description: A page of widgets.
          content:
            application/json:
              schema: { $ref: "#/components/schemas/WidgetPage" }
    post:
      operationId: createWidget
      tags: [Widgets]
      summary: Create a widget
      requestBody:
        required: true
        content:
          application/json:
            schema: { $ref: "#/components/schemas/WidgetRequest" }
      responses:
        "201":
          description: The widget was created.
          content:
            application/json:
              schema: { $ref: "#/components/schemas/Widget" }
        "400": { $ref: "#/components/responses/ValidationFailed" }
  /api/v1/widgets/{id}:
    parameters:
      - name: id
        in: path
        required: true
        schema: { type: string, format: uuid }
    get:
      operationId: getWidget
      tags: [Widgets]
      summary: Fetch a widget
      responses:
        "200":
          description: The widget.
          content:
            application/json:
              schema: { $ref: "#/components/schemas/Widget" }
        "404": { $ref: "#/components/responses/NotFound" }
    delete:
      operationId: deleteWidget
      tags: [Widgets]
      summary: Delete a widget
      responses:
        "204": { description: The widget was deleted. }
        "404": { $ref: "#/components/responses/NotFound" }
components:
  schemas:
    Widget:
      type: object
      required: [id, name, status, createdAt]
      properties:
        id: { type: string, format: uuid, readOnly: true }
        name: { type: string, maxLength: 120, example: Flux capacitor }
        status: { $ref: "#/components/schemas/WidgetStatus" }
        createdAt: { type: string, format: date-time, readOnly: true }
    WidgetRequest:
      type: object
      required: [name]
      properties:
        name: { type: string, maxLength: 120, example: Flux capacitor }
        status: { $ref: "#/components/schemas/WidgetStatus", default: ACTIVE }
    WidgetStatus:
      type: string
      enum: [ACTIVE, RETIRED]
    WidgetPage:
      type: object
      properties:
        items:
          type: array
          items: { $ref: "#/components/schemas/Widget" }
        page: { type: integer, format: int32 }
        size: { type: integer, format: int32 }
        totalElements: { type: integer, format: int64 }
        totalPages: { type: integer, format: int32 }
    ProblemDetail:
      type: object
      properties:
        type: { type: string, format: uri }
        title: { type: string }
        status: { type: integer, format: int32 }
        detail: { type: string }
  responses:
    NotFound:
      description: The addressed resource does not exist.
      content:
        application/problem+json:
          schema: { $ref: "#/components/schemas/ProblemDetail" }
    ValidationFailed:
      description: The request violates a documented constraint.
      content:
        application/problem+json:
          schema: { $ref: "#/components/schemas/ProblemDetail" }
```

## Plan

One tag → one interface (`WidgetApi`) + one test class (`WidgetApiTest`). Renames per
the DTO rules: response schema `Widget` → `WidgetResponse` record; `WidgetPage` → the
generic `PageResponse<T>` envelope. The spec's `ProblemDetail` schema and `NotFound` /
`ValidationFailed` responses are mirrored into `OpenApiConfig` under the same names, so
the interface's `ref = "#/components/responses/..."` round-trips.

## Records — `api/dto/`

```java
package com.example.widgets.api.dto;

public enum WidgetStatus {
    ACTIVE,
    RETIRED
}
```

```java
package com.example.widgets.api.dto;

import io.swagger.v3.oas.annotations.media.Schema;

@Schema(description = "Write representation of a widget.")
public record WidgetRequest(
        @Schema(description = "The widget name.", example = "Flux capacitor",
                requiredMode = Schema.RequiredMode.REQUIRED, maxLength = 120)
        String name,

        @Schema(description = "Lifecycle status.",
                requiredMode = Schema.RequiredMode.NOT_REQUIRED, defaultValue = "ACTIVE")
        WidgetStatus status) {
}
```

```java
package com.example.widgets.api.dto;

import io.swagger.v3.oas.annotations.media.Schema;
import java.time.OffsetDateTime;
import java.util.UUID;

@Schema(description = "Read representation of a widget.")
public record WidgetResponse(
        @Schema(description = "Server-assigned id.", accessMode = Schema.AccessMode.READ_ONLY,
                example = "7b9d6c1e-2f3a-4b5c-8d9e-0a1b2c3d4e5f")
        UUID id,

        @Schema(description = "The widget name.", example = "Flux capacitor", maxLength = 120)
        String name,

        @Schema(description = "Lifecycle status.")
        WidgetStatus status,

        @Schema(description = "Creation instant.", accessMode = Schema.AccessMode.READ_ONLY)
        OffsetDateTime createdAt) {
}
```

```java
package com.example.widgets.api.dto;

import io.swagger.v3.oas.annotations.media.Schema;
import java.util.List;

@Schema(description = "The offset-pagination envelope shared by all list endpoints.")
public record PageResponse<T>(
        @Schema(description = "The page of results.")
        List<T> items,

        @Schema(description = "Zero-based page index.", example = "0")
        int page,

        @Schema(description = "Page size.", example = "50")
        int size,

        @Schema(description = "Total matching elements across all pages.", example = "137")
        long totalElements,

        @Schema(description = "Total number of pages.", example = "3")
        int totalPages) {
}
```

## Mount prefix — `api/ApiPaths.java`

```java
package com.example.widgets.api;

/**
 * Where this service mounts under the platform origin. The spec keeps the prefix out of its
 * paths and carries it in the server URL, because it belongs to the deployment rather than to
 * the API: one origin serves the app at {@code /} and reserves {@code /api} for services, so no
 * API path can collide with a client-side route and one set of edge rules covers every service.
 */
public final class ApiPaths {

    /** Base path of every operation in v1 of this API. */
    public static final String V1 = "/api/widgets/v1";

    private ApiPaths() {}
}
```

## Contract interface — `api/WidgetApi.java`

```java
package com.example.widgets.api;

import com.example.widgets.api.dto.PageResponse;
import com.example.widgets.api.dto.WidgetRequest;
import com.example.widgets.api.dto.WidgetResponse;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.Parameter;
import io.swagger.v3.oas.annotations.media.Content;
import io.swagger.v3.oas.annotations.media.Schema;
import io.swagger.v3.oas.annotations.responses.ApiResponse;
import io.swagger.v3.oas.annotations.tags.Tag;
import jakarta.validation.Valid;
import java.util.UUID;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.ResponseStatus;

@Tag(name = "Widgets", description = "Widgets and their lifecycle.")
@RequestMapping(ApiPaths.V1 + "/widgets")           // see ApiPaths below
public interface WidgetApi {

    @Operation(summary = "Create a widget")
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

    @Operation(summary = "List widgets", description = "Lists widgets, offset-paginated.")
    @ApiResponse(responseCode = "200", description = "A page of widgets.")
    @GetMapping
    ResponseEntity<PageResponse<WidgetResponse>> list(
            @Parameter(description = "Zero-based page index.", example = "0")
            @RequestParam(name = "page", defaultValue = "0") int page,
            @Parameter(description = "Page size; values above 200 are clamped, not rejected.",
                    example = "50")
            @RequestParam(name = "size", defaultValue = "50") int size);

    @Operation(summary = "Fetch a widget")
    @ApiResponse(responseCode = "200", description = "The widget.",
            content = @Content(mediaType = "application/json",
                    schema = @Schema(implementation = WidgetResponse.class)))
    @ApiResponse(responseCode = "404", ref = "#/components/responses/NotFound")
    @GetMapping("/{id}")
    ResponseEntity<WidgetResponse> get(
            @Parameter(description = "Widget id.") @PathVariable("id") UUID id);

    @Operation(summary = "Delete a widget")
    @ApiResponse(responseCode = "204", description = "The widget was deleted.")
    @ApiResponse(responseCode = "404", ref = "#/components/responses/NotFound")
    @ResponseStatus(HttpStatus.NO_CONTENT)
    @DeleteMapping("/{id}")
    ResponseEntity<Void> delete(
            @Parameter(description = "Widget id.") @PathVariable("id") UUID id);
}
```

## Shared components — `config/OpenApiConfig.java` (trimmed)

```java
package com.example.widgets.config;

import io.swagger.v3.oas.models.Components;
import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Info;
import io.swagger.v3.oas.models.media.Content;
import io.swagger.v3.oas.models.media.IntegerSchema;
import io.swagger.v3.oas.models.media.MediaType;
import io.swagger.v3.oas.models.media.ObjectSchema;
import io.swagger.v3.oas.models.media.Schema;
import io.swagger.v3.oas.models.media.StringSchema;
import io.swagger.v3.oas.models.responses.ApiResponse;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

/** API metadata plus the reusable error components that operations reference by $ref. */
@Configuration
public class OpenApiConfig {

    private static final String PROBLEM_JSON = "application/problem+json";
    private static final String SCHEMA_PROBLEM = "ProblemDetail";

    @Bean
    public OpenAPI widgetServiceOpenAPI() {
        return new OpenAPI()
                .info(new Info()
                        .title("Widget Service API")
                        // Contract version (semver), seeded from the ingested spec's info.version.
                        .version("1.0.0"))
                .components(new Components()
                        .addSchemas(SCHEMA_PROBLEM, problemDetailSchema())
                        .addResponses("NotFound", problemResponse(
                                "The addressed resource does not exist."))
                        .addResponses("ValidationFailed", problemResponse(
                                "The request violates a documented constraint.")));
    }

    private ApiResponse problemResponse(String description) {
        return new ApiResponse()
                .description(description)
                .content(new Content().addMediaType(PROBLEM_JSON, new MediaType()
                        .schema(new Schema<>().$ref("#/components/schemas/" + SCHEMA_PROBLEM))));
    }

    private Schema<?> problemDetailSchema() {
        return new ObjectSchema()
                .description("RFC 9457 problem detail.")
                .addProperty("type", new StringSchema().format("uri"))
                .addProperty("title", new StringSchema())
                .addProperty("status", new IntegerSchema().format("int32"))
                .addProperty("detail", new StringSchema());
    }
}
```

## Contract tests

Shared base (`src/test/java/com/example/widgets/AbstractWebApiTest.java`) — note the
Boot 4 imports (`tools.jackson`, `boot.webmvc.test.autoconfigure`):

```java
package com.example.widgets;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.fasterxml.jackson.annotation.JsonInclude;
import java.util.UUID;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.webmvc.test.autoconfigure.AutoConfigureMockMvc;
import org.springframework.http.MediaType;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import tools.jackson.databind.ObjectMapper;

/**
 * Base class for REST contract tests. Written test-first: until an implementing
 * {@code @RestController} layer exists the endpoints return 404 and these tests FAIL —
 * the intended TDD "red" state. Once implemented they must pass unchanged.
 */
@SpringBootTest
@AutoConfigureMockMvc
public abstract class AbstractWebApiTest {

    /**
     * The public path, spelled out rather than read from {@code ApiPaths}: the suite should pin
     * where clients actually call, so moving the mount point fails here instead of being
     * silently followed. A move is deliberately two edits.
     */
    protected static final String API = "/api/widgets/v1";

    @Autowired
    protected MockMvc mockMvc;

    @Autowired
    protected ObjectMapper objectMapper;

    /**
     * Serializes a request DTO with its null components omitted. A record component can only say
     * "absent" by being null, and absent is what these tests mean by it; a literal {@code null} on
     * the wire is a different request, and the tests that want one build it with {@link #postRaw}.
     *
     * <p>Deliberately not the application's own inclusion policy: a response still has to carry an
     * explicit null for any required-and-nullable member.
     */
    protected String json(Object value) {
        return requestMapper().writeValueAsString(value);
    }

    private ObjectMapper requestMapper() {
        return objectMapper.rebuild()
                .changeDefaultPropertyInclusion(i -> i.withValueInclusion(JsonInclude.Include.NON_NULL))
                .build();
    }

    protected MockHttpServletRequestBuilder postJson(String urlTemplate, Object body, Object... uriVars) {
        return postRaw(urlTemplate, json(body), uriVars);
    }

    /** Raw-body variant, for payloads no DTO can express: explicit nulls, wrong types. */
    protected MockHttpServletRequestBuilder postRaw(String urlTemplate, String rawJson, Object... uriVars) {
        return post(urlTemplate, uriVars).contentType(MediaType.APPLICATION_JSON).content(rawJson);
    }

    /** Perform a create request, assert 201, and return the id from the response body. */
    protected UUID createAndReturnId(MockHttpServletRequestBuilder request) throws Exception {
        String body = mockMvc.perform(request)
                .andExpect(status().isCreated())
                .andReturn()
                .getResponse()
                .getContentAsString();
        return UUID.fromString(objectMapper.readTree(body).get("id").asText());
    }
}
```

`src/test/java/com/example/widgets/api/WidgetApiTest.java`:

```java
package com.example.widgets.api;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.delete;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.content;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

import com.example.widgets.AbstractWebApiTest;
import com.example.widgets.api.dto.WidgetRequest;
import com.example.widgets.api.dto.WidgetStatus;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;

/** REST contract for widgets. */
class WidgetApiTest extends AbstractWebApiTest {

    private UUID createWidget(String name) throws Exception {
        return createAndReturnId(
                postJson(API + "/widgets", new WidgetRequest(name, WidgetStatus.ACTIVE)));
    }

    @Test
    void createReturns201WithBody() throws Exception {
        mockMvc.perform(postJson(API + "/widgets", new WidgetRequest("Flux capacitor", null)))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.id").isNotEmpty())
                .andExpect(jsonPath("$.name").value("Flux capacitor"))
                // status was omitted, so the spec's default applies
                .andExpect(jsonPath("$.status").value("ACTIVE"))
                .andExpect(jsonPath("$.createdAt").isNotEmpty());
    }

    @Test
    void rejectsWidgetWithoutName() throws Exception {
        mockMvc.perform(postJson(API + "/widgets", new WidgetRequest(null, WidgetStatus.ACTIVE)))
                .andExpect(status().isBadRequest());
    }

    @Test
    void rejectsNameLongerThan120() throws Exception {
        mockMvc.perform(postJson(API + "/widgets", new WidgetRequest("x".repeat(121), null)))
                .andExpect(status().isBadRequest());
    }

    @Test
    void getUnknownReturns404AsProblemJson() throws Exception {
        mockMvc.perform(get(API + "/widgets/{id}", UUID.randomUUID()))
                .andExpect(status().isNotFound())
                .andExpect(content().contentType(MediaType.APPLICATION_PROBLEM_JSON));
    }

    @Test
    void malformedIdReturns400() throws Exception {
        mockMvc.perform(get(API + "/widgets/{id}", "not-a-uuid"))
                .andExpect(status().isBadRequest());
    }

    @Test
    void listReturnsPaginationEnvelope() throws Exception {
        createWidget("Widget");

        mockMvc.perform(get(API + "/widgets"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.items").isArray())
                .andExpect(jsonPath("$.totalElements").isNumber());
    }

    @Test
    void deleteThenGetReturns404() throws Exception {
        UUID id = createWidget("Doomed");

        mockMvc.perform(delete(API + "/widgets/{id}", id)).andExpect(status().isNoContent());
        mockMvc.perform(get(API + "/widgets/{id}", id)).andExpect(status().isNotFound());
    }
}
```

## Delivered state

```
src/main/java/com/example/widgets/
  api/WidgetApi.java
  api/dto/{WidgetRequest,WidgetResponse,WidgetStatus,PageResponse}.java
  config/OpenApiConfig.java
src/test/java/com/example/widgets/
  AbstractWebApiTest.java
  api/WidgetApiTest.java
```

Everything compiles; the suite is red (endpoints 404) because no `@RestController`
implements `WidgetApi` yet — the intended test-first state. Implementing
`WidgetController implements WidgetApi` + a `WidgetService` (and the validation the
tests assert) turns it green without touching a single test.

The generated document was checked before handover per step 8: throwaway stubs implementing
`WidgetApi`, a temporary test printing `/v3/api-docs`, a diff against the spec above, then
both deleted. That pass is what confirms `PageResponse<WidgetResponse>` documents itself as
`PageResponseWidgetResponse` with `items` refs to `Widget`, that the 400/404 responses
render as `$ref`s to the shared components, and that the wire names match.
