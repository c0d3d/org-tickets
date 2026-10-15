# Parallel Jira Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the sequential blocking sync with parallel async HTTP requests, consolidate duplicate API calls, and provide a non-blocking UX with modeline progress.

**Architecture:** New `org-jira-async.el` module provides `org-jira--async-request` (wraps `url-retrieve`) and `org-jira--async-batch` (fires N thunks, calls back when all done). The existing `org-jira--sync-to-jira` is rewritten as a 4-phase pipeline: setup → create/update tickets → attachments+links → apply results to buffer. Each phase is a named top-level function. Adaptive rate limiting throttles only on HTTP 429.

**Tech Stack:** Emacs Lisp, `url-retrieve` (built-in async HTTP), `run-at-time` (timers), ERT (testing)

**Spec:** `docs/superpowers/specs/2026-05-13-parallel-sync-design.md`

**Worktree:** This work MUST be done on an isolated git worktree branch. Before
starting Task 1, create a worktree:
```bash
git worktree add .worktrees/parallel-sync -b parallel-sync
cd .worktrees/parallel-sync
```
All tasks run inside this worktree. When complete, merge back to main.

**Key files to read before starting:**
- `org-jira-api.el` — current sync HTTP client (`org-jira--api-request`), never modified
- `org-jira-sync.el` — current sync flow, will be rewritten
- `org-jira-core.el` — data structures and config vars
- `org-jira-attachments.el` — attachment sync, minor refactor
- `org-jira-parse.el` — document parsing, `org-jira--resolve-blocked-by-in-org`
- `docs/dev/testing.md` — test conventions

**Run existing tests before AND after every task:**
```bash
make test
```

---

## File Structure

| File | Responsibility | Status |
|------|---------------|--------|
| `org-jira-async.el` | Async HTTP: request, batch, rate limiting, progress | New (~250 lines) |
| `org-jira-core.el` | Add `org-jira--sync-in-progress` buffer-local var | Modify (151 → ~160 lines) |
| `org-jira-sync.el` | Rewrite sync-to-jira as phased async pipeline | Modify (407 → ~450 lines) |
| `org-jira-attachments.el` | Accept pre-fetched data in `sync-attachments` | Modify (294 → ~310 lines) |
| `org-jira-test-async.el` | Tests for async layer + sync phases | New (~350 lines) |
| `org-jira-test.el` | Add `load-file` for `org-jira-test-async.el` | Modify (83 → ~84 lines) |

---

### Task 1: Verify existing tests pass (baseline)

**Files:**
- None modified

- [ ] **Step 1: Run existing test suite**

```bash
make test
```

Expected: All tests pass. Record the count (e.g., "42 tests passed"). If any fail, stop and fix before proceeding.

- [ ] **Step 2: Commit baseline (no changes needed)**

No commit — this is a verification step only.

---

### Task 2: Add `org-jira--sync-in-progress` to core

**Files:**
- Modify: `org-jira-core.el:148` (before `(provide 'org-jira-core)`)

- [ ] **Step 1: Add the buffer-local variable**

In `org-jira-core.el`, add before the `(provide 'org-jira-core)` line:

```elisp
(defvar-local org-jira--sync-in-progress nil
  "Non-nil when an async sync is running in this buffer.
Guards against re-entrant sync calls and marks the buffer read-only.")
```

- [ ] **Step 2: Run tests**

```bash
make test
```

Expected: All existing tests still pass (no behavior change).

- [ ] **Step 3: Commit**

```bash
git add org-jira-core.el
git commit -m "feat: add org-jira--sync-in-progress buffer-local var"
```

---

### Task 3: Create `org-jira-async.el` — async request function

**Files:**
- Create: `org-jira-async.el`
- Create: `org-jira-test-async.el`
- Modify: `org-jira-test.el:19` (add load-file line)

- [ ] **Step 1: Write failing test for `org-jira--async-request` success path**

Create `org-jira-test-async.el`:

```elisp
;;; org-jira-test-async.el --- Tests for org-jira async layer  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(load-file (expand-file-name "org-jira.el" (file-name-directory (or load-file-name buffer-file-name))))
(load-file (expand-file-name "org-jira-async.el" (file-name-directory (or load-file-name buffer-file-name))))

;;;; org-jira--async-request tests

(ert-deftest org-jira-test-async--request-success ()
  "Test async request calls back with parsed JSON on 200."
  (let ((callback-result nil)
        (callback-err 'not-called)
        (org-jira--jira-base-url "https://test.atlassian.net")
        (org-jira--api-user "user@test.com")
        (org-jira--api-token "test-token"))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (url callback &rest _)
                 ;; Simulate async: call callback immediately with a mock buffer
                 (let ((buf (generate-new-buffer " *test-http*")))
                   (with-current-buffer buf
                     (insert "HTTP/1.1 200 OK\nContent-Type: application/json\n\n")
                     (insert "{\"key\":\"PROJ-123\",\"id\":\"456\"}"))
                   (funcall callback nil)
                   buf))))
      (org-jira--async-request
       "GET" "/rest/api/3/issue/PROJ-123"
       (lambda (response err)
         (setq callback-result response)
         (setq callback-err err)))
      ;; Callback should have fired
      (should (null callback-err))
      (should callback-result)
      (should (string= (cdr (assoc "key" callback-result)) "PROJ-123")))))

(ert-deftest org-jira-test-async--request-error ()
  "Test async request calls back with error on non-2xx."
  (let ((callback-result 'not-called)
        (callback-err nil)
        (org-jira--jira-base-url "https://test.atlassian.net")
        (org-jira--api-user "user@test.com")
        (org-jira--api-token "test-token"))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (url callback &rest _)
                 (let ((buf (generate-new-buffer " *test-http*")))
                   (with-current-buffer buf
                     (insert "HTTP/1.1 400 Bad Request\n\n")
                     (insert "{\"errorMessages\":[\"Field required\"]}"))
                   (funcall callback nil)
                   buf))))
      (org-jira--async-request
       "GET" "/rest/api/3/issue/BAD"
       (lambda (response err)
         (setq callback-result response)
         (setq callback-err err)))
      (should callback-err)
      (should (null callback-result)))))

(ert-deftest org-jira-test-async--request-encodes-utf8 ()
  "Test async request encodes JSON body as UTF-8."
  (let ((captured-data nil)
        (org-jira--jira-base-url "https://test.atlassian.net")
        (org-jira--api-user "user@test.com")
        (org-jira--api-token "test-token"))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (url callback &rest _)
                 ;; Capture url-request-data before it goes out of scope
                 (setq captured-data url-request-data)
                 (let ((buf (generate-new-buffer " *test-http*")))
                   (with-current-buffer buf
                     (insert "HTTP/1.1 200 OK\n\n{}"))
                   (funcall callback nil)
                   buf))))
      (org-jira--async-request
       "PUT" "/rest/api/3/issue/PROJ-1"
       #'ignore
       (list (cons 'fields (list (cons "summary" "Café résumé")))))
      ;; Data should be UTF-8 encoded
      (should captured-data)
      (should (string-match-p "Caf" captured-data))
      ;; UTF-8 encoding makes it longer than raw string
      (let* ((json-str (json-encode (list (cons 'fields (list (cons "summary" "Café résumé")))))))
        (should (> (length captured-data) (length json-str)))))))

(provide 'org-jira-test-async)
;;; org-jira-test-async.el ends here
```

- [ ] **Step 2: Register test file in aggregator**

In `org-jira-test.el`, add after the last `load-file` line (line 19):

```elisp
(load-file (expand-file-name "org-jira-test-async.el" (file-name-directory (or load-file-name buffer-file-name))))
```

- [ ] **Step 3: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL — `org-jira-async.el` doesn't exist yet, load fails.

- [ ] **Step 4: Implement `org-jira--async-request`**

Create `org-jira-async.el`:

```elisp
;;; org-jira-async.el --- Async HTTP layer for org-jira  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Neil Locketz

;; Author: Neil Locketz <neil@nlocketz.com>
;; Keywords: org, jira, project management
;; Version: 0.1.0

;;; Commentary:

;; Async HTTP layer for org-jira.
;; Provides non-blocking API requests, batch coordination, and rate limiting.

;;; Code:

(require 'org-jira-core)
(require 'url)
(require 'json)

;;;; Async HTTP Request

(defun org-jira--async-request (method endpoint callback &optional data)
  "Make an async API request to Jira.
METHOD is HTTP method (GET, POST, PUT, DELETE).
ENDPOINT is the API endpoint path.
CALLBACK is (lambda (response err) ...) called when the request completes.
DATA is optional request body (will be JSON-encoded as UTF-8)."
  (unless org-jira--jira-base-url
    (org-jira--resolve-config))
  (let* ((url (concat org-jira--jira-base-url endpoint))
         (url-request-method method)
         (url-request-extra-headers
          (list (cons "Content-Type" "application/json")
                (cons "Accept" "application/json")
                (cons "Authorization"
                      (concat "Basic "
                              (base64-encode-string
                               (concat org-jira--api-user ":" org-jira--api-token) t)))))
         (url-request-data
          (when data (encode-coding-string (json-encode data) 'utf-8))))
    (url-retrieve url
                  (lambda (_status)
                    (org-jira--async-parse-response (current-buffer) callback))
                  nil t)))

(defun org-jira--async-parse-response (buffer callback)
  "Parse HTTP response in BUFFER and invoke CALLBACK.
CALLBACK is (lambda (response err) ...)."
  (unwind-protect
      (with-current-buffer buffer
        (goto-char (point-min))
        (re-search-forward "^$" nil t)
        (let ((status (buffer-substring-no-properties (point-min) (point))))
          ;; 429 handling is added in Task 4; for now treat as error
          (if (string-match-p "HTTP/.* 2[0-9][0-9]" status)
                (let ((body (string-trim
                             (buffer-substring-no-properties (point) (point-max)))))
                  (if (or (string= body "") (string-match-p "^[[:space:]]*$" body))
                      (funcall callback nil nil)
                    (let ((json-object-type 'alist)
                          (json-array-type 'list))
                      (funcall callback (json-read-from-string body) nil))))
              (let ((body (buffer-substring-no-properties (point) (point-max))))
                (funcall callback nil
                         (format "Jira API error: %s\nResponse: %s"
                                 (string-trim status) (string-trim body))))))))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))

(provide 'org-jira-async)

;;; org-jira-async.el ends here
```

- [ ] **Step 5: Run tests**

```bash
make test
```

Expected: The 3 new async tests pass. All existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add org-jira-async.el org-jira-test-async.el org-jira-test.el
git commit -m "feat: add org-jira--async-request with async url-retrieve"
```

---

### Task 4: Add rate limiting to async request

**Files:**
- Modify: `org-jira-async.el`
- Modify: `org-jira-test-async.el`

- [ ] **Step 1: Write failing test for 429 retry**

Add to `org-jira-test-async.el` before the `(provide ...)` line:

```elisp
;;;; Rate limiting tests

(ert-deftest org-jira-test-async--request-retries-on-429 ()
  "Test async request retries after Retry-After delay on 429."
  (let ((attempt-count 0)
        (callback-result nil)
        (callback-err 'not-called)
        (org-jira--jira-base-url "https://test.atlassian.net")
        (org-jira--api-user "user@test.com")
        (org-jira--api-token "test-token"))
    ;; Reset rate limit state
    (org-jira--rate-limit-reset)
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (url callback &rest _)
                 (setq attempt-count (1+ attempt-count))
                 (let ((buf (generate-new-buffer " *test-http*")))
                   (with-current-buffer buf
                     (if (= attempt-count 1)
                         ;; First attempt: 429
                         (insert "HTTP/1.1 429 Too Many Requests\nRetry-After: 1\n\n")
                       ;; Retry: 200
                       (insert "HTTP/1.1 200 OK\n\n{\"key\":\"PROJ-1\"}")))
                   (funcall callback nil)
                   buf)))
              ;; Make run-at-time call the function immediately for testing
              ((symbol-function 'run-at-time)
               (lambda (_secs _repeat func &rest args)
                 (apply func args)
                 nil)))
      (org-jira--async-request
       "GET" "/rest/api/3/issue/PROJ-1"
       (lambda (response err)
         (setq callback-result response)
         (setq callback-err err)))
      (should (= attempt-count 2))
      (should (null callback-err))
      (should (string= (cdr (assoc "key" callback-result)) "PROJ-1")))))

(ert-deftest org-jira-test-async--rate-limit-state-throttles ()
  "Test that 429 sets throttle state and recovery opens back up."
  (org-jira--rate-limit-reset)
  ;; Simulate a 429
  (org-jira--rate-limit-on-429 5)
  (should (org-jira--rate-limit-throttled-p))
  ;; Simulate recovery
  (org-jira--rate-limit-reset)
  (should-not (org-jira--rate-limit-throttled-p)))
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL — `org-jira--rate-limit-reset`, `org-jira--handle-rate-limit`, etc. don't exist yet.

- [ ] **Step 3: Add rate limiting to `org-jira-async.el`**

Add before `(provide 'org-jira-async)`:

```elisp
;;;; Adaptive Rate Limiting

(defvar org-jira--rate-limit-throttled nil
  "Non-nil when rate-limited by Jira (received 429).")

(defvar org-jira--rate-limit-max-concurrent nil
  "Max concurrent requests during throttle. Nil means uncapped.")

(defvar org-jira--rate-limit-pending nil
  "Queue of (lambda () ...) thunks waiting for rate limit to clear.")

(defun org-jira--rate-limit-reset ()
  "Reset rate limit state to uncapped."
  (setq org-jira--rate-limit-throttled nil)
  (setq org-jira--rate-limit-max-concurrent nil)
  (setq org-jira--rate-limit-pending nil))

(defun org-jira--rate-limit-throttled-p ()
  "Return non-nil if currently rate-limited."
  org-jira--rate-limit-throttled)

(defun org-jira--rate-limit-on-429 (retry-after)
  "Handle a 429 response. RETRY-AFTER is delay in seconds."
  (setq org-jira--rate-limit-throttled t)
  (setq org-jira--rate-limit-max-concurrent
        (max 1 (/ (or org-jira--rate-limit-max-concurrent 10) 2)))
  (run-at-time retry-after nil #'org-jira--rate-limit-resume))

(defun org-jira--rate-limit-resume ()
  "Resume pending requests after rate limit delay."
  (setq org-jira--rate-limit-throttled nil)
  ;; Drain pending queue
  (let ((pending (copy-sequence org-jira--rate-limit-pending)))
    (setq org-jira--rate-limit-pending nil)
    (dolist (thunk pending)
      (funcall thunk))))

(defun org-jira--handle-rate-limit (buffer callback)
  "Handle a 429 response in BUFFER by retrying after delay.
Re-invokes the original request via CALLBACK after Retry-After seconds."
  (let* ((retry-after
          (with-current-buffer buffer
            (goto-char (point-min))
            (if (re-search-forward "Retry-After: \\([0-9]+\\)" nil t)
                (string-to-number (match-string 1))
              5))))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))
    ;; Store retry info and schedule
    (org-jira--rate-limit-on-429 retry-after)))
```

Now update `org-jira--handle-rate-limit` to actually retry. This requires the original request parameters. Refactor `org-jira--async-request` to pass them through:

Replace the `org-jira--async-parse-response` call inside `org-jira--async-request` with a closure that captures the retry context. Update `org-jira--async-request`:

```elisp
(defun org-jira--async-request (method endpoint callback &optional data)
  "Make an async API request to Jira.
METHOD is HTTP method (GET, POST, PUT, DELETE).
ENDPOINT is the API endpoint path.
CALLBACK is (lambda (response err) ...) called when the request completes.
DATA is optional request body (will be JSON-encoded as UTF-8)."
  (unless org-jira--jira-base-url
    (org-jira--resolve-config))
  (let* ((url (concat org-jira--jira-base-url endpoint))
         (url-request-method method)
         (url-request-extra-headers
          (list (cons "Content-Type" "application/json")
                (cons "Accept" "application/json")
                (cons "Authorization"
                      (concat "Basic "
                              (base64-encode-string
                               (concat org-jira--api-user ":" org-jira--api-token) t)))))
         (url-request-data
          (when data (encode-coding-string (json-encode data) 'utf-8)))
         (retry-fn (lambda ()
                     (org-jira--async-request method endpoint callback data))))
    (if (org-jira--rate-limit-throttled-p)
        ;; Queue for later
        (push retry-fn org-jira--rate-limit-pending)
      (url-retrieve url
                    (lambda (_status)
                      (org-jira--async-parse-response
                       (current-buffer) callback retry-fn))
                    nil t))))
```

Update `org-jira--async-parse-response` to accept RETRY-FN:

```elisp
(defun org-jira--async-parse-response (buffer callback retry-fn)
  "Parse HTTP response in BUFFER and invoke CALLBACK.
CALLBACK is (lambda (response err) ...).
RETRY-FN is called to retry the request on 429."
  (unwind-protect
      (with-current-buffer buffer
        (goto-char (point-min))
        (re-search-forward "^$" nil t)
        (let ((status (buffer-substring-no-properties (point-min) (point))))
          (if (string-match-p "HTTP/.* 429" status)
              (progn
                (let ((retry-after
                       (progn
                         (goto-char (point-min))
                         (if (re-search-forward "Retry-After: \\([0-9]+\\)" nil t)
                             (string-to-number (match-string 1))
                           5))))
                  (org-jira--rate-limit-on-429 retry-after)
                  ;; Add retry to pending queue (will fire after delay)
                  (push retry-fn org-jira--rate-limit-pending)))
            (if (string-match-p "HTTP/.* 2[0-9][0-9]" status)
                (let ((body (string-trim
                             (buffer-substring-no-properties (point) (point-max)))))
                  (if (or (string= body "") (string-match-p "^[[:space:]]*$" body))
                      (funcall callback nil nil)
                    (let ((json-object-type 'alist)
                          (json-array-type 'list))
                      (funcall callback (json-read-from-string body) nil))))
              (let ((body (buffer-substring-no-properties (point) (point-max))))
                (funcall callback nil
                         (format "Jira API error: %s\nResponse: %s"
                                 (string-trim status) (string-trim body))))))))
    (when (buffer-live-p buffer)
      (kill-buffer buffer))))
```

Also remove the now-unused standalone `org-jira--handle-rate-limit` function since the logic is inline in `org-jira--async-parse-response`.

- [ ] **Step 4: Run tests**

```bash
make test
```

Expected: All tests pass including the 2 new rate limit tests.

- [ ] **Step 5: Commit**

```bash
git add org-jira-async.el org-jira-test-async.el
git commit -m "feat: add adaptive rate limiting to async requests"
```

---

### Task 5: Add `org-jira--async-batch`

**Files:**
- Modify: `org-jira-async.el`
- Modify: `org-jira-test-async.el`

- [ ] **Step 1: Write failing test for batch**

Add to `org-jira-test-async.el` before `(provide ...)`:

```elisp
;;;; Batch tests

(ert-deftest org-jira-test-async--batch-all-succeed ()
  "Test batch calls final callback with all results in order."
  (let ((final-results nil)
        (org-jira--jira-base-url "https://test.atlassian.net")
        (org-jira--api-user "user@test.com")
        (org-jira--api-token "test-token"))
    (org-jira--rate-limit-reset)
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (url callback &rest _)
                 (let ((buf (generate-new-buffer " *test-http*"))
                       ;; Extract key from URL path
                       (key (when (string-match "/issue/\\(PROJ-[0-9]+\\)" url)
                              (match-string 1 url))))
                   (with-current-buffer buf
                     (insert (format "HTTP/1.1 200 OK\n\n{\"key\":\"%s\"}" (or key "UNKNOWN"))))
                   (funcall callback nil)
                   buf))))
      (org-jira--async-batch
       (list (lambda () (org-jira--async-request
                         "GET" "/rest/api/3/issue/PROJ-1"
                         (lambda (r e) (cons r e))))
             (lambda () (org-jira--async-request
                         "GET" "/rest/api/3/issue/PROJ-2"
                         (lambda (r e) (cons r e))))
             (lambda () (org-jira--async-request
                         "GET" "/rest/api/3/issue/PROJ-3"
                         (lambda (r e) (cons r e)))))
       (lambda (results) (setq final-results results)))
      (should final-results)
      (should (= (length final-results) 3)))))

(ert-deftest org-jira-test-async--batch-empty ()
  "Test batch with no thunks calls final callback immediately."
  (let ((final-called nil))
    (org-jira--async-batch
     nil
     (lambda (results)
       (setq final-called t)
       (should (null results))))
    (should final-called)))
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
make test
```

Expected: FAIL — `org-jira--async-batch` doesn't exist.

- [ ] **Step 3: Implement `org-jira--async-batch`**

Add to `org-jira-async.el` before the rate limiting section:

```elisp
;;;; Batch Coordination

(defun org-jira--async-batch (thunks final-callback)
  "Fire all THUNKS and call FINAL-CALLBACK when all complete.
THUNKS is a list of (lambda () ...) functions. Each thunk must accept
a callback as part of its own setup (typically via `org-jira--async-request`).
FINAL-CALLBACK is (lambda (results) ...) called once all thunks complete.
RESULTS is a list of (response . err) pairs in thunk order.

Each thunk is a zero-arg function that fires one async operation.
The thunk is responsible for calling a callback that records its result."
  (if (null thunks)
      (funcall final-callback nil)
    (let* ((total (length thunks))
           (completed 0)
           (results (make-vector total nil)))
      (cl-loop for thunk in thunks
               for idx from 0
               do (let ((i idx)
                        (fn thunk))
                    (funcall fn
                             (lambda (response err)
                               (aset results i (cons response err))
                               (setq completed (1+ completed))
                               (when (= completed total)
                                 (funcall final-callback
                                          (append results nil))))))))))
```

**Important:** This changes the thunk contract — each thunk now receives a callback argument. Update the test to match:

```elisp
(ert-deftest org-jira-test-async--batch-all-succeed ()
  "Test batch calls final callback with all results in order."
  (let ((final-results nil)
        (org-jira--jira-base-url "https://test.atlassian.net")
        (org-jira--api-user "user@test.com")
        (org-jira--api-token "test-token"))
    (org-jira--rate-limit-reset)
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (url callback &rest _)
                 (let ((buf (generate-new-buffer " *test-http*"))
                       (key (when (string-match "/issue/\\(PROJ-[0-9]+\\)" url)
                              (match-string 1 url))))
                   (with-current-buffer buf
                     (insert (format "HTTP/1.1 200 OK\n\n{\"key\":\"%s\"}" (or key "UNKNOWN"))))
                   (funcall callback nil)
                   buf))))
      (org-jira--async-batch
       (list (lambda (cb) (org-jira--async-request "GET" "/rest/api/3/issue/PROJ-1" cb))
             (lambda (cb) (org-jira--async-request "GET" "/rest/api/3/issue/PROJ-2" cb))
             (lambda (cb) (org-jira--async-request "GET" "/rest/api/3/issue/PROJ-3" cb)))
       (lambda (results) (setq final-results results)))
      (should final-results)
      (should (= (length final-results) 3))
      ;; Results should be in order
      (should (string= (cdr (assoc "key" (car (nth 0 final-results)))) "PROJ-1"))
      (should (string= (cdr (assoc "key" (car (nth 2 final-results)))) "PROJ-3")))))
```

- [ ] **Step 4: Run tests**

```bash
make test
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add org-jira-async.el org-jira-test-async.el
git commit -m "feat: add org-jira--async-batch for parallel request coordination"
```

---

### Task 6: Add modeline progress indicator

**Files:**
- Modify: `org-jira-async.el`
- Modify: `org-jira-test-async.el`

- [ ] **Step 1: Write failing test for progress**

Add to `org-jira-test-async.el` before `(provide ...)`:

```elisp
;;;; Progress indicator tests

(ert-deftest org-jira-test-async--progress-displays ()
  "Test that progress indicator updates and clears."
  (with-temp-buffer
    (org-jira--progress-init 10)
    (should (string-match-p "0/10" (org-jira--progress-format)))
    (org-jira--progress-tick)
    (org-jira--progress-tick)
    (should (string-match-p "2/10" (org-jira--progress-format)))
    (org-jira--progress-clear)
    (should (string= "" (org-jira--progress-format)))))
```

- [ ] **Step 2: Run tests to verify failure**

```bash
make test
```

Expected: FAIL — progress functions don't exist.

- [ ] **Step 3: Implement progress indicator**

Add to `org-jira-async.el` before the rate limiting section:

```elisp
;;;; Modeline Progress Indicator

(defvar-local org-jira--progress-current 0
  "Number of completed operations in current sync.")

(defvar-local org-jira--progress-total 0
  "Total number of operations in current sync.")

(defvar-local org-jira--progress-active nil
  "Non-nil when progress indicator is active.")

(defun org-jira--progress-init (total)
  "Initialize progress indicator with TOTAL operations."
  (setq org-jira--progress-current 0)
  (setq org-jira--progress-total total)
  (setq org-jira--progress-active t)
  (unless (memq 'org-jira--progress-modeline-string global-mode-string)
    (push 'org-jira--progress-modeline-string global-mode-string))
  (force-mode-line-update t))

(defun org-jira--progress-tick ()
  "Increment progress by one."
  (setq org-jira--progress-current (1+ org-jira--progress-current))
  (force-mode-line-update t))

(defun org-jira--progress-clear ()
  "Clear the progress indicator."
  (setq org-jira--progress-active nil)
  (setq org-jira--progress-current 0)
  (setq org-jira--progress-total 0)
  (setq global-mode-string
        (delq 'org-jira--progress-modeline-string global-mode-string))
  (force-mode-line-update t))

(defun org-jira--progress-format ()
  "Return the current progress string."
  (if org-jira--progress-active
      (format " [org-jira: %d/%d]" org-jira--progress-current org-jira--progress-total)
    ""))

(defvar org-jira--progress-modeline-string
  '(:eval (org-jira--progress-format))
  "Modeline construct for org-jira sync progress.")
(put 'org-jira--progress-modeline-string 'risky-local-variable t)
```

- [ ] **Step 4: Run tests**

```bash
make test
```

Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add org-jira-async.el org-jira-test-async.el
git commit -m "feat: add modeline progress indicator for sync"
```

---

### Task 7: Refactor `org-jira--sync-attachments` to accept pre-fetched data

**Files:**
- Modify: `org-jira-attachments.el:262-282`
- Modify: `org-jira-test-async.el`

- [ ] **Step 1: Write failing test for pre-fetched attachment data**

Add to `org-jira-test-async.el` before `(provide ...)`:

```elisp
;;;; Attachment consolidation tests

(ert-deftest org-jira-test-async--sync-attachments-uses-prefetched ()
  "Test that sync-attachments skips GET when given pre-fetched data."
  (let ((api-calls nil))
    (cl-letf (((symbol-function 'org-jira--api-request)
               (lambda (method endpoint &rest _)
                 (push (list method endpoint) api-calls)
                 nil))
              ((symbol-function 'org-jira--download-attachments) #'ignore)
              ((symbol-function 'org-jira--upload-attachments) #'ignore))
      (with-temp-buffer
        (org-mode)
        (insert "* Test Feature\n")
        (org-entry-put (point) "JIRA_KEY" "PROJ-1")
        (let ((ticket (org-jira--ticket-create
                       :key "PROJ-1" :type "Feature" :summary "Test")))
          ;; Pass pre-fetched attachments: should NOT call GET
          (org-jira--sync-attachments ticket '(((filename . "a.png"))))
          (should (null api-calls)))))))
```

- [ ] **Step 2: Run tests to verify failure**

```bash
make test
```

Expected: FAIL — `org-jira--sync-attachments` doesn't accept a second argument yet.

- [ ] **Step 3: Update `org-jira--sync-attachments` to accept optional pre-fetched data**

In `org-jira-attachments.el`, change the function signature and body at line 262:

Old:
```elisp
(defun org-jira--sync-attachments (ticket)
  "Sync attachments for TICKET between Jira and org-attach.
This is bidirectional:
1. Downloads from Jira to org-attach (new attachments).
2. Uploads local org-attach files to Jira (new files).
Matching is by filename."
  (let ((key (org-jira--ticket-key ticket)))
    ;; Guard: don't sync if no valid key
    (unless (and key (stringp key) (> (length key) 0))
      (when org-jira-debug
        (message "org-jira: Skipping attachment sync for ticket without a valid key"))
      (setq key nil))

    ;; Only proceed if we have a valid key
    (when key
      ;; Get existing attachments from Jira
      (let ((jira-attachments (org-jira--get-attachments key)))
        ;; Download new attachments from Jira to org-attach
        (org-jira--download-attachments key jira-attachments)
        ;; Upload new local attachments to Jira
        (org-jira--upload-attachments key)))))
```

New:
```elisp
(defun org-jira--sync-attachments (ticket &optional prefetched-attachments)
  "Sync attachments for TICKET between Jira and org-attach.
This is bidirectional:
1. Downloads from Jira to org-attach (new attachments).
2. Uploads local org-attach files to Jira (new files).
Matching is by filename.
PREFETCHED-ATTACHMENTS, if non-nil, skips the GET and uses this data."
  (let ((key (org-jira--ticket-key ticket)))
    ;; Guard: don't sync if no valid key
    (unless (and key (stringp key) (> (length key) 0))
      (when org-jira-debug
        (message "org-jira: Skipping attachment sync for ticket without a valid key"))
      (setq key nil))

    ;; Only proceed if we have a valid key
    (when key
      ;; Use pre-fetched data or fetch from Jira
      (let ((jira-attachments (or prefetched-attachments
                                  (org-jira--get-attachments key))))
        ;; Download new attachments from Jira to org-attach
        (org-jira--download-attachments key jira-attachments)
        ;; Upload new local attachments to Jira
        (org-jira--upload-attachments key)))))
```

- [ ] **Step 4: Run tests**

```bash
make test
```

Expected: All tests pass — existing callers pass 1 arg (still works), new test passes 2 args.

- [ ] **Step 5: Commit**

```bash
git add org-jira-attachments.el org-jira-test-async.el
git commit -m "refactor: allow sync-attachments to accept pre-fetched data"
```

---

### Task 8: Rewrite `org-jira--sync-to-jira` as phased async pipeline

**Files:**
- Modify: `org-jira-sync.el:219-256`
- Modify: `org-jira-test-async.el`

This is the largest task. It replaces the sequential `org-jira--sync-to-jira` with a phased async pipeline. Each phase is a named top-level function.

- [ ] **Step 1: Write failing test for buffer protection and phase flow**

Add to `org-jira-test-async.el` before `(provide ...)`:

```elisp
;;;; Phased sync tests

(ert-deftest org-jira-test-async--sync-sets-buffer-readonly ()
  "Test that sync marks buffer read-only and clears after."
  (let ((org-jira--jira-base-url "https://test.atlassian.net")
        (org-jira--api-user "user@test.com")
        (org-jira--api-token "test-token")
        (org-jira--issue-type-ids '(("New Feature" . "1") ("Story" . "2")))
        (org-jira-default-sprint nil))
    (org-jira--rate-limit-reset)
    (cl-letf (((symbol-function 'org-jira--resolve-config) #'ignore)
              ((symbol-function 'org-jira--clear-sprint-cache) #'ignore)
              ((symbol-function 'org-jira--ensure-issue-types) #'ignore)
              ((symbol-function 'url-retrieve)
               (lambda (url callback &rest _)
                 (let ((buf (generate-new-buffer " *test-http*")))
                   (with-current-buffer buf
                     (insert "HTTP/1.1 200 OK\n\n{\"fields\":{}}"))
                   (funcall callback nil)
                   buf))))
      (with-temp-buffer
        (org-mode)
        (insert "* Test Feature\n")
        (org-entry-put (point) "JIRA_KEY" "PROJ-1")
        (org-entry-put (point) "JIRA_TYPE" "New Feature")
        ;; Should not be read-only before sync
        (should-not buffer-read-only)
        (org-jira--sync-to-jira)
        ;; After sync completes, buffer should be writable again
        (should-not buffer-read-only)
        (should-not org-jira--sync-in-progress)))))

(ert-deftest org-jira-test-async--sync-rejects-reentrant ()
  "Test that sync rejects a second call while in progress."
  (with-temp-buffer
    (org-mode)
    (setq org-jira--sync-in-progress t)
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (org-jira--sync-to-jira)
        (should (cl-some (lambda (m) (string-match-p "already in progress" m)) messages))))
    (setq org-jira--sync-in-progress nil)))
```

- [ ] **Step 2: Run tests to verify failure**

```bash
make test
```

Expected: FAIL — current `org-jira--sync-to-jira` doesn't check `org-jira--sync-in-progress` or set read-only.

- [ ] **Step 3: Implement phased sync**

Replace `org-jira--sync-to-jira` (lines 219-256 of `org-jira-sync.el`) with:

```elisp
;;;; Phased Async Sync

(defun org-jira--all-features-exist-p (features)
  "Return t if every ticket in FEATURES has a non-empty JIRA_KEY."
  (cl-every (lambda (f)
              (let ((key (org-jira--ticket-key f)))
                (and key (stringp key) (> (length key) 0))))
            features))

;;;###autoload
(defun org-jira--sync-to-jira ()
  "Sync all tickets in the org document to Jira asynchronously.
Phase 0: Setup. Phase 1: Create/update tickets.
Phase 2: Attachments + links. Phase 3: Apply results to buffer."
  (interactive)
  (cl-block org-jira--sync-to-jira
    ;; Guard: reject re-entrant calls
    (when org-jira--sync-in-progress
      (message "org-jira: Sync already in progress")
      (cl-return-from org-jira--sync-to-jira nil))
    ;; Phase 0: Setup
    (org-jira--clear-sprint-cache)
    (org-jira--ensure-issue-types)
    (let* ((doc (org-jira--parse-document))
           (features (org-jira--doc-features doc))
           (stories (org-jira--doc-stories doc))
           (all-tickets (org-jira--doc-tickets doc))
           (all-exist (org-jira--all-features-exist-p features))
           (total (length all-tickets))
           (buf (current-buffer))
           (results (make-hash-table :test 'equal)))
      (setq org-jira--sync-in-progress t)
      (setq buffer-read-only t)
      (org-jira--progress-init total)
      (message "org-jira: Syncing %d tickets to Jira..." total)
      ;; Phase 1
      (if all-exist
          ;; All features exist: fire everything in parallel
          (org-jira--sync-phase-1 all-tickets buf doc results)
        ;; Features first, then stories
        (org-jira--sync-phase-1
         features buf doc results
         (lambda ()
           (org-jira--sync-phase-1 stories buf doc results)))))))

(defun org-jira--sync-phase-1 (tickets buf doc results &optional then)
  "Phase 1: create/update TICKETS asynchronously.
BUF is the org buffer. DOC is the parsed document. RESULTS is a hash table.
THEN is an optional callback to run before Phase 2 (e.g., to sync stories
after features). If nil, proceeds directly to Phase 2."
  (if (null tickets)
      (if then
          (funcall then)
        (org-jira--sync-phase-2 buf doc results))
    (org-jira--async-batch
     (mapcar (lambda (ticket)
               (lambda (batch-cb)
                 (org-jira--sync-one-ticket ticket buf results batch-cb)))
             tickets)
     (lambda (_batch-results)
       (if then
           (funcall then)
         (org-jira--sync-phase-2 buf doc results))))))

(defun org-jira--sync-one-ticket (ticket buf results batch-cb)
  "Sync a single TICKET asynchronously.
BUF is the org buffer. RESULTS accumulates fetched data.
BATCH-CB is (lambda (response err) ...) to signal batch completion."
  (let ((key (org-jira--ticket-key ticket)))
    (if (and key (stringp key) (> (length key) 0))
        ;; Existing ticket: GET full data, then PUT update
        (org-jira--sync-existing-ticket ticket key buf results batch-cb)
      ;; New ticket: POST create
      (org-jira--sync-new-ticket ticket buf results batch-cb))))

(defun org-jira--sync-existing-ticket (ticket key buf results batch-cb)
  "Fetch and update an existing TICKET with KEY.
BUF is the org buffer. RESULTS stores fetched data. BATCH-CB signals done."
  (org-jira--async-request
   "GET" (concat "/rest/api/3/issue/" key)
   (lambda (response err)
     (if err
         (funcall batch-cb nil err)
       ;; Store fetched data for Phase 2 and Phase 3
       (puthash key response results)
       ;; Build and fire PUT
       (org-jira--fire-ticket-update ticket response buf batch-cb)))))

(defun org-jira--fire-ticket-update (ticket response buf batch-cb)
  "Fire PUT to update TICKET using fetched RESPONSE for ADF resolution.
BUF is the org buffer. BATCH-CB signals done."
  (let* ((key (org-jira--ticket-key ticket))
         (fields (org-jira--alist-get "fields" response))
         (jira-attachments (when fields
                             (cdr (assoc "attachment" fields))))
         (description-raw (org-jira--ticket-description ticket))
         (update-data (org-jira--build-update-fields ticket jira-attachments)))
    (if update-data
        (org-jira--async-request
         "PUT" (concat "/rest/api/3/issue/" key)
         (lambda (_resp err)
           (when buf (org-jira--progress-tick-in-buffer buf))
           (funcall batch-cb nil err))
         update-data)
      (when buf (org-jira--progress-tick-in-buffer buf))
      (funcall batch-cb nil nil))))

(defun org-jira--build-update-fields (ticket jira-attachments)
  "Build the update payload for TICKET.
JIRA-ATTACHMENTS is the attachment list for ADF mediaInline resolution.
Returns a (fields ...) alist suitable for the PUT body, or nil if empty."
  (let ((fields nil)
        (summary (org-jira--ticket-summary ticket))
        (description-raw (org-jira--ticket-description ticket))
        (fix-version (org-jira--ticket-fix-version ticket))
        (labels (org-jira--ticket-labels ticket))
        (story-points (org-jira--ticket-story-points ticket))
        (due-date (org-jira--ticket-due-date ticket)))
    (when summary
      (push (cons 'summary summary) fields))
    (when (and description-raw (not (string= description-raw "")))
      (let ((adf-desc (org-jira--build-adf-description description-raw jira-attachments)))
        (when adf-desc
          (push (cons 'description adf-desc) fields))))
    (when (and fix-version (not (string= fix-version "")))
      (push (cons 'fixVersions (list (list (cons "name" fix-version)))) fields))
    (when labels
      (push (cons 'labels labels) fields))
    (when story-points
      (push (cons 'customfield_10016 story-points) fields))
    (when (and due-date (not (string= due-date "")))
      (push (cons 'duedate due-date) fields))
    (when fields
      (list (cons 'fields fields)))))

(defun org-jira--sync-new-ticket (ticket buf results batch-cb)
  "Create a new TICKET via POST.
BUF is the org buffer. RESULTS stores the new key. BATCH-CB signals done."
  (let* ((type (org-jira--ticket-type ticket))
         (jira-type (if (string= type "Feature") "New Feature" type))
         (issue-type-id (cdr (assoc jira-type org-jira--issue-type-ids)))
         (fields (list (cons 'project (list (cons "id" org-jira--project-id)))
                       (cons 'summary (org-jira--ticket-summary ticket))
                       (cons 'issuetype (list (cons "id" issue-type-id))))))
    ;; Add optional fields
    (let ((desc (org-jira--ticket-description ticket)))
      (when (and desc (not (string= desc "")))
        (let ((adf (org-jira--build-adf-description desc nil)))
          (when adf (push (cons 'description adf) fields)))))
    (let ((fv (org-jira--ticket-fix-version ticket)))
      (when (and fv (not (string= fv "")))
        (push (cons 'fixVersions (list (list (cons "name" fv)))) fields)))
    (let ((labels (org-jira--ticket-labels ticket)))
      (when labels (push (cons 'labels labels) fields)))
    (let ((sp (org-jira--ticket-story-points ticket)))
      (when sp (push (cons 'customfield_10016 sp) fields)))
    (let ((dd (org-jira--ticket-due-date ticket)))
      (when (and dd (not (string= dd "")))
        (push (cons 'duedate dd) fields)))
    (when org-jira-default-sprint
      (let ((sprint-id (org-jira--resolve-sprint-value org-jira-default-sprint)))
        (when sprint-id
          (push (cons 'customfield_10020 sprint-id) fields))))
    (org-jira--async-request
     "POST" "/rest/api/3/issue"
     (lambda (response err)
       (unless err
         (let ((new-key (or (cdr (assoc "key" response))
                            (cdr (assoc (intern-soft "key") response)))))
           (when new-key
             ;; Store new key for Phase 3
             (puthash (org-jira--ticket-summary ticket)
                      (list (cons 'new-key new-key)
                            (cons 'ticket ticket))
                      results)
             (setf (org-jira--ticket-key ticket) new-key))))
       (when buf (org-jira--progress-tick-in-buffer buf))
       (funcall batch-cb nil err))
     (list (cons 'fields fields)))))

(defun org-jira--progress-tick-in-buffer (buf)
  "Increment progress in BUF if it's still alive."
  (when (buffer-live-p buf)
    (with-current-buffer buf
      (org-jira--progress-tick))))

(defun org-jira--sync-phase-2 (buf doc results)
  "Phase 2: sync attachments and links for all tickets.
BUF is the org buffer. DOC is the parsed document. RESULTS has fetched data."
  (let ((thunks nil))
    ;; Build thunks for link creation
    (dolist (ticket (org-jira--doc-tickets doc))
      (push (lambda (cb)
              (with-current-buffer buf
                (org-jira--sync-ticket-links ticket))
              (funcall cb nil nil))
            thunks))
    ;; Build thunks for attachment sync
    (dolist (ticket (org-jira--doc-tickets doc))
      (let ((key (org-jira--ticket-key ticket)))
        (when (and key (stringp key) (> (length key) 0))
          (let ((fetched (gethash key results)))
            (push (lambda (cb)
                    (with-current-buffer buf
                      (let* ((fields (when fetched (org-jira--alist-get "fields" fetched)))
                             (att (when fields (cdr (assoc "attachment" fields)))))
                        (org-jira--sync-attachments ticket att)))
                    (when buf (org-jira--progress-tick-in-buffer buf))
                    (funcall cb nil nil))
                  thunks)))))
    (org-jira--async-batch
     (nreverse thunks)
     (lambda (_results)
       (org-jira--sync-phase-3 buf doc results)))))

(defun org-jira--sync-phase-3 (buf doc results)
  "Phase 3: apply accumulated results to org buffer.
BUF is the org buffer. DOC is the parsed document.
RESULTS has fetched Jira responses keyed by ticket key."
  (cl-block org-jira--sync-phase-3
    (unless (buffer-live-p buf)
      (message "org-jira: Buffer was killed during sync")
      (cl-return-from org-jira--sync-phase-3 nil))
    (with-current-buffer buf
    (let ((inhibit-read-only t))
      ;; Apply new keys for created tickets
      (maphash (lambda (summary-or-key data)
                 (when (and (listp data) (assoc 'new-key data))
                   (let* ((new-key (cdr (assoc 'new-key data)))
                          (ticket (cdr (assoc 'ticket data))))
                     (org-jira--set-org-ticket-key
                      (org-jira--ticket-org-node ticket) new-key)
                     (when org-jira-default-sprint
                       (org-jira--set-org-sprint
                        new-key (format "%s" org-jira-default-sprint))))))
               results)
      ;; Apply sprint and due-date from fetched responses
      (dolist (ticket (org-jira--doc-tickets doc))
        (let* ((key (org-jira--ticket-key ticket))
               (fetched (when key (gethash key results))))
          (when fetched
            (org-jira--apply-fetched-sprint ticket fetched)
            (org-jira--apply-fetched-due-date ticket fetched))))
      ;; Inherit due dates from parent features to stories
      (dolist (story (org-jira--doc-stories doc))
        (let ((parent-key (or (org-jira--ticket-parent story)
                              (save-excursion
                                (goto-char (org-element-property
                                            :begin (org-jira--ticket-org-node story)))
                                (org-jira--find-parent-ticket-key)))))
          (when parent-key
            (org-jira--inherit-due-date (org-jira--ticket-key story) parent-key))))
      ;; Resolve blocked-by → blocks display
      (org-jira--resolve-blocked-by-in-org doc))
    ;; Cleanup
    (setq buffer-read-only nil)
    (setq org-jira--sync-in-progress nil)
    (org-jira--progress-clear)
    (message "org-jira: Sync complete (%d tickets)" (length (org-jira--doc-tickets doc))))))

(defun org-jira--apply-fetched-sprint (ticket fetched)
  "Update sprint in org from FETCHED Jira response for TICKET."
  (let* ((key (org-jira--ticket-key ticket))
         (org-sprint (org-jira--ticket-sprint ticket))
         (fields (org-jira--alist-get "fields" fetched))
         (sprint-data (when fields (org-jira--alist-get "customfield_10020" fields)))
         (jira-sprint (org-jira--parse-sprint-from-jira-response sprint-data)))
    (when (and jira-sprint (not (equal jira-sprint org-sprint)))
      (org-jira--set-org-sprint key jira-sprint))))

(defun org-jira--apply-fetched-due-date (ticket fetched)
  "Update due date in org from FETCHED Jira response for TICKET."
  (let* ((key (org-jira--ticket-key ticket))
         (org-due-date (org-jira--ticket-due-date ticket))
         (fields (org-jira--alist-get "fields" fetched))
         (jira-due-date (when fields (org-jira--alist-get "duedate" fields))))
    (when (and jira-due-date (not (equal jira-due-date org-due-date)))
      (org-jira--set-org-due-date key jira-due-date))))
```

- [ ] **Step 4: Run tests**

```bash
make test
```

Expected: All existing tests pass. The 2 new phase tests pass.

- [ ] **Step 5: Commit**

```bash
git add org-jira-sync.el org-jira-test-async.el
git commit -m "feat: rewrite sync-to-jira as phased async pipeline"
```

---

### Task 9: Add request consolidation test

**Files:**
- Modify: `org-jira-test-async.el`

- [ ] **Step 1: Write test verifying 1 GET + 1 PUT per existing ticket**

Add to `org-jira-test-async.el` before `(provide ...)`:

```elisp
;;;; Request consolidation tests

(ert-deftest org-jira-test-async--existing-ticket-fires-one-get-one-put ()
  "Test that syncing an existing ticket fires exactly 1 GET + 1 PUT."
  (let ((request-log nil)
        (org-jira--jira-base-url "https://test.atlassian.net")
        (org-jira--api-user "user@test.com")
        (org-jira--api-token "test-token")
        (org-jira--issue-type-ids '(("New Feature" . "1")))
        (org-jira-default-sprint nil))
    (org-jira--rate-limit-reset)
    (cl-letf (((symbol-function 'org-jira--resolve-config) #'ignore)
              ((symbol-function 'org-jira--clear-sprint-cache) #'ignore)
              ((symbol-function 'org-jira--ensure-issue-types) #'ignore)
              ((symbol-function 'org-jira--sync-ticket-links) #'ignore)
              ((symbol-function 'org-jira--sync-attachments) #'ignore)
              ((symbol-function 'org-jira--resolve-blocked-by-in-org) #'ignore)
              ((symbol-function 'url-retrieve)
               (lambda (url callback &rest _)
                 (let ((method url-request-method)
                       (buf (generate-new-buffer " *test-http*")))
                   (push method request-log)
                   (with-current-buffer buf
                     (pcase method
                       ("GET"
                        (insert "HTTP/1.1 200 OK\n\n")
                        (insert "{\"fields\":{\"attachment\":[],\"customfield_10020\":null,\"duedate\":null}}"))
                       ("PUT"
                        (insert "HTTP/1.1 204 No Content\n\n"))))
                   (funcall callback nil)
                   buf))))
      (with-temp-buffer
        (org-mode)
        (insert "* Test Feature\n")
        (org-entry-put (point) "JIRA_KEY" "PROJ-1")
        (org-entry-put (point) "JIRA_TYPE" "New Feature")
        (org-jira--sync-to-jira)
        ;; Should have exactly 1 GET and 1 PUT
        (should (= (cl-count "GET" request-log :test #'string=) 1))
        (should (= (cl-count "PUT" request-log :test #'string=) 1))
        ;; Total: 2 requests (down from 5)
        (should (= (length request-log) 2))))))
```

- [ ] **Step 2: Run tests**

```bash
make test
```

Expected: All tests pass. This verifies the consolidation actually works.

- [ ] **Step 3: Commit**

```bash
git add org-jira-test-async.el
git commit -m "test: verify request consolidation (1 GET + 1 PUT per ticket)"
```

---

### Task 10: Add `all-features-exist-p` parallel grouping test

**Files:**
- Modify: `org-jira-test-async.el`

- [ ] **Step 1: Write test for full-parallel when all features exist**

Add to `org-jira-test-async.el` before `(provide ...)`:

```elisp
(ert-deftest org-jira-test-async--all-features-exist-full-parallel ()
  "When all features have keys, stories fire in same batch."
  (let ((batch-call-count 0)
        (org-jira--jira-base-url "https://test.atlassian.net")
        (org-jira--api-user "user@test.com")
        (org-jira--api-token "test-token")
        (org-jira--issue-type-ids '(("New Feature" . "1") ("Story" . "2")))
        (org-jira-default-sprint nil))
    (org-jira--rate-limit-reset)
    (cl-letf (((symbol-function 'org-jira--resolve-config) #'ignore)
              ((symbol-function 'org-jira--clear-sprint-cache) #'ignore)
              ((symbol-function 'org-jira--ensure-issue-types) #'ignore)
              ((symbol-function 'org-jira--sync-ticket-links) #'ignore)
              ((symbol-function 'org-jira--sync-attachments) #'ignore)
              ((symbol-function 'org-jira--resolve-blocked-by-in-org) #'ignore)
              ((symbol-function 'org-jira--async-batch)
               (lambda (thunks final-cb)
                 (setq batch-call-count (1+ batch-call-count))
                 ;; Execute thunks synchronously for testing
                 (dolist (thunk thunks)
                   (funcall thunk (lambda (_r _e) nil)))
                 (funcall final-cb nil)))
              ((symbol-function 'url-retrieve)
               (lambda (url callback &rest _)
                 (let ((buf (generate-new-buffer " *test-http*")))
                   (with-current-buffer buf
                     (insert "HTTP/1.1 200 OK\n\n{\"fields\":{}}"))
                   (funcall callback nil)
                   buf))))
      (with-temp-buffer
        (org-mode)
        (insert "* Feature A\n")
        (org-entry-put (point) "JIRA_KEY" "PROJ-1")
        (org-entry-put (point) "JIRA_TYPE" "New Feature")
        (insert "** Story A\n")
        (org-entry-put (point) "JIRA_KEY" "PROJ-2")
        (org-entry-put (point) "JIRA_TYPE" "Story")
        (org-entry-put (point) "PARENT" "PROJ-1")
        (org-jira--sync-to-jira)
        ;; Phase 1 should use 1 batch (all tickets together),
        ;; Phase 2 uses 1 batch for attachments+links = 2 total
        (should (= batch-call-count 2))))))
```

- [ ] **Step 2: Run tests**

```bash
make test
```

Expected: All tests pass.

- [ ] **Step 3: Commit**

```bash
git add org-jira-test-async.el
git commit -m "test: verify full-parallel when all features exist"
```

---

### Task 11: Final verification

**Files:**
- None modified

- [ ] **Step 1: Run full test suite**

```bash
make test
```

Expected: ALL tests pass — both existing regression tests and all new async/phase tests.

- [ ] **Step 2: Byte-compile to check for warnings**

```bash
make compile
```

Expected: No warnings. If there are warnings about free variables or unknown functions, fix them.

- [ ] **Step 3: Check file sizes**

```bash
wc -l org-jira-async.el org-jira-sync.el org-jira-test-async.el org-jira-core.el
```

Expected: All files under 750 lines.

- [ ] **Step 4: Commit any final fixes**

Only if Step 2 or 3 revealed issues. Otherwise no commit needed.

---

## Task Dependency Summary

```
Task 1 (baseline) → Task 2 (core var) → Task 3 (async request)
  → Task 4 (rate limiting) → Task 5 (batch) → Task 6 (progress)
  → Task 7 (attachment refactor) → Task 8 (phased sync)
  → Task 9 (consolidation test) → Task 10 (parallel grouping test)
  → Task 11 (final verification)
```

All tasks are sequential — each builds on the previous.

---

## Known Limitations / Future Work

**Phase 2 attachment operations are not fully async.** Phase 2 batches thunks
that internally call `org-jira--upload-attachment` (uses `url-retrieve-synchronously`)
and `org-jira--download-attachment` (uses `url-copy-file`). These are synchronous
within each thunk. The batch coordination fires all thunks, but since Emacs is
single-threaded, they block sequentially within the event loop.

The main parallelism win comes from Phase 1 (GET + PUT per ticket are truly
async via `url-retrieve`), plus the request consolidation (5 requests → 2-3).
Making attachment uploads/downloads fully async would require rewriting
`org-jira--upload-attachment` to use `url-retrieve` with a unibyte response
handler — a good follow-up but out of scope for this plan.

Similarly, link creation in Phase 2 uses the synchronous `org-jira--api-request`.
Converting to `org-jira--async-request` is a straightforward follow-up.
