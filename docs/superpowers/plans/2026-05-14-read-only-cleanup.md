# Buffer Read-Only Cleanup on Sync Failure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure `buffer-read-only` and `org-jira--sync-in-progress` are always cleared when sync fails, preventing permanently locked buffers.

**Architecture:** Wrap the sync entry point in `unwind-protect` so that any synchronous error during pipeline setup (Phase 0/1 kickoff) always cleans up buffer state. Add a dedicated cleanup function to avoid duplication between Phase 3's normal path and the error path.

**Tech Stack:** Emacs Lisp, ERT

---

## Bug Triage

The original bug report had two symptoms:

1. **plz "File exists, will not overwrite" error** — **FIXED** by commit `a512831`. Attachments are deduped by filename and stale local files are deleted before `plz` download. A `condition-case` wraps the `plz` call so errors invoke the callback instead of hanging the pipeline.

2. **Buffer remains read-only after errors** — **PARTIALLY FIXED**. The plz fix ensures the download callback fires, so the pipeline reaches Phase 3 which clears `buffer-read-only`. However, there's a remaining gap: `org-jira--sync-to-jira` sets `buffer-read-only t` at line 242 of `org-jira-sync.el` with no `unwind-protect`. If anything after that point signals a synchronous error (e.g., a thunk throws during `org-jira--async-batch` setup, or `org-jira--sync-phase-1` itself errors), Phase 3 never runs and the buffer is permanently locked.

## File Structure

- **Modify:** `org-jira-sync.el` — add cleanup helper, wrap entry point in `unwind-protect`
- **Modify:** `org-jira-sync-phases.el` — use shared cleanup helper in Phase 3
- **Modify:** `org-jira-test-sync-flow.el` — add test for error-during-sync cleanup

---

### Task 1: Extract cleanup helper

**Files:**
- Modify: `org-jira-sync.el:225-245`
- Modify: `org-jira-sync-phases.el:385-406`

- [ ] **Step 1: Write the failing test**

Add to `org-jira-test-sync-flow.el` after the existing `org-jira-test--buffer-is-read-only-during-sync` test:

```elisp
(ert-deftest org-jira-test--buffer-unlocked-after-sync-error ()
  "buffer-read-only and sync-in-progress are cleared when sync signals an error."
  (org-jira-test--with-sync-mocks
      (lambda (_method _endpoint _callback &optional _data)
        (error "Simulated network failure"))
    (with-temp-buffer
      (org-mode)
      (org-jira-test--insert-feature "Feature" "PROJ-1")
      (setq org-jira--sync-in-progress nil)
      (setq buffer-read-only nil)
      (make-local-variable 'mode-line-misc-info)
      (setq mode-line-misc-info nil)
      ;; Sync should not propagate the error to the caller
      (org-jira--sync-to-jira)
      ;; Buffer must be unlocked after the error
      (should (null buffer-read-only))
      (should (null org-jira--sync-in-progress)))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test 2>&1 | grep -A 5 'buffer-unlocked-after-sync-error'`
Expected: FAIL — `buffer-read-only` is still `t` after the error because there's no `unwind-protect`.

- [ ] **Step 3: Add `org-jira--sync-cleanup` helper to `org-jira-sync.el`**

Add just above `org-jira--sync-to-jira` (around line 222):

```elisp
(defun org-jira--sync-cleanup ()
  "Clear sync-in-progress flag, unlock buffer, and remove progress indicator."
  (setq buffer-read-only nil)
  (setq org-jira--sync-in-progress nil)
  (org-jira--progress-clear))
```

- [ ] **Step 4: Wrap `org-jira--sync-to-jira` body in `condition-case`**

Replace lines 242-245 of `org-jira-sync.el` with:

```elisp
      (setq buffer-read-only t)
      (setq org-jira--sync-in-progress t)
      (org-jira--progress-init ticket-count)
      (condition-case err
          (org-jira--sync-phase-1 doc all-features-exist-p org-buffer)
        (error
         (org-jira--sync-cleanup)
         (message "org-jira: Sync failed: %S" err))))))
```

- [ ] **Step 5: Use cleanup helper in Phase 3**

In `org-jira-sync-phases.el`, replace lines 400-402 in `org-jira--sync-phase-3`:

```elisp
       ;; before:
       (setq buffer-read-only nil)
       (setq org-jira--sync-in-progress nil)
       (org-jira--progress-clear)
       ;; after:
       (org-jira--sync-cleanup)
```

The `org-jira--sync-cleanup` function is defined in `org-jira-sync.el` which `org-jira-sync-phases.el` already depends on (it declares functions from it). Add a `declare-function` at the top of `org-jira-sync-phases.el`:

```elisp
(declare-function org-jira--sync-cleanup "org-jira-sync")
```

- [ ] **Step 6: Run tests to verify everything passes**

Run: `make test`
Expected: All tests pass, including the new `org-jira-test--buffer-unlocked-after-sync-error`.

- [ ] **Step 7: Run byte-compilation**

Run: `make compile`
Expected: No warnings.

- [ ] **Step 8: Commit**

```bash
git add org-jira-sync.el org-jira-sync-phases.el org-jira-test-sync-flow.el
git commit -m "fix: ensure buffer is unlocked when sync fails mid-pipeline

Extract org-jira--sync-cleanup helper and wrap Phase 1 kickoff in
condition-case so that synchronous errors during pipeline setup
always clear buffer-read-only and org-jira--sync-in-progress."
```

---

## What's NOT needed

- No changes to `org-jira-attachments.el` — the plz overwrite bug is already fixed by commit `a512831`.
- No changes to `org-jira-async.el` — `org-jira--async-batch` correctly calls callbacks for both success and error cases. Async errors (in `url-retrieve` callbacks) don't propagate as signals, they're handled by the `:else` paths which invoke callbacks.
- The async phases (1→2→3) chain via callbacks, not synchronous calls, so once the async pipeline is running, errors are handled per-request. The only vulnerable window is the synchronous setup before async takes over — that's what this fix covers.
