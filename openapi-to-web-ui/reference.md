# Reference: verified configs, snippets, and checklists

Facts below were verified against primary sources on 2026-08-22. Versions drift: always prefer the latest stable release and check the installed version before debugging against these notes.

| Tool | State when verified | Source |
|---|---|---|
| Next.js | 16.x stable (App Router, Turbopack default) | [nextjs.org](https://nextjs.org/docs) |
| Tailwind CSS | v4 (CSS-first config, OKLCH colors in shadcn themes) | [tailwindcss.com](https://tailwindcss.com) |
| shadcn/ui | Built on **Base UI**, not Radix: `render` prop instead of `asChild`, and no `form` component. `toast` deprecated for `sonner` | [ui.shadcn.com](https://ui.shadcn.com/docs/tailwind-v4) |
| @hey-api/openapi-ts | pre-1.0 — pin exact version | [heyapi.dev](https://heyapi.dev/openapi-ts/get-started) |
| TanStack Query | v5; `queryOptions` helper is the idiomatic pattern | [tanstack.com/query](https://tanstack.com/query/v5/docs/framework/react/guides/query-options) |
| Zod | v4 (top-level `z.email()` etc.); works with `@hookform/resolvers` ≥ 5.4.2 | [zod.dev](https://zod.dev) |
| OpenAPI | 3.2.0 released 2025-09-19; Redocly lints 2.0–3.2 | [spec.openapis.org](https://spec.openapis.org/oas/v3.2.0) |
| WCAG | 2.2 is current (9 criteria added over 2.1) | [w3.org/TR/WCAG22](https://www.w3.org/TR/WCAG22/) |
| Core Web Vitals | LCP ≤ 2.5s, INP ≤ 200ms, CLS ≤ 0.1 at p75; INP replaced FID in 2024 | [web.dev/vitals](https://web.dev/articles/vitals) |

## Known first-run failures

Every entry below cost real round trips on a previous run. Take the stated value rather than the one that looks right.

| Symptom | Cause and fix |
|---|---|
| `shadcn init -b neutral` → `Expected 'radix' \| 'base' \| 'aria'` | `-b` now selects the primitive library, not the base colour. Use `shadcn init -d -y` and take the defaults. |
| `shadcn add form` reports success but writes nothing | The registry moved to Base UI and dropped the react-hook-form wrapper. Nothing will tell you; the file is just absent. Copy "Form bindings" below. |
| `asChild` does nothing on a shadcn component | Base UI uses `render={<Link href="…" />}` instead. |
| `openapi-ts` → `Invalid Hey API shorthand format` | A bare `a/b` string is read as a registry shorthand. Use `input: { path: './openapi/openapi.yaml' }`. |
| Generated `client.gen.ts` → `Cannot find module '../../../hey-api'` | `runtimeConfigPath` resolves oddly. The working value is exactly `'./src/hey-api'`. |
| …then `TS5097: An import path can only end with '.ts'` | You wrote `'./src/hey-api.ts'`. Drop the extension. |
| `tsc --noEmit` rejects `PageProps<"/items/[id]">` | Next's route types are generated. Run `npx next typegen` once, then typecheck. |
| `use: { reducedMotion: 'reduce' }` fails to typecheck | In current Playwright it lives one level down: `use: { contextOptions: { reducedMotion: 'reduce' } }`. |
| axe reports contrast like `#999999 on #f9f9f9` inside a dialog | It scanned mid-fade. Colours are only measurable once animation settles — set the reduced-motion option above. |
| axe reports contrast on a `destructive` button | Not a false positive: the stock theme fails AA. See "Contrast fixes" below. |
| `getByLabel('Other item')` never matches a select or combobox | `<label for>` does not name a `<button>` under HTML-AAM. Fix the app with `aria-labelledby` (see "Form bindings"), then match with `getByRole('button', { name: /^Other item/ })`. |
| `getByLabel` matches several unrelated controls | It is substring and case-insensitive by default. `"Other item"` matches a radio labelled "…the other item". Anchor with a regex or `exact: true`. |

## Scaffold commands

```bash
npx create-next-app@latest <app-name> --ts --app --tailwind --eslint --src-dir --turbopack --import-alias "@/*" --use-npm --yes
cd <app-name>
npx shadcn@latest init -d -y          # no -b flag; it means something else now
npx shadcn@latest add button card input select dialog skeleton sonner badge breadcrumb label textarea separator dropdown-menu tabs alert table tooltip checkbox switch popover command radio-group -y
npm i @tanstack/react-query react-hook-form zod @hookform/resolvers
npm i -D -E @hey-api/openapi-ts
npm i -D @playwright/test @axe-core/playwright
npx playwright install chromium
```

`form` is deliberately absent from that list — it no longer exists in the registry. Copy "Form bindings" below instead.

`create-next-app` refuses to scaffold into a directory containing *anything* it recognises, including a stray `openapi/` folder. If the spec is already in place, scaffold into a temp directory and move the contents in.

If npm reports React 19 peer-dependency conflicts from a community package, the shadcn CLI offers `--force`/`--legacy-peer-deps`; prefer updating the offending package first.

## Hey API codegen

`openapi-ts.config.ts` at the project root:

```ts
import { defineConfig } from '@hey-api/openapi-ts';

export default defineConfig({
  // Object form is required: a bare 'a/b' string is parsed as a registry shorthand.
  input: { path: './openapi/openapi.yaml' },
  output: 'src/client',
  plugins: [
    // Listing ANY plugin ejects the defaults — include all of these explicitly.
    '@hey-api/typescript',
    { name: '@hey-api/sdk', validator: true },   // validates responses with the zod schemas
    // Exactly this string: no leading '../', no '.ts' extension.
    { name: '@hey-api/client-next', runtimeConfigPath: './src/hey-api' },
    '@tanstack/react-query',
    'zod',
  ],
});
```

Set `validator: true` only when the spec's enums are closed. If it documents additive evolution — "clients should treat unknown values as valid but unfamiliar rather than fail" — response validation turns that promise into a runtime crash the first time the server adds an enum member. Drop to a plain `'@hey-api/sdk'` and say why in the report.

Runtime client config (`src/hey-api.ts`) — base URL from env, not hardcoded:

```ts
import type { CreateClientConfig } from './client/client.gen';

export const createClientConfig: CreateClientConfig = (config) => ({
  ...config,
  baseUrl: process.env.NEXT_PUBLIC_API_BASE_URL, // or '/api/upstream' when proxying (see below)
});
```

package.json script: `"api:gen": "openapi-ts"`. Notes:

- Generated output lands in `src/client/` (`types.gen.ts`, `sdk.gen.ts`, `zod.gen.ts`, `@tanstack/react-query.gen.ts`, `client.gen.ts`). Commit it; regenerate on spec change; never hand-edit.
- The TanStack plugin emits **options factories** (`getProductsOptions(...)`, `createOrderMutation(...)`), not hooks.
- `@hey-api/client-next` integrates Next's extended `fetch` (per-request caching/revalidation). If it rejects a spec feature, `@hey-api/client-fetch` is the drop-in fallback.
- Hey API consumes Swagger 2.0 and OpenAPI 3.0/3.1; if a 3.2-only construct trips it, check for a newer release, then simplify the offending construct (they are rare: `additionalOperations`, `querystring`).

## TanStack Query setup

Provider (client component, imported by the root layout):

```tsx
'use client';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { useState } from 'react';

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(
    () => new QueryClient({ defaultOptions: { queries: { staleTime: 60_000 } } }),
  );
  return <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>;
}
```

Explicit `staleTime` matters: with SSR hydration, the default `staleTime: 0` triggers an immediate duplicate refetch on mount.

Using generated options:

```tsx
'use client';
import { useQuery } from '@tanstack/react-query';
import { getProductsOptions } from '@/client/@tanstack/react-query.gen';

const { data, isPending, isError, refetch } = useQuery({
  ...getProductsOptions({ query: { page, category } }),
  placeholderData: (prev) => prev,   // keep old list visible while filters change
});
```

Server-side prefetch for SEO-relevant pages (App Router):

```tsx
import { dehydrate, HydrationBoundary, QueryClient } from '@tanstack/react-query';
import { getProductsOptions } from '@/client/@tanstack/react-query.gen';

export default async function Page() {
  const queryClient = new QueryClient();
  await queryClient.prefetchQuery(getProductsOptions({ query: { page: 1 } }));
  return (
    <HydrationBoundary state={dehydrate(queryClient)}>
      <ProductList />
    </HydrationBoundary>
  );
}
```

Optimistic update (low-stakes mutations only): `onMutate` → `cancelQueries` → snapshot via `getQueryData` → `setQueryData` → return snapshot; `onError` → restore snapshot + toast; `onSettled` → `invalidateQueries`.

When the browser goes through the `/api/upstream` proxy, note that a relative base URL only resolves in the browser: server-side prefetch should call the upstream directly (the server may hold the secret), while the hydrated client uses the proxy. Keep the query key identical in both places.

## Credential-safe proxy (BFF)

When the spec requires an API key or app-level token, never expose it. Point the generated client's `baseUrl` at `/api/upstream` and forward server-side:

```ts
// src/app/api/upstream/[...path]/route.ts
import { NextRequest } from 'next/server';

const UPSTREAM = process.env.API_BASE_URL!; // server-only env var

async function proxy(req: NextRequest, { params }: { params: Promise<{ path: string[] }> }) {
  const { path } = await params;
  // Don't use new URL(relative, base): a base without a trailing slash silently drops its last segment.
  const url = `${UPSTREAM.replace(/\/$/, '')}/${path.join('/')}${req.nextUrl.search}`;
  const res = await fetch(url, {
    method: req.method,
    headers: {
      'content-type': req.headers.get('content-type') ?? 'application/json',
      authorization: `Bearer ${process.env.API_KEY}`, // attach secret server-side
    },
    body: req.method === 'GET' || req.method === 'HEAD' ? undefined : await req.blob(),
  });
  return new Response(res.body, { status: res.status, headers: { 'content-type': res.headers.get('content-type') ?? 'application/json' } });
}

export { proxy as GET, proxy as POST, proxy as PUT, proxy as PATCH, proxy as DELETE };
```

Env rules: secrets in `API_*` vars (server-only). `NEXT_PUBLIC_*` is compiled into the browser bundle — only truly public values. Whitelist paths in the proxy if the upstream API has operations the app must not expose.

## Form bindings (`src/components/ui/form.tsx`)

shadcn no longer ships this, and rebuilding it from memory is the most expensive part of a cold start. Copy it. The point of it is that one generated id threads `htmlFor`, `aria-invalid`, and `aria-describedby` across label, control, description, and error so they cannot drift apart by hand.

```tsx
'use client';

import * as React from 'react';
import {
  Controller, FormProvider, useFormContext, useFormState,
  type ControllerProps, type FieldPath, type FieldValues,
} from 'react-hook-form';
import { Label } from '@/components/ui/label';
import { cn } from '@/lib/utils';

const Form = FormProvider;

const FormFieldContext = React.createContext<{ name: string } | null>(null);
const FormItemContext = React.createContext<{ id: string } | null>(null);

function FormField<T extends FieldValues, N extends FieldPath<T>>(props: ControllerProps<T, N>) {
  const value = React.useMemo(() => ({ name: props.name }), [props.name]);
  return (
    <FormFieldContext.Provider value={value}>
      <Controller {...props} />
    </FormFieldContext.Provider>
  );
}

function useFormField() {
  const fieldContext = React.useContext(FormFieldContext);
  const itemContext = React.useContext(FormItemContext);
  const { getFieldState } = useFormContext();
  const formState = useFormState({ name: fieldContext?.name as string });
  if (!fieldContext) throw new Error('useFormField must be used within <FormField>');
  if (!itemContext) throw new Error('useFormField must be used within <FormItem>');
  const { id } = itemContext;
  return {
    id,
    name: fieldContext.name,
    formItemId: `${id}-control`,
    formLabelId: `${id}-label`,
    formDescriptionId: `${id}-description`,
    formMessageId: `${id}-message`,
    ...getFieldState(fieldContext.name, formState),
  };
}

function FormItem({ className, ...props }: React.ComponentProps<'div'>) {
  const id = React.useId();
  const value = React.useMemo(() => ({ id }), [id]);
  return (
    <FormItemContext.Provider value={value}>
      <div data-slot="form-item" className={cn('grid gap-2', className)} {...props} />
    </FormItemContext.Provider>
  );
}

function FormLabel({ className, ...props }: React.ComponentProps<typeof Label>) {
  const { error, formItemId, formLabelId } = useFormField();
  return (
    <Label
      data-error={!!error}
      className={cn('data-[error=true]:text-destructive', className)}
      id={formLabelId}
      htmlFor={formItemId}
      {...props}
    />
  );
}

/**
 * `aria-labelledby` goes on alongside `htmlFor`, because a `<label for>` does NOT name a
 * `<button>` under HTML-AAM — a Base UI select or combobox trigger would otherwise be
 * announced by its current value with no idea what it is choosing.
 */
function FormControl({ children }: { children: React.ReactElement<Record<string, unknown>> }) {
  const { error, formItemId, formLabelId, formDescriptionId, formMessageId } = useFormField();
  return React.cloneElement(children, {
    id: formItemId,
    'aria-labelledby': formLabelId,
    'aria-describedby': error ? `${formDescriptionId} ${formMessageId}` : formDescriptionId,
    'aria-invalid': !!error,
  });
}

function FormDescription({ className, ...props }: React.ComponentProps<'p'>) {
  const { formDescriptionId } = useFormField();
  return <p id={formDescriptionId} className={cn('text-sm text-muted-foreground', className)} {...props} />;
}

// Errors occupy the description's slot and pair an icon with the text, so failure is
// never signalled by colour alone.
function FormMessage({ className, children, ...props }: React.ComponentProps<'p'>) {
  const { error, formMessageId } = useFormField();
  const body = error ? String(error?.message ?? '') : children;
  if (!body) return null;
  return (
    <p id={formMessageId} className={cn('flex items-start gap-1.5 text-sm font-medium text-destructive', className)} {...props}>
      <svg aria-hidden="true" viewBox="0 0 16 16" className="mt-0.5 size-4 shrink-0 fill-current">
        <path d="M8 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 0 0 0-13ZM7.25 4.5h1.5v5h-1.5v-5Zm0 6.25h1.5v1.5h-1.5v-1.5Z" />
      </svg>
      <span>{body}</span>
    </p>
  );
}

export { Form, FormControl, FormDescription, FormField, FormItem, FormLabel, FormMessage, useFormField };
```

A Base UI select or combobox trigger should then merge that label id with its own, so the name reads "Kind of value, Date" rather than dropping either half:

```tsx
const labelledByChain = labelledBy && id ? `${labelledBy} ${id}` : labelledBy;
```

Standalone controls outside a `FormField` need the same treatment by hand: give the `<Label>` an `id` and pass it as `aria-labelledby`.

## Contrast fixes for the stock shadcn theme

The default palette does not pass AA in either scheme. Both of these are real axe failures, not scan artifacts:

```css
:root { --destructive: oklch(0.505 0.213 27.518); } /* stock is 4.0:1 as text on its own 10% tint */
.dark { --destructive: oklch(0.75  0.16  22.216); } /* stock drops to 4.24:1 once that tint stacks on a muted dialog footer */
```

Inline `<code>` inheriting `--muted-foreground` onto `--muted` lands at 4.34:1, so pin it: `code { @apply text-foreground; }`.

Respecting reduced motion is a WCAG requirement in its own right, and it is also what makes an axe scan deterministic:

```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
    scroll-behavior: auto !important;
  }
}
```

## Forms: react-hook-form + Zod v4

- Requires `@hookform/resolvers` ≥ 5.4.2 for clean Zod 4 types (`zodResolver` auto-detects Zod 3 vs 4).
- Zod 4 syntax: `z.email()`, `z.url()` are top-level (not `z.string().email()`).
- If a schema uses `.default()` or `z.coerce`, input and output types differ. Either omit the `useForm` generic entirely, or pass all three: `useForm<z.input<typeof S>, unknown, z.output<typeof S>>`.

```tsx
const schema = zCreateReviewData.shape.body; // start from generated zod.gen.ts, extend if needed

const form = useForm<z.input<typeof schema>, unknown, z.output<typeof schema>>({
  resolver: zodResolver(schema),
  mode: 'onTouched',           // validate on first blur, then live — friendliest cadence
  defaultValues: { rating: 5, comment: '' },
});
```

Build fields with shadcn's `Form`/`FormField`/`FormLabel`/`FormControl`/`FormMessage`: they wire `htmlFor`, `aria-invalid`, and `aria-describedby` automatically. On invalid submit, react-hook-form focuses the first errored field by default — don't disable that. Map API validation errors (422) back onto fields with `form.setError`.

## Form UX checklist (NN/g + web.dev grounded)

- [ ] Labels above fields, always visible; never placeholder-as-label (placeholders are format examples only)
- [ ] Related fields grouped; label visually closer to its own field than to neighbors
- [ ] Required fields marked; format requirements stated up front, not revealed by the error
- [ ] Input types match data (`inputMode`, `autocomplete`, no dropdowns for 2–3 options — use radios)
- [ ] Validate on blur; clear the error on input; nothing flags mid-typing
- [ ] Errors adjacent below the field, specific and actionable, icon + text + outline (not color alone)
- [ ] Submit stays enabled; invalid submit focuses first error; pending state while in flight
- [ ] User input preserved on any failure; no Reset/Clear button
- [ ] Multi-step flows: progress indicator, values persist across steps, review step before final commit

## Page-state matrix

Every data-driven page ships all four states, designed intentionally:

| State | Browse page | Detail page | Form |
|---|---|---|---|
| Loading | Skeleton grid matching final layout | Skeleton of hero + body | Fields disabled only while submitting |
| Empty | "No results for X" + clear-filters / browse-all action | — (404 → `not-found.tsx`) | — |
| Error | Message + Retry button | Message + Retry + link back | Inline field errors + summary toast for non-field failures |
| Success | Content; announce result count to screen readers on filter | Content | Toast + navigate to created/updated resource |

## WCAG 2.2 AA checklist

Baseline (carried from 2.0/2.1): semantic landmarks and headings; keyboard operability with no traps; visible focus; skip link; 4.5:1 contrast for text and 3:1 for large text/UI components; labels or `aria-label` on all controls; alt text; no info by color alone; `prefers-reduced-motion` respected; page `lang`; touch/pointer works without hover.

New in 2.2 (A/AA):

- [ ] 2.4.11 Focus Not Obscured — focused element never fully hidden under sticky header/footer (`scroll-padding-top` on `html`)
- [ ] 2.5.7 Dragging Movements — single-pointer alternative for any drag (sliders, reorder)
- [ ] 2.5.8 Target Size — ≥ 24×24 CSS px for interactive targets (or sufficient spacing); inline text links exempt
- [ ] 3.2.6 Consistent Help — help/contact mechanism in the same location on every page
- [ ] 3.3.7 Redundant Entry — previously entered info auto-populated or selectable within a flow
- [ ] 3.3.8 Accessible Authentication — no cognitive test to log in; paste allowed; `autocomplete="username"`/`"current-password"`/`"one-time-code"`

Legal context: the European Accessibility Act (Directive 2019/882) applies since 2025-06-28 to e-commerce and consumer services sold to EU consumers regardless of company location (microenterprise exemption: <10 staff and <€2M turnover). Its harmonized standard EN 301 549 currently incorporates WCAG 2.1 AA, with WCAG 2.2 expected in the next revision — building to 2.2 AA satisfies today's bar and the coming one. Enforcement is real: French courts ordered a major retailer to remediate in 2026.

## Core Web Vitals

| Metric | Good (p75) | Measures | Main tactics here |
|---|---|---|---|
| LCP | ≤ 2.5s | Load of largest element | SSR, `next/image` + `priority` on hero, `next/font` |
| INP | ≤ 200ms | Interaction latency | Less client JS (`'use client'` at leaves), debounced search, no sync work in handlers |
| CLS | ≤ 0.1 | Unexpected layout shift | Skeletons sized like content, image dimensions set, no late-inserted banners |

All three must pass, judged on 28-day field data (CrUX), not lab runs. Lighthouse is a proxy; say so when reporting.

## Playwright + axe

`e2e/a11y.spec.ts` — scan every page in the page map, including opened dialogs/menus.

**Assert on a formatted summary, never on the raw violations array.** `expect(results.violations).toEqual([])` serialises every `tags` array and `relatedNodes` entry into the failure diff — hundreds of lines per violation, and the one fact you need is buried in it. Reduce first:

```ts
import { test, expect, type Page } from '@playwright/test';
import AxeBuilder from '@axe-core/playwright';

const TAGS = ['wcag2a', 'wcag2aa', 'wcag21aa', 'wcag22aa'];

async function violations(page: Page) {
  const { violations } = await new AxeBuilder({ page }).withTags(TAGS).analyze();
  return violations.flatMap((v) =>
    v.nodes.map((n) => `${v.id} [${v.impact}] ${n.target.join(' ')} — ${n.failureSummary?.split('\n').pop()?.trim()}`),
  );
}

/** Skeletons carry aria-busy, so their absence is the signal that real content is up.
    A count assertion also works when the element never existed; `not.toContainText`
    fails outright on a missing element. */
async function settled(page: Page) {
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible();
  await expect(page.locator('[aria-busy="true"]')).toHaveCount(0, { timeout: 20_000 });
}

for (const path of ['/', '/products', '/products/1']) {
  test(`a11y: ${path}`, async ({ page }) => {
    await page.goto(path);
    await settled(page);
    expect(await violations(page)).toEqual([]);
  });
}
```

One violation then prints as one readable line — `color-contrast [serious] .bg-destructive\/10 — Expected contrast ratio of 4.5:1`.

Add a second project for dark mode; it is a distinct set of tokens and costs almost nothing to cover:

```ts
projects: [
  { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
  { name: 'chromium-dark', testMatch: /a11y\.spec\.ts/, use: { ...devices['Desktop Chrome'], colorScheme: 'dark' } },
],
use: { contextOptions: { reducedMotion: 'reduce' } },   // NOT use.reducedMotion
```

Use `@axe-core/playwright` (official, Deque), not the older third-party `axe-playwright`. Drive the UI into a state (open the dialog, wait for it) before scanning. If the API under test is live, seed fixtures over `request` in `beforeAll` rather than assuming any records exist.

## Escape hatches

Only deviate for hard constraints, and say so in the report:

- **MSW mocks / API not live yet**: Orval v8 generates MSW + Faker mocks natively (hooks-first; ESM-only, Node ≥ 22.18). Hey API's mock story is weaker.
- **Types only, minimal footprint**: `openapi-typescript` + `openapi-fetch` (+ `openapi-react-query`) — no SDK codegen, everything inferred.
- **SEO genuinely irrelevant** (app is public but fully behind interaction, e.g. a widget): a Vite SPA is acceptable; keep every other practice in this skill.
