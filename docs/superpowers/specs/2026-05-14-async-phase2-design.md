# Async Phase 2: Non-Blocking Attachments and Links

## Problem

The sync pipeline freezes Emacs during Phase 2. Phase 1 (issue CRUD) is
truly async via `url-retrieve`, but Phase 2 attachment and link operations
use `url-retrieve-synchronously` inside async-batch thunks — blocking the
event loop during every HTTP call.

## Decision Summary

- **JSON API calls** (links, issue GETs): keep existing `org-jira--async-request`
  via `url-retrieve` — already non-blocking.
- **File uploads**: use [plz.el](https://github.com/alphapapa/plz.el) (GNU ELPA)
  with curl backend — handles multipart natively.
- **File downloads**: use plz.el with `:as '(file PATH)` — curl writes directly
  to disk, non-blocking.
- **No changes** to Phase 1 or Phase 3.

## Dependency: plz.el

plz.el is added as a required dependency. At load time, a warning is shown
if it's missing:

```elisp
;; In org-jira-core.el
(unless (require 'plz nil t)
  (display-warning 'org-jira
    "org-jira requires the `plz' package (GNU ELPA). \
Install it with: M-x package-install RET plz RET"
    :error))
```

plz.el requires Emacs 27.1+ and curl (universally available on macOS/Linux).

## Async Attachment Operations

All attachment operations become async. The synchronous versions are replaced,
not kept alongside.

### New Functions

**`org-jira--async-download-attachment (url filename dir size callback)`**
- Uses `plz 'get` with `:as '(file LOCAL-PATH)`.
- Skips download if local file exists with matching size (Jira provides no
  hash — filename + size is the best dedup available).
- Calls `(callback local-path err)`.

**`org-jira--async-upload-attachment (ticket-key file-path callback)`**
- Uses `plz 'post` with `:body '(file FILE-PATH)` and multipart headers.
- Calls `(callback response err)`.

**`org-jira--async-download-attachments (ticket-key attachments callback)`**
- Filters out already-local files by name + size comparison.
- Fires remaining downloads concurrently via individual plz calls.
- Tracks completion count, calls `callback` when all finish.

**`org-jira--async-upload-attachments (ticket-key jira-attachments callback)`**
- Takes `jira-attachments` from caller — **no re-fetch** of attachment metadata.
- Compares local files against jira-attachments by filename.
- Fires uploads concurrently, calls `callback` when all finish.

### Removed Functions

- `org-jira--download-attachment` (sync) — replaced by async version.
- `org-jira--upload-attachment` (sync) — replaced by async version.

### Updated Functions

- `org-jira--sync-attachments` — rewired to use async versions with a
  completion message in the callback.
- `org-jira--upload-attachments` — no longer calls `org-jira--get-attachments`
  internally; callers pass the attachment list in.

### Download Dedup Strategy

Jira attachment metadata provides `filename` and `size` but no hash/checksum.
Dedup compares filename + byte size: if a local file exists with matching name
and size, the download is skipped. This avoids unnecessary downloads while
accepting that same-size-different-content is a theoretical (but rare) gap.

### Rate Limiting

plz calls for attachments do not go through the `org-jira--async-request`
rate-limit state machine. Jira's attachment endpoints have higher rate limits
than issue CRUD, and attachment operations are far fewer. If a 429 occurs,
plz's `:else` callback receives the error and it is logged.

## Async Link Creation

**`org-jira--async-create-link (from-key to-key link-type callback)`**
- Uses existing `org-jira--async-request` (POST to `/rest/api/3/issueLink`).
- Goes through the rate-limit state machine automatically.
- Single API call per link — Jira has no bulk link creation endpoint.

**`org-jira--async-sync-ticket-links (ticket org-buffer callback)`**
- Collects all links for a ticket (parent link for stories, explicit blocks,
  blocked-by) — same logic as current `org-jira--sync-ticket-links`.
- Fires them concurrently via `org-jira--async-batch`.
- Calls `callback` when all complete.

The synchronous `org-jira--create-link` and `org-jira--sync-ticket-links` are
removed — all callers use async versions.

## Phase 2 Restructuring

Phase 2 thunks become truly non-blocking:

**Attachment thunks** (`org-jira--make-attachment-thunk`):
1. Call `org-jira--async-download-attachments` with Phase 1 attachment list.
2. On completion, call `org-jira--async-upload-attachments` with same list.
3. On completion, call `done`.

**Link thunks** (`org-jira--make-link-thunk`):
1. Call `org-jira--async-sync-ticket-links`.
2. On completion, call `done`.

**Phase 2 entry** (`org-jira--sync-phase-2`) is structurally unchanged — builds
thunks, fires via `org-jira--async-batch`, transitions to Phase 3. The
difference is thunks are now truly non-blocking.

## What Does NOT Change

- **Phase 1**: Already async via `url-retrieve`. No changes.
- **Phase 3**: Intentionally synchronous (buffer mutations). No changes.
- **`org-jira--async-request`**: Kept as-is for JSON API calls.
- **`org-jira--async-batch`**: Kept as-is for coordination.
- **Rate-limit state machine**: Kept as-is, used by link creation.
- **Progress modeline**: Kept as-is.

## Testing Strategy

### Unit Tests (new async functions)

- `org-jira--async-download-attachment`: mock plz, verify callback with file
  path on success and error on failure.
- `org-jira--async-upload-attachment`: mock plz, verify POST with correct
  URL/headers/body.
- `org-jira--async-download-attachments`: verify size-based dedup skips
  matching files; verify callback fires after all downloads complete.
- `org-jira--async-upload-attachments`: verify dedup against passed-in
  jira-attachments (no GET call); verify callback fires after all uploads.
- `org-jira--async-create-link`: mock `org-jira--async-request`, verify
  correct payload structure.
- `org-jira--async-sync-ticket-links`: verify parent + blocks + blocked-by
  links are all collected and fired.

### Integration Tests (Phase 2 flow)

- Verify Phase 2 thunks call async functions (not synchronous ones).
- Verify Phase 2 → Phase 3 transition fires after all thunks complete.
- Verify attachment list from Phase 1 is threaded through (no re-fetch).

### Test Mocking

- plz is mocked at the function level (`cl-letf`) — no curl or network needed.
- Existing Phase 1 tests unchanged.
- Existing sync-flow tests updated to match new async signatures.
