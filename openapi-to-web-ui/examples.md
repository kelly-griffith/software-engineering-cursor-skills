# Worked example: bookshop API → public web app

Input: a spec pasted by the user (excerpt):

```yaml
openapi: 3.1.0
info: { title: Bookshop API, version: 1.0.0 }
paths:
  /books:
    get:
      operationId: listBooks
      parameters:
        - { name: q, in: query, schema: { type: string } }
        - { name: genre, in: query, schema: { type: string, enum: [fiction, nonfiction, poetry] } }
        - { name: page, in: query, schema: { type: integer, minimum: 1, default: 1 } }
    post:
      operationId: createBook
      security: [{ adminKey: [] }]
  /books/{bookId}:
    get: { operationId: getBook }
    delete:
      operationId: deleteBook
      security: [{ adminKey: [] }]
  /books/{bookId}/reviews:
    get: { operationId: listReviews }
    post:
      operationId: createReview
      requestBody:
        content:
          application/json:
            schema:
              type: object
              required: [rating, comment]
              properties:
                rating: { type: integer, minimum: 1, maximum: 5 }
                comment: { type: string, minLength: 10, maxLength: 2000 }
components:
  securitySchemes:
    adminKey: { type: apiKey, in: header, name: X-Api-Key }
```

## Step 2 output: page map

| Route | Purpose | Operations | Render |
|---|---|---|---|
| `/` | Home: featured genres, search entry | `listBooks` (first page) | SSR |
| `/books` | Browse: search `q`, filter `genre`, paginate — all in URL | `listBooks` | SSR + client refinement |
| `/books/[bookId]` | Detail + reviews, review form | `getBook`, `listReviews`, `createReview` | SSR; form client-side |

Excluded as operator-only (reported to the user, not built): `createBook`, `deleteBook` — both require `adminKey`, which a public visitor never holds. The `adminKey` scheme also means no secret belongs in the browser; public reads here are unauthenticated, so no proxy is needed. If *all* operations had required the key, every call would go through the `/api/upstream` proxy from reference.md.

## Step 6 output: key artifacts

Browse page reads URL state and spreads generated query options:

```tsx
// src/app/books/page.tsx (server component prefetches; client component below refines)
const { data, isPending, isError, refetch } = useQuery({
  ...listBooksOptions({ query: { q, genre, page } }),
  placeholderData: (prev) => prev,
});

if (isPending) return <BookGridSkeleton />;                  // same grid dimensions as results
if (isError) return <ErrorState onRetry={() => refetch()} />; // human message + retry
if (data.items.length === 0)
  return <EmptyState query={q} onClear={clearFilters} />;     // explain + clear-filters action
```

Review form starts from the generated Zod schema — the spec's `minLength: 10` becomes the validation message, not a hand-written rule:

```tsx
// Exact export names live in src/client/zod.gen.ts — check them, they vary slightly by version.
const schema = zCreateReviewData.shape.body;

const form = useForm<z.input<typeof schema>, unknown, z.output<typeof schema>>({
  resolver: zodResolver(schema),
  mode: 'onTouched',
  defaultValues: { rating: 5, comment: '' },
});

const mutation = useMutation({
  ...createReviewMutation(),
  onSuccess: () => {
    toast.success('Review published');
    queryClient.invalidateQueries({ queryKey: listReviewsQueryKey({ path: { bookId } }) });
  },
  onError: () => toast.error("Couldn't publish your review — your text is still here. Try again."),
});
```

UX details that must appear in the rendered form: "Rating" as radio-style stars (5 options — no dropdown), "Comment" label above the textarea with "At least 10 characters" as persistent helper text below it, submit button reading "Publish review" (not "Submit") with a pending spinner, and the comment text preserved if the request fails.

## Step 10 output: report shape

- Page map table (above) + excluded operations and why
- `api:gen`, `tsc --noEmit`, `lint`, `build`, `playwright test` results verbatim
- Axe: zero violations at `wcag2a/wcag2aa/wcag21aa/wcag22aa` on `/`, `/books`, `/books/[id]`, and the open review form
- Reminder that CWV pass/fail is decided by field data after launch
