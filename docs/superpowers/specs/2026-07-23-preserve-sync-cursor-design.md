# Preserve Cursor Location Across Sync

## Problem

`org-jira-sync-to-jira` runs an asynchronous pipeline: phase 1 (create/update
tickets and fetch remote data) → phase 2 (attachments, links) → phase 3 (apply
results to the buffer). Throughout this pipeline, helpers move point without
restoring it:

- `org-jira--set-org-ticket-key`, `org-jira--set-org-sprint`,
  `org-jira--set-org-due-date` call `goto-char` directly.
- Phase-3 `org-jira--apply-*` helpers walk the buffer applying updates.

When the pipeline finishes, point is left at the last ticket touched instead of
where the user was before invoking sync. Because the moves happen in later async
callbacks, a `save-excursion` wrapper around the entry point cannot help — point
must be captured at sync start and restored when the pipeline ends.

## Goal

After a sync completes (success or error), the cursor returns to where the user
was when they invoked sync, and — if the buffer is visible in a window — the
window scroll is restored so point stays visible at the same spot. Focus is
**not** stolen: if the user navigated to another buffer/window during the async
sync, we do not select the org-buffer's window.

## Approach

Capture position markers when sync starts; restore them in the single cleanup
choke point that runs on both success and error.

### 1. New buffer-local state (`org-jira-core.el`)

Add two `defvar-local`s next to the existing `org-jira--sync-in-progress`:

```elisp
(defvar-local org-jira--sync-saved-point nil
  "Marker for point when the current async sync began, or nil.")

(defvar-local org-jira--sync-saved-window-start nil
  "Marker for window-start when the current async sync began, or nil.")
```

Buffer-local matches `org-jira--sync-in-progress`, which is already
`defvar-local`.

### 2. Capture at sync start (`org-jira--sync-to-jira`, `org-jira-sync.el`)

Right after marking the buffer read-only / setting the in-progress flag, in the
org-buffer:

- `org-jira--sync-saved-point` := `(point-marker)`. A marker (not a raw
  position) so it rides along correctly as `JIRA_KEY` and other properties are
  inserted during sync.
- If `(get-buffer-window (current-buffer))` is non-nil, set
  `org-jira--sync-saved-window-start` := `(copy-marker (window-start win))`;
  otherwise leave it nil.

### 3. Restore at cleanup (`org-jira--sync-cleanup`, `org-jira-sync.el`)

`org-jira--sync-cleanup` already runs on the success path (end of phase 3, inside
the org-buffer) and on the phase-1 error path. Extend it to restore position
before/after clearing state:

- If `org-jira--sync-saved-point` is a marker whose buffer is live:
  - In that buffer, `goto-char` the marker.
  - Find a window displaying that buffer (`get-buffer-window`). If found:
    - `set-window-point` to point.
    - If `org-jira--sync-saved-window-start` is a live marker,
      `set-window-start` to it (preserving scroll).
  - Do **not** `select-window` — focus is preserved.
- Release both markers (`set-marker ... nil`) and reset the vars to nil so they
  do not slow future buffer edits.

Guard everything so that a killed buffer, a buffer no longer shown in any
window, or a sync that never captured (vars nil) all degrade gracefully to
"restore what we can, skip the rest."

## Edge Cases

- **Buffer killed mid-sync:** `marker-buffer` is nil / not live → skip restore,
  still clear vars.
- **Org-buffer not displayed in any window:** restore point only, skip
  `set-window-*`.
- **No capture happened:** vars are nil → skip restore entirely.
- **Content changed by sync:** markers absorb insertions/deletions, so point
  lands on the same logical location.

## Testing

Add a unit test (in `org-jira-test-sync-flow.el`, matching its existing harness
and mocking style):

- Set up an org buffer with multiple tickets.
- Position point on a known heading that is *not* the last one synced.
- Run the sync flow through the existing test harness/mocks.
- Assert point returns to the original heading (e.g., by comparing the heading
  text or a stored position/marker) rather than the last-synced ticket.

A second test may assert that when no sync capture occurs the cleanup path is a
no-op (defensive), if it fits the harness cheaply.

## Non-Goals

- Restoring focus / selecting the org-buffer's window when the user moved away.
- Preserving mark, region, or fold state beyond point and scroll.
- Changing the async pipeline structure or phase boundaries.
