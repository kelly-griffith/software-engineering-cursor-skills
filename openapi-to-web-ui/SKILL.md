---
name: openapi-to-web-ui
description: >-
  Ingests an OpenAPI specification (3.0/3.1/3.2 or Swagger 2.0, YAML or JSON,
  from a file, URL, or pasted text) and builds a polished web app over that API
  using a prescribed stack: Next.js App Router, TypeScript, Tailwind CSS,
  shadcn/ui, TanStack Query, and a typed client, query options, and Zod schemas
  generated from the spec. Bakes in evidence-based UI/UX: task-oriented page
  architecture, research-backed form design with spec-derived validation,
  loading/empty/error states, WCAG 2.2 AA accessibility, Core Web Vitals
  targets, SEO metadata on anonymously reachable routes, and a server-side
  proxy so API credentials never reach the browser. Use when the user provides
  an OpenAPI or Swagger spec and asks for a website, web app, frontend, UI,
  portal, storefront, dashboard, account area, or personal tool over it.
---

# OpenAPI to Web UI

Build a production-quality web app on top of an API described by an OpenAPI spec. Four standards hold on every route, and they are what this skill is for:

- **Accessibility to WCAG 2.2 AA** — launch-blocking, not polish (step 9). For consumer services sold into the EU it is also a legal requirement (European Accessibility Act, enforced since June 2025).
- **Fast first load** — server-rendered reads, Core Web Vitals as hard targets (step 8).
- **Credentials never in the browser** — anything secret stays behind a server-side proxy (step 7).
- **Information architecture that follows user tasks**, rather than mirroring the API's CRUD surface (step 2).

One per-route property decides exactly one thing: whether an anonymous visitor can load a route determines whether it is indexable (metadata, canonical URL, sitemap) or `noindex`. It never decides whether a route gets built, or to what standard — see step 8.

## Workflow

Copy this checklist and track progress:

```
Task Progress:
- [ ] 1. Ingest and validate the spec
- [ ] 2. Design the page map (task-oriented)
- [ ] 3. Scaffold the prescribed stack
- [ ] 4. Generate the API layer from the spec
- [ ] 5. Build the app shell
- [ ] 6. Build pages (browse, detail, forms)
- [ ] 7. Wire auth and credential handling
- [ ] 8. Performance everywhere, indexing where routes are anonymous
- [ ] 9. Accessibility pass (WCAG 2.2 AA)
- [ ] 10. Verify
```

## 1. Ingest and validate the spec

Accept the spec as a file path, URL, or pasted text. Save it into the project at `openapi/openapi.yaml` (or `.json`) so codegen is reproducible. Validate:

```bash
npx @redocly/cli@latest lint openapi/openapi.yaml
```

Redocly handles Swagger 2.0 through OpenAPI 3.2 and multi-file specs. Fix or report hard errors (broken refs, invalid schemas) before continuing; style warnings are fine to note and move on.

Build an inventory from the spec:

- **Resources**: group operations by tag and by path prefix (`/products`, `/products/{id}`).
- **Operations**: method, path, `operationId`, params, request/response schemas.
- **Schemas**: field types and constraints (`required`, `enum`, `minLength`, `pattern`, `format`) — these drive form validation later.
- **Auth**: `securitySchemes` and per-operation `security` (decides step 7).
- **Pagination**: page/limit vs cursor params on collection operations.
- **Filtering/search**: query params on collection operations.
- **Errors**: error response schemas (RFC 9457 problem+json or custom).

## 2. Design the page map (task-oriented)

Do not generate one page per endpoint. Users think in tasks ("find a product", "book a slot", "track my order"), so derive pages from what a visitor would do:

- `GET` collection → **browse page** with search, filters, sort, pagination. All of that state lives in the URL (shareable, back-button-safe, indexable).
- `GET` item → **detail page** with a clean URL (`/products/[id]` or slug if available).
- `POST`/`PUT`/`PATCH`/`DELETE` that an end user would trigger → **form, flow, or action** (sign up, submit review, create booking, delete my own record).
- Add a **home page** that orients visitors and routes them into the main tasks.

**What to exclude, and the test to use.** The question is *whose action is this*, not *how dangerous is it*. Exclude an operation only when the app's own user is not the party who performs it: admin-only tags, scopes or roles the user cannot hold, back-office reporting, operations acting on *other* users' data, machine-to-machine integration hooks. Note the exclusions to the user.

Do **not** exclude an operation merely because it writes or destroys. Users own their own data, and deleting or exporting it is a first-class end-user task — in the EU, an obligation rather than a nicety. An account app that cannot delete its own records is a broken app, not a safe one. Destructive operations that belong to the user get built, with the confirmation and cascade-warning treatment in step 6.

Also record, per route, whether an anonymous visitor can reach it. That single flag drives step 8 and nothing else; it does not decide whether the route gets built.

Decide render mode per page: reads that carry the first paint (browse, detail, home) render on the server, because SSR is what puts content in front of the user quickly — indexability is a bonus on the routes that happen to be anonymous, not the reason. Interactive refinement (filtering, form state) runs on the client via TanStack Query. Summarize the page map as a table (route, purpose, operations used, anonymous?, render mode) in your report.

## 3. Scaffold the prescribed stack

The stack is prescribed — don't offer alternatives unless a hard constraint rules it out (see "Escape hatches" in [reference.md](reference.md)):

| Layer | Choice | Why |
|---|---|---|
| Framework | Next.js (App Router, latest stable) | SSR/streaming carries first-load performance (LCP) on every route; the Metadata API then covers SEO wherever routes are indexable |
| Language | TypeScript, strict | End-to-end types from the spec to the component |
| Styling | Tailwind CSS v4 | Ships with create-next-app; design tokens via CSS variables |
| Components | shadcn/ui | Accessible primitives, owned in-repo, themeable |
| Server state | TanStack Query v5 | Caching, optimistic updates, SSR hydration |
| API layer | `@hey-api/openapi-ts` | Generates typed SDK + TanStack Query options + Zod schemas from the spec |
| Forms | react-hook-form + Zod v4 (`@hookform/resolvers`) | Spec-derived validation, accessible error wiring |
| Testing | Playwright + `@axe-core/playwright` | Smoke tests and automated WCAG scans |

Take the scaffold commands from [reference.md](reference.md) verbatim rather than from memory, and read its **"Known first-run failures"** table before running anything. Both the shadcn CLI and `@hey-api/openapi-ts` have changed in ways that fail confusingly — one of them silently — and that table converts each into a value to type instead of a round trip to spend. Pin `@hey-api/openapi-ts` to an exact version (`-E`): it is pre-1.0 and minor releases can change output.

## 4. Generate the API layer from the spec

Create `openapi-ts.config.ts` — full verified config in [reference.md](reference.md). Critical rules:

- Listing any plugin **ejects the defaults**: always include `@hey-api/typescript`, `@hey-api/sdk`, and a client plugin explicitly, alongside `@tanstack/react-query` and `zod`.
- The TanStack plugin generates `queryOptions`/`mutationOptions`/`infiniteQueryOptions` **factories, not hooks** — spread them into `useQuery`/`useMutation`/`useSuspenseQuery` and into `queryClient.prefetchQuery` on the server. This is the v5-idiomatic pattern.
- Add `"api:gen": "openapi-ts"` to package.json scripts. Regenerate after any spec change; never hand-edit generated files. Commit the generated output.
- The generated Zod schemas carry the spec's constraints — reuse them in forms instead of hand-writing validation.

## 5. Build the app shell

- Root layout: skip-to-content link first, then `header` (logo, primary nav, and a consistently-placed help/contact link — WCAG 3.2.6), `main`, `footer` landmarks. Load fonts with `next/font` (no layout shift, no FOIT).
- Providers: `QueryClientProvider` with a default `staleTime` of ~60s — with SSR hydration, `staleTime: 0` causes an immediate duplicate refetch on the client.
- Feedback: shadcn `sonner` toaster mounted once in the layout (the older `toast` component is deprecated).
- Theme: light + dark via CSS variables, defaulting to `prefers-color-scheme`.
- Route conventions everywhere: `loading.tsx` (skeletons), `error.tsx` (message + retry via `reset()`), `not-found.tsx`.

## 6. Build pages

**Browse pages.** Read filter/sort/page state from `searchParams`; update it with router navigation so URLs stay shareable. Debounce text search ~300ms. Skeletons must match the final layout's dimensions (this is what prevents layout shift). Distinguish three non-happy states and design each: loading (skeleton), empty (explain why and give a next action — clear filters, browse all), error (human message + retry button, never a raw stack or JSON blob). Prefer cursor pagination when the API offers it; otherwise numbered pages that preserve active filters.

**Detail pages.** Server-render with the generated SDK, `generateMetadata` from the fetched resource (title, description, OG image if the schema has one). Prefetch on link hover with the generated query options for instant-feeling navigation. Breadcrumbs back to the collection.

**Forms and mutations.** The rules below are grounded in usability research (NN/g, Google web.dev) and WCAG — follow all of them; details and snippets in [reference.md](reference.md):

- Build schemas from the **generated Zod output** (extend, don't rewrite). Wire with `zodResolver` and `mode: 'onTouched'`.
- Labels **above** fields, always visible. Placeholders only for format examples, never as the label.
- Mark required fields; put persistent hints below the input, in the same slot errors will occupy.
- Validate on blur; clear an error as soon as the user edits the field; never flag errors mid-typing.
- Error messages sit directly under the field, say specifically what to fix, and use icon + text + outline — not color alone. Wire `aria-invalid`, `aria-describedby`, and `aria-labelledby` through the "Form bindings" component in [reference.md](reference.md) — shadcn no longer ships one, so copy it rather than rebuilding it.
- Keep the submit button **enabled**; on invalid submit, focus the first errored field. Show a pending state during the request; only prevent double-submission after a valid click.
- Preserve everything the user typed on failure, and never ask for the same information twice in one flow (WCAG 3.3.7).
- Destructive actions get a confirmation dialog naming the exact object. Low-stakes mutations get optimistic updates with rollback. Success = toast + navigate to the result.

## 7. Wire auth and credential handling

- **Never ship API keys or client secrets to the browser.** If the spec's `securitySchemes` require a key/token the app owns, generate the client's `baseUrl` to point at your own route handler, which proxies to the upstream API and attaches the secret from server-only env vars (proxy snippet in [reference.md](reference.md)). Only fully public, unauthenticated APIs may be called directly from the client.
- End-user login (OAuth authorization code / OIDC in the spec): keep tokens in httpOnly, secure cookies — never localStorage. Auth.js is the standard Next.js choice for OIDC flows.
- WCAG 3.3.8 (Accessible Authentication): never block paste in password/OTP fields, support password managers via `autocomplete` attributes, no cognitive puzzles as the only login path.

## 8. SEO and performance

Performance applies to every route. Indexing applies only to the routes an anonymous visitor can reach — use the flag recorded in step 2, and do not treat "no indexable routes" as a failure.

**Everywhere.** Title template in the root layout and per-page titles, one `h1` per page with no skipped heading levels, and the Core Web Vitals targets (75th percentile, field data): **LCP ≤ 2.5s, INP ≤ 200ms, CLS ≤ 0.1** — all three must pass. Tactics: `next/image` with `priority` on the LCP image, `next/font`, stream slow sections with Suspense, reserve space for async content (skeletons sized like the content), keep `'use client'` at the leaves, explicit `staleTime` to avoid hydration double-fetch. Titles and headings are navigation and orientation for screen-reader and tab-title users; they are not SEO decoration.

**Anonymous routes only.** Per-page descriptions, `generateMetadata` on dynamic routes, Open Graph tags, canonical URLs, and a `sitemap.ts` listing exactly those routes.

**Authenticated routes.** `robots: { index: false, follow: false }` in the route's metadata — one account's data has no business in an index, and a leaked URL should not be crawlable. Scope `robots.ts` to match: `disallow` the authenticated path prefixes rather than blanket-disallowing `/`, or the marketing and sign-up pages go dark too. If the app is *entirely* authenticated, a blanket `disallow: /` plus no sitemap is the correct and complete answer — say so in the report instead of inventing SEO work.

## 9. Accessibility pass (WCAG 2.2 AA)

Baseline: semantic HTML, full keyboard operability, visible focus, 4.5:1 text contrast (3:1 for large text and UI parts), labels on every control, alt text, `prefers-reduced-motion` respected. Then the criteria new in WCAG 2.2 with direct app implications:

- **2.5.8 Target Size**: interactive targets ≥ 24×24 CSS px (inline text links exempt).
- **2.4.11 Focus Not Obscured**: sticky headers must not hide the focused element — set `scroll-padding-top`/`scroll-margin`.
- **3.2.6 Consistent Help**: help/contact link in the same place on every page.
- **3.3.7 Redundant Entry**: auto-fill previously entered info within a flow.
- **3.3.8 Accessible Authentication**: see step 7.
- **2.5.7 Dragging Movements**: any drag interaction needs a single-pointer alternative.

shadcn/Radix primitives are accessible, but composition is on you: every `Dialog` needs a `DialogTitle`, icon-only buttons need `aria-label`s, and re-themed colors must re-verify contrast. Verify the stock theme too — a default palette is not a passing one. EU note: for e-commerce or consumer services sold into the EU, WCAG-level accessibility is legally mandated (EAA, enforced since 2025-06-28) — treat AA as launch-blocking, not polish. Full checklist: [reference.md](reference.md).

## 10. Verify

```bash
npm run api:gen && npx tsc --noEmit && npm run lint && npm run build
npx playwright test
```

- Playwright: a smoke test per page plus an axe scan asserting zero violations with tags `['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa']` (fixture in [reference.md](reference.md)). Scan open states too (dialogs, menus), not just initial render.
- Manual pass: keyboard-only walkthrough, 200% zoom, 375px viewport, dark mode, and a throttled network to see every loading/empty/error state at least once.
- Report honestly: build/type/lint/test results, the page map, which operations were excluded and whose actions they were, which routes are indexable (state plainly if none are, and why), and that Core Web Vitals are ultimately judged on field data, not lab runs.

## Additional resources

- Verified configs, snippets, checklists, and escape hatches: [reference.md](reference.md)
- Worked example (spec → page map → key artifacts): [examples.md](examples.md)
