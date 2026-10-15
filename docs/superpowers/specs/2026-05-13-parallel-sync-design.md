# Parallel Jira Sync Design

## Problem

The current `org-jira--sync-to-jira` makes 5+ sequential blocking HTTP requests
per ticket (with 2 duplicates). For 20 tickets this means 100+ serial requests,
making sync painfully slow.

## Goals

1. Eliminate duplicate API calls (consolidate from 5 to 2-3 per existing ticket)
2. Fire HTTP requests in parallel using async `url-retrieve`
3. Adaptive rate limiting — uncapped by default, throttle only on HTTP 429
4. Non-blocking UX — buffer is read-only during sync, user can use other buffers
5. Modeline progress indicator (nice-to-have)
6. All existing regression tests must continue to pass unchanged

## Non-Goals

- Changing the Jira API endpoints used (no bulk/batch APIs)
- Adding external dependencies (pure Elisp only)
- Changing the org document format or properties

## Architecture

### Request Consolidation

**Before (per existing ticket, 5+ requests):**

| # | Request | Used by |
|---|---------|---------|
| 1 | GET `/issue/{key}?fields=attachment` | sync-ticket (ADF mediaInline) |
| 2 | PUT `/issue/{key}` | sync-ticket (update) |
| 3 | GET `/issue/{key}?fields=attachment` | sync-attachments (duplicate of #1) |
| 4 | GET `/issue/{key}` | sync-sprint-from-jira |
| 5 | GET `/issue/{key}` | sync-due-date-from-jira (duplicate of #4) |

**After (per existing ticket, 2-3 requests):**

| # | Request | Provides |
|---|---------|----------|
| 1 | GET `/issue/{key}` | Attachments, sprint, due date — all from one response |
| 2 | PUT `/issue/{key}` | Update ticket fields |
| 3 | POST attachments (if needed) | Upload new local files |

For new tickets (no JIRA_KEY): 1 POST to create, then attachment uploads. No GET
needed.

### New Module: `org-jira-async.el`

Async HTTP layer that wraps `url-retrieve` with coordination primitives.

#### `org-jira--async-request`

Async replacement for `org-jira--api-request`.

```
(org-jira--async-request METHOD ENDPOINT CALLBACK &optional DATA)
```

- `CALLBACK` is `(lambda (response err) ...)` where `response` is parsed JSON
  (same format as `org-jira--api-request` returns) and `err` is nil on success
  or an error description on failure.
- Uses `url-retrieve` (non-blocking) internally.
- Parses the response buffer the same way the current sync `org-jira--api-request`
  does (HTTP status check, JSON decode).
- On HTTP 429: reads `Retry-After` header, re-queues the request via `run-at-time`
  after the specified delay, and triggers the adaptive throttle.

#### Encoding Invariants

`org-jira--async-request` must preserve the exact encoding behavior of the
current synchronous `org-jira--api-request`:

- **JSON request bodies (non-ASCII text):** `url-request-data` must be set to
  `(encode-coding-string (json-encode data) 'utf-8)`. This ensures non-ASCII
  characters in ticket summaries and descriptions (e.g., accented characters,
  CJK, emoji) survive the round-trip. The `url-retrieve` callback must also
  handle UTF-8 response bodies correctly.

- **Binary attachment uploads:** `org-jira--upload-attachment` builds the
  multipart body in a unibyte buffer (`set-buffer-multibyte nil`) and reads
  file bytes with `coding-system-for-read 'no-conversion` +
  `insert-file-contents-literally`. This must NOT change — raw bytes must
  pass through without any encoding transformation. When making attachment
  uploads async, the multipart body construction stays identical; only the
  final `url-retrieve-synchronously` call changes to `url-retrieve`.

- **Async attachment downloads:** the current `url-copy-file` preserves binary
  content. The async replacement must write the response body to disk with
  `coding-system-for-write 'no-conversion` to avoid corrupting binary files
  (images, PDFs, etc.).

#### `org-jira--async-batch`

Fires a list of async operations and calls back when all complete.

```
(org-jira--async-batch THUNKS FINAL-CALLBACK)
```

- `THUNKS` is a list of zero-arg functions. Each fires one async request.
- Tracks completion count internally.
- `FINAL-CALLBACK` is `(lambda (results) ...)` called once all thunks have
  completed (or errored). `results` is a list of `(response . err)` pairs in
  the same order as `THUNKS`.

#### Adaptive Rate Limiting

Built into `org-jira--async-request`:

- **Default:** no concurrency limit. All requests fire immediately.
- **On 429:** parse `Retry-After` header (seconds, default to 5 if missing).
  Pause the failed request, re-queue it after the delay via `run-at-time`.
  Set a buffer-local throttle flag so any new requests that haven't fired yet
  also wait behind the delay.
- **Recovery:** after the retry-after window, resume requests. Gradually open
  back up — double the allowed concurrent requests after each successful batch
  until back to uncapped.
- **State:** managed in a `org-jira--rate-limit-state` struct with fields:
  `throttled-p`, `retry-after-time`, `max-concurrent` (nil = uncapped),
  `pending-queue` (list of deferred thunks).

### Sync Flow Phases

The new `org-jira--sync-to-jira` orchestrates three async phases. Each phase
fires all its requests at once, and the completion callback kicks off the next
phase.

#### Phase 0: Setup (synchronous)

Runs before any async work:

1. Guard: if `org-jira--sync-in-progress`, message and return.
2. Clear sprint cache, ensure issue types loaded.
3. Parse document → get features list and stories list.
4. Check `all-features-exist-p`: every feature has a non-empty JIRA_KEY.
5. Mark buffer read-only, set `org-jira--sync-in-progress` to `t`.
6. Initialize modeline progress: `[org-jira: 0/N]`.

#### Phase 1: Create/Update Tickets + Fetch Remote Data

**Ticket grouping based on `all-features-exist-p`:**

- If `t`: fire ALL tickets (features + stories) in one `org-jira--async-batch`.
- If `nil`: fire features in a batch → on completion, fire stories in a batch.

**Per existing ticket (has JIRA_KEY):**

1. Fire GET `/issue/{key}` (full ticket data).
2. In its callback: extract attachments, sprint, due date from response. Store
   in a results accumulator. Then fire PUT `/issue/{key}` with current org data
   (using the fetched attachments for ADF mediaInline resolution).
3. PUT callback: record completion in accumulator.

**Per new ticket (no JIRA_KEY):**

1. Fire POST `/issue/` to create.
2. In callback: extract new key from response, store in results accumulator.
3. If `org-jira-default-sprint`, record sprint assignment in results.

Progress: update modeline after each ticket completes.

#### Phase 2: Attachments + Links

Fires when Phase 1 completes. All tickets now have keys.

Fire in parallel via `org-jira--async-batch`:

- **Attachment uploads:** for each ticket, compare local org-attach files against
  the attachment list fetched in Phase 1. Upload any files not in Jira.
- **Attachment downloads:** for each ticket, compare Jira attachment list against
  local files. Download any files not local. Note: current `url-copy-file` is
  synchronous; replace with async `url-retrieve` writing to a file in the
  callback to maintain full parallelism.
- **Link creation:** for each ticket, fire POST for BLOCKS, BLOCKED-BY, and
  implicit parent→story links.

Progress: continue updating modeline.

#### Phase 3: Apply Results to Buffer (synchronous)

Fires when Phase 2 completes. Runs in `with-current-buffer`:

1. Write new JIRA_KEYs to org headings (for newly created tickets).
2. Update SPRINT properties from fetched Jira data.
3. Update DUE_DATE properties from fetched Jira data.
4. Inherit due dates from parent features to stories.
5. Set SPRINT drawer for newly created tickets to `org-jira-default-sprint`.
6. Resolve BLOCKED-BY → BLOCKS display properties
   (`org-jira--resolve-blocked-by-in-org`).
7. Remove buffer read-only, clear `org-jira--sync-in-progress`.
8. Clear modeline progress.
9. Message: `"org-jira: Sync complete (N tickets)"`.

### Buffer Protection

- At sync start: `(setq buffer-read-only t)` on the org buffer.
- `org-jira--sync-in-progress` buffer-local variable prevents re-entry.
- User can freely use other Emacs buffers during sync.
- Phase 3 temporarily binds `inhibit-read-only` to `t` for its buffer mutations,
  then sets `buffer-read-only` back to `nil`.

### Modeline Progress (Nice-to-Have)

A minor mode or mode-line construct that displays sync progress:

```
[org-jira: 5/20]
```

- Initialized in Phase 0 with total ticket count.
- Incremented in Phase 1 and Phase 2 callbacks.
- Cleared in Phase 3.
- Uses `force-mode-line-update` to refresh display.

## Code Complexity Constraints

All code must follow the project's existing style rules:

- **750-line file limit.** No file may exceed 750 lines. If a new file
  approaches this, split by logical responsibility before it gets there.
- **Max 3 levels of nesting.** Use early returns (`cl-return-from`, `unless`
  guards) to flatten deeply nested code. Async callbacks naturally add one level
  of nesting — keep callback bodies short (extract helpers for anything over
  ~10 lines).
- **Functions under 30 lines.** Extract subroutines for anything longer.
- **Minimize callback depth.** The phase chain (Phase 1 → 2 → 3) is inherently
  3 levels of callbacks. Each phase should be its own named function (not an
  inline lambda) to keep nesting flat:
  - `org-jira--sync-phase-1` calls `org-jira--async-batch` with
    `#'org-jira--sync-phase-2` as the completion callback.
  - `org-jira--sync-phase-2` calls `org-jira--async-batch` with
    `#'org-jira--sync-phase-3` as the completion callback.
  - `org-jira--sync-phase-3` is synchronous, applies results, cleans up.
- **Named functions over inline lambdas** for any callback longer than a single
  expression. This keeps each function readable and independently testable.

### Estimated File Sizes

| File | Estimated lines | Notes |
|------|----------------|-------|
| `org-jira-async.el` | ~200-300 | Async request, batch, rate limiting, modeline progress |
| `org-jira-sync.el` | ~400 (current) → ~450 | Phase orchestration replaces old sequential loop; helpers stay |
| `org-jira-test-async.el` | ~300-400 | Async layer tests + consolidated sync flow tests |
| `org-jira-core.el` | ~155 (current) → ~160 | Add sync-in-progress defvar |

All well within the 750-line limit. If `org-jira-sync.el` grows past ~600
during implementation, split phase orchestration into `org-jira-sync-phases.el`.

## File Changes

| File | Change |
|------|--------|
| `org-jira-async.el` | **New.** Async HTTP layer: `org-jira--async-request`, `org-jira--async-batch`, rate limit state, modeline progress. |
| `org-jira-sync.el` | Rewrite `org-jira--sync-to-jira` to use phased async flow. Phase functions are named top-level functions (not nested lambdas). Keep all helper functions (`sync-ticket-links`, `set-org-sprint`, etc.) unchanged. |
| `org-jira-api.el` | No changes. `org-jira--api-request` stays as-is for backwards compatibility and test mocking. |
| `org-jira-attachments.el` | No changes to public API. `org-jira--sync-attachments` may be refactored internally to accept pre-fetched attachment data instead of re-fetching. |
| `org-jira-core.el` | Add `org-jira--sync-in-progress` defvar. |

## Testing Strategy

### Existing Tests

All existing regression tests must pass unchanged. They mock
`org-jira--api-request` (the synchronous version) and test:

- Ticket creation/update logic
- Sprint sync behavior
- Due date sync behavior
- Link creation
- Attachment sync

Since `org-jira--api-request` is preserved and the underlying sync helper
functions are unchanged, these tests continue to exercise the same code paths.

### New Tests: Async Layer (`org-jira-test-async.el`)

- `org-jira--async-request`: mock `url-retrieve` to verify callback invocation,
  response parsing (success, error, empty body), and 429 retry behavior.
- `org-jira--async-batch`: verify all callbacks fire and final completion
  callback runs with all results in correct order.
- Adaptive rate limiting: mock a 429 response with `Retry-After` header, verify
  request is re-queued and fires after delay. Verify throttle flag pauses new
  requests. Verify recovery back to uncapped.
- Buffer protection: verify `buffer-read-only` is set during sync and cleared
  after. Verify re-entrant call is rejected with message.
- Encoding: verify JSON request body is UTF-8 encoded (round-trip non-ASCII
  characters like accented text and emoji). Verify binary attachment upload
  preserves exact bytes (no encoding transformation). Verify binary attachment
  download writes identical bytes to disk.

### New Tests: Consolidated Sync Flow

- Verify existing ticket fires 1 GET + 1 PUT (not the old 5 requests). Count
  calls to `org-jira--async-request` with appropriate method/endpoint checks.
- Verify `all-features-exist-p` detection: when all features have keys → stories
  fire in same batch; when some features lack keys → features batch fires first,
  stories batch fires in its completion callback.
- Verify Phase 3 correctly applies accumulated results (sprint, due date, new
  keys) to org buffer.

### Integration Test

End-to-end sync with mocked async requests. Verifies the full phase chain
(0 → 1 → 2 → 3) completes and the org buffer ends up in the correct final state
(same as current sync would produce).

## Risks

- **Callback ordering:** async callbacks may fire in any order. Phase 3's
  buffer mutations must be order-independent (they are — each ticket writes to
  its own heading).
- **Error handling:** if a single request fails, it should not block the entire
  sync. Errors are collected in the results accumulator and reported at the end.
- **Buffer killed during sync:** guard all `with-current-buffer` calls with
  `buffer-live-p` checks.
- **Emacs event loop:** `url-retrieve` relies on the Emacs event loop running.
  If the user runs a long blocking command, async callbacks will queue up but
  still fire when the event loop resumes.
