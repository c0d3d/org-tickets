# Async Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the entire sync pipeline non-blocking by converting Phase 2 (attachments + links) from synchronous HTTP to async, using plz.el for file operations and existing `org-jira--async-request` for link creation.

**Architecture:** plz.el (curl backend, GNU ELPA) handles file uploads/downloads asynchronously. Link creation uses the existing `org-jira--async-request` + `org-jira--async-batch` infrastructure. Phase 2 thunks become truly non-blocking callbacks. Phase 1 and Phase 3 are unchanged.

**Tech Stack:** Emacs Lisp, plz.el (GNU ELPA), curl, ERT testing framework

**Spec:** `docs/superpowers/specs/2026-05-14-async-phase2-design.md`

---

### Task 1: Add plz.el Dependency with Load-Time Warning

**Files:**
- Modify: `org-jira-core.el:29-36` (require section)

- [ ] **Step 1: Write the failing test**

Create a new test file `org-jira-test-plz-dep.el`:

```elisp
;;; org-jira-test-plz-dep.el --- Tests for plz dependency handling  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)

(ert-deftest org-jira-test--plz-available-after-core-load ()
  "Loading org-jira-core should attempt to require plz."
  (should (featurep 'plz)))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test 2>&1 | grep plz-available`
Expected: FAIL — plz is not required yet in org-jira-core.el

- [ ] **Step 3: Add plz require with warning to org-jira-core.el**

In `org-jira-core.el`, after the existing `(require 'ox)` line (line 36), add:

```elisp
(unless (require 'plz nil t)
  (display-warning 'org-jira
    "org-jira requires the `plz' package (GNU ELPA). \
Install it with: M-x package-install RET plz RET"
    :error))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test 2>&1 | grep plz-available`
Expected: PASS (assuming plz is installed in your Emacs)

If plz is not installed, install it first: `emacs --batch --eval '(package-install (quote plz))'`

- [ ] **Step 5: Run full test suite**

Run: `make test`
Expected: All tests pass, no regressions.

- [ ] **Step 6: Commit**

```bash
git add org-jira-core.el org-jira-test-plz-dep.el
git commit -m "feat: add plz.el dependency with load-time warning"
```

---

### Task 2: Async Download Attachment (Single File)

**Files:**
- Modify: `org-jira-attachments.el`
- Test: `org-jira-test-attachments.el`

- [ ] **Step 1: Write the failing tests**

Add to `org-jira-test-attachments.el`:

```elisp
(ert-deftest org-jira-test--async-download-attachment-success ()
  "Async download calls plz GET and invokes callback with file path."
  (let ((callback-result nil)
        (plz-calls nil))
    (cl-letf (((symbol-function 'plz)
               (lambda (method url &rest args)
                 (push (list method url args) plz-calls)
                 ;; Simulate success: call :then callback
                 (let ((then-fn (plist-get args :then)))
                   (when then-fn (funcall then-fn nil))))))
      (org-jira--async-download-attachment
       "https://jira.test/attachment/123/file.png"
       "file.png"
       "/tmp/test-attach"
       1024
       (lambda (path err)
         (setq callback-result (list path err)))))
    (should (= (length plz-calls) 1))
    (should (eq (car (car plz-calls)) 'get))
    (should (car callback-result))
    (should-not (cadr callback-result))))

(ert-deftest org-jira-test--async-download-attachment-skips-matching-size ()
  "Async download skips file when local copy matches size."
  (let ((callback-result nil)
        (plz-calls nil)
        (temp-dir (make-temp-file "org-jira-test-" t)))
    (unwind-protect
        (progn
          ;; Create a local file with matching size (5 bytes)
          (let ((local-file (expand-file-name "file.txt" temp-dir)))
            (with-temp-file local-file (insert "hello"))
            (cl-letf (((symbol-function 'plz)
                       (lambda (_method _url &rest _args)
                         (push t plz-calls))))
              (org-jira--async-download-attachment
               "https://jira.test/attachment/123/file.txt"
               "file.txt"
               temp-dir
               5
               (lambda (path err)
                 (setq callback-result (list path err))))))
          (should (null plz-calls))
          (should (car callback-result))
          (should-not (cadr callback-result)))
      (delete-directory temp-dir t))))

(ert-deftest org-jira-test--async-download-attachment-error ()
  "Async download invokes callback with error on plz failure."
  (let ((callback-result nil))
    (cl-letf (((symbol-function 'plz)
               (lambda (_method _url &rest args)
                 (let ((else-fn (plist-get args :else)))
                   (when else-fn
                     (funcall else-fn (make-instance 'plz-error
                                        :message "Download failed")))))))
      (org-jira--async-download-attachment
       "https://jira.test/attachment/123/file.png"
       "file.png"
       "/tmp/test-attach"
       1024
       (lambda (path err)
         (setq callback-result (list path err)))))
    (should-not (car callback-result))
    (should (cadr callback-result))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test 2>&1 | grep async-download-attachment`
Expected: FAIL — `org-jira--async-download-attachment` is void

- [ ] **Step 3: Implement `org-jira--async-download-attachment`**

Add to `org-jira-attachments.el`, after the `(require 'mailcap)` line. Also add `(require 'plz)` at the top of the file:

```elisp
(defun org-jira--async-download-attachment (url filename dir size callback)
  "Asynchronously download attachment from URL to FILENAME in DIR.
SIZE is the expected file size from Jira metadata.  If a local file
exists with matching name and size, the download is skipped.
CALLBACK is (lambda (path err) ...) called on completion."
  (let ((local-path (expand-file-name filename dir)))
    (if (and (file-exists-p local-path)
             (= (file-attribute-size (file-attributes local-path)) size))
        (progn
          (when org-jira-debug
            (message "org-jira: Skipping download, local file matches: %s" filename))
          (funcall callback local-path nil))
      (when org-jira-debug
        (message "org-jira: Downloading attachment %s to %s" filename local-path))
      (make-directory dir t)
      (plz 'get url
        :headers (org-jira--async-build-headers)
        :as `(file ,local-path)
        :then (lambda (_) (funcall callback local-path nil))
        :else (lambda (err)
                (when org-jira-debug
                  (message "org-jira: Failed to download %s: %S" filename err))
                (funcall callback nil (format "Download failed: %s" err)))))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test 2>&1 | grep async-download-attachment`
Expected: All 3 tests PASS

- [ ] **Step 5: Run full test suite**

Run: `make test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add org-jira-attachments.el org-jira-test-attachments.el
git commit -m "feat: add async single-file attachment download via plz"
```

---

### Task 3: Async Upload Attachment (Single File)

**Files:**
- Modify: `org-jira-attachments.el`
- Test: `org-jira-test-attachments.el`

- [ ] **Step 1: Write the failing tests**

Add to `org-jira-test-attachments.el`:

```elisp
(ert-deftest org-jira-test--async-upload-attachment-success ()
  "Async upload calls plz POST with correct URL and multipart headers."
  (let ((plz-calls nil)
        (callback-result nil)
        (temp-file (make-temp-file "org-jira-test-upload")))
    (unwind-protect
        (progn
          (with-temp-file temp-file (insert "file content"))
          (let ((org-jira--jira-base-url "https://test.atlassian.net")
                (org-jira--api-user "user@test.com")
                (org-jira--api-token "token123"))
            (cl-letf (((symbol-function 'plz)
                       (lambda (method url &rest args)
                         (push (list method url args) plz-calls)
                         (let ((then-fn (plist-get args :then)))
                           (when then-fn (funcall then-fn '((status . "ok"))))))))
              (org-jira--async-upload-attachment
               "PROJ-123"
               temp-file
               (lambda (response err)
                 (setq callback-result (list response err))))))
          (should (= (length plz-calls) 1))
          (let ((call (car plz-calls)))
            (should (eq (nth 0 call) 'post))
            (should (string-match "PROJ-123/attachments" (nth 1 call))))
          (should (car callback-result))
          (should-not (cadr callback-result)))
      (delete-file temp-file))))

(ert-deftest org-jira-test--async-upload-attachment-error ()
  "Async upload invokes callback with error on plz failure."
  (let ((callback-result nil)
        (temp-file (make-temp-file "org-jira-test-upload")))
    (unwind-protect
        (progn
          (with-temp-file temp-file (insert "content"))
          (let ((org-jira--jira-base-url "https://test.atlassian.net")
                (org-jira--api-user "user@test.com")
                (org-jira--api-token "token123"))
            (cl-letf (((symbol-function 'plz)
                       (lambda (_method _url &rest args)
                         (let ((else-fn (plist-get args :else)))
                           (when else-fn
                             (funcall else-fn (make-instance 'plz-error
                                                :message "Upload failed")))))))
              (org-jira--async-upload-attachment
               "PROJ-123"
               temp-file
               (lambda (response err)
                 (setq callback-result (list response err))))))
          (should-not (car callback-result))
          (should (cadr callback-result)))
      (delete-file temp-file))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test 2>&1 | grep async-upload-attachment`
Expected: FAIL — `org-jira--async-upload-attachment` is void

- [ ] **Step 3: Implement `org-jira--async-upload-attachment`**

Add to `org-jira-attachments.el`:

```elisp
(defun org-jira--async-upload-attachment (ticket-key file-path callback)
  "Asynchronously upload FILE-PATH as an attachment to TICKET-KEY.
Uses plz with curl for multipart form upload.
CALLBACK is (lambda (response err) ...) called on completion."
  (let* ((filename (file-name-nondirectory file-path))
         (url (concat org-jira--jira-base-url
                      "/rest/api/3/issue/" ticket-key "/attachments"))
         (auth-header (concat "Basic "
                              (base64-encode-string
                               (concat org-jira--api-user ":" org-jira--api-token) t))))
    (when org-jira-debug
      (message "org-jira: Uploading attachment %s to %s" filename ticket-key))
    (plz 'post url
      :headers `(("Authorization" . ,auth-header)
                 ("X-Atlassian-Token" . "no-check"))
      :body `(file ,file-path)
      :as 'string
      :then (lambda (response)
              (funcall callback response nil))
      :else (lambda (err)
              (when org-jira-debug
                (message "org-jira: Failed to upload %s: %S" filename err))
              (funcall callback nil (format "Upload failed: %s" err))))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test 2>&1 | grep async-upload-attachment`
Expected: All PASS

- [ ] **Step 5: Run full test suite**

Run: `make test`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add org-jira-attachments.el org-jira-test-attachments.el
git commit -m "feat: add async single-file attachment upload via plz"
```

---

### Task 4: Async Batch Download and Upload Attachments

**Files:**
- Modify: `org-jira-attachments.el`
- Test: `org-jira-test-attachments.el`

- [ ] **Step 1: Write the failing tests for batch download**

Add to `org-jira-test-attachments.el`:

```elisp
(ert-deftest org-jira-test--async-download-attachments-filters-by-size ()
  "Batch download skips files that exist locally with matching size."
  (let ((downloaded nil)
        (callback-result nil)
        (temp-dir (make-temp-file "org-jira-test-" t)))
    (unwind-protect
        (progn
          ;; Create a local file matching one attachment
          (let ((existing (expand-file-name "exists.txt" temp-dir)))
            (with-temp-file existing (insert "12345")))  ; 5 bytes
          (cl-letf (((symbol-function 'org-jira--async-download-attachment)
                     (lambda (url filename dir size callback)
                       (push filename downloaded)
                       (funcall callback (expand-file-name filename dir) nil)))
                    ((symbol-function 'org-jira--find-ticket-by-key)
                     (lambda (_key) (point)))
                    ((symbol-function 'org-jira--ensure-org-attach-id)
                     (lambda (_key) "fake-id"))
                    ((symbol-function 'org-jira--get-ticket-attach-dir)
                     (lambda (_create) temp-dir)))
            (with-temp-buffer
              (org-mode)
              (insert "* Ticket\n")
              (org-entry-put (point) "JIRA_KEY" "PROJ-1")
              (org-jira--async-download-attachments
               "PROJ-1"
               (list (list (cons "filename" "exists.txt")
                           (cons "size" 5)
                           (cons "content" "https://jira.test/exists.txt"))
                     (list (cons "filename" "new.txt")
                           (cons "size" 100)
                           (cons "content" "https://jira.test/new.txt")))
               (lambda (results err)
                 (setq callback-result (list results err))))))
          ;; Only "new.txt" should be downloaded
          (should (equal downloaded '("new.txt")))
          (should callback-result))
      (delete-directory temp-dir t))))

(ert-deftest org-jira-test--async-download-attachments-empty-list ()
  "Batch download with empty attachment list calls callback immediately."
  (let ((callback-result nil))
    (org-jira--async-download-attachments
     "PROJ-1" nil
     (lambda (results err)
       (setq callback-result (list results err))))
    (should callback-result)))
```

- [ ] **Step 2: Write the failing tests for batch upload**

Add to `org-jira-test-attachments.el`:

```elisp
(ert-deftest org-jira-test--async-upload-attachments-dedup ()
  "Batch upload skips files that already exist in Jira by filename."
  (let ((uploaded nil)
        (callback-result nil)
        (temp-dir (make-temp-file "org-jira-test-" t)))
    (unwind-protect
        (progn
          ;; Create two local files
          (with-temp-file (expand-file-name "existing.txt" temp-dir)
            (insert "already in jira"))
          (with-temp-file (expand-file-name "new-file.txt" temp-dir)
            (insert "not in jira"))
          (cl-letf (((symbol-function 'org-jira--async-upload-attachment)
                     (lambda (ticket-key file-path callback)
                       (push (file-name-nondirectory file-path) uploaded)
                       (funcall callback t nil)))
                    ((symbol-function 'org-jira--find-ticket-by-key)
                     (lambda (_key) (point)))
                    ((symbol-function 'org-jira--get-ticket-attach-dir)
                     (lambda (_create) temp-dir)))
            (with-temp-buffer
              (org-mode)
              (insert "* Ticket\n")
              (org-entry-put (point) "JIRA_KEY" "PROJ-1")
              (org-jira--async-upload-attachments
               "PROJ-1"
               ;; Jira already has "existing.txt"
               (list (list (cons "filename" "existing.txt")))
               (lambda (results err)
                 (setq callback-result (list results err))))))
          ;; Only "new-file.txt" should be uploaded
          (should (equal uploaded '("new-file.txt")))
          (should callback-result))
      (delete-directory temp-dir t))))

(ert-deftest org-jira-test--async-upload-attachments-no-dir ()
  "Batch upload calls callback immediately when no attach dir exists."
  (let ((callback-result nil))
    (cl-letf (((symbol-function 'org-jira--find-ticket-by-key)
               (lambda (_key) (point)))
              ((symbol-function 'org-jira--get-ticket-attach-dir)
               (lambda (_create) nil)))
      (with-temp-buffer
        (org-mode)
        (insert "* Ticket\n")
        (org-entry-put (point) "JIRA_KEY" "PROJ-1")
        (org-jira--async-upload-attachments
         "PROJ-1" nil
         (lambda (results err)
           (setq callback-result (list results err))))))
    (should callback-result)))
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `make test 2>&1 | grep "async-download-attachments\|async-upload-attachments"`
Expected: FAIL — functions are void

- [ ] **Step 4: Implement `org-jira--async-download-attachments`**

Add to `org-jira-attachments.el`:

```elisp
(defun org-jira--async-download-attachments (ticket-key attachments callback)
  "Asynchronously download ATTACHMENTS from Jira for TICKET-KEY.
ATTACHMENTS is a list of attachment metadata alists from Jira.
Skips files that exist locally with matching filename and size.
CALLBACK is (lambda (results err) ...) called when all downloads finish."
  (cl-block org-jira--async-download-attachments
    (unless attachments
      (funcall callback nil nil)
      (cl-return-from org-jira--async-download-attachments))
    (save-excursion
      (let ((pos (org-jira--find-ticket-by-key ticket-key)))
        (unless pos
          (funcall callback nil nil)
          (cl-return-from org-jira--async-download-attachments))
        (goto-char pos)
        (org-jira--ensure-org-attach-id ticket-key)
        (let* ((attach-dir (org-jira--get-ticket-attach-dir t))
               (to-download
                (cl-remove-if
                 (lambda (att)
                   (let* ((filename (org-jira--attachment-filename att))
                          (size (org-jira--alist-get "size" att))
                          (local-path (expand-file-name filename attach-dir)))
                     (and (file-exists-p local-path)
                          size
                          (= (file-attribute-size (file-attributes local-path))
                             size))))
                 attachments))
               (total (length to-download))
               (counter (list 0))
               (results nil))
          (if (= total 0)
              (funcall callback nil nil)
            (dolist (att to-download)
              (let ((filename (org-jira--attachment-filename att))
                    (url (org-jira--attachment-content-url att))
                    (size (or (org-jira--alist-get "size" att) 0)))
                (org-jira--async-download-attachment
                 url filename attach-dir size
                 (lambda (path err)
                   (push (cons path err) results)
                   (cl-incf (car counter))
                   (when (= (car counter) total)
                     (funcall callback results nil))))))))))))
```

- [ ] **Step 5: Implement `org-jira--async-upload-attachments`**

Add to `org-jira-attachments.el`:

```elisp
(defun org-jira--async-upload-attachments (ticket-key jira-attachments callback)
  "Asynchronously upload local attachments for TICKET-KEY to Jira.
JIRA-ATTACHMENTS is the attachment list from Jira (used for dedup by filename).
Does NOT re-fetch attachment metadata from Jira.
CALLBACK is (lambda (results err) ...) called when all uploads finish."
  (cl-block org-jira--async-upload-attachments
    (save-excursion
      (let ((pos (org-jira--find-ticket-by-key ticket-key)))
        (unless pos
          (funcall callback nil nil)
          (cl-return-from org-jira--async-upload-attachments))
        (goto-char pos)
        (let ((dir (org-jira--get-ticket-attach-dir nil)))
          (unless dir
            (funcall callback nil nil)
            (cl-return-from org-jira--async-upload-attachments))
          (let* ((local-files (org-attach-file-list dir))
                 (jira-filenames (mapcar #'org-jira--attachment-filename
                                         (or jira-attachments nil)))
                 (to-upload (cl-remove-if
                             (lambda (f) (member f jira-filenames))
                             local-files))
                 (total (length to-upload))
                 (counter (list 0))
                 (results nil))
            (if (= total 0)
                (funcall callback nil nil)
              (dolist (file to-upload)
                (let ((file-path (expand-file-name file dir)))
                  (org-jira--async-upload-attachment
                   ticket-key file-path
                   (lambda (response err)
                     (push (cons response err) results)
                     (cl-incf (car counter))
                     (when (= (car counter) total)
                       (funcall callback results nil)))))))))))))
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `make test 2>&1 | grep "async-download-attachments\|async-upload-attachments"`
Expected: All PASS

- [ ] **Step 7: Run full test suite**

Run: `make test`
Expected: All tests pass.

- [ ] **Step 8: Commit**

```bash
git add org-jira-attachments.el org-jira-test-attachments.el
git commit -m "feat: add async batch download/upload for attachments"
```

---

### Task 5: Async Link Creation

**Files:**
- Modify: `org-jira-api.el`
- Modify: `org-jira-sync.el`
- Test: `org-jira-test-sync-flow.el`

- [ ] **Step 1: Write the failing tests**

Add to `org-jira-test-sync-flow.el`:

```elisp
(ert-deftest org-jira-test--async-create-link-fires-post ()
  "Async create link should POST to issueLink endpoint."
  (let ((request-calls nil))
    (cl-letf (((symbol-function 'org-jira--async-request)
               (lambda (method endpoint callback &optional data)
                 (push (list method endpoint data) request-calls)
                 (funcall callback nil nil))))
      (let ((result nil))
        (org-jira--async-create-link "PROJ-1" "PROJ-2" "Blocks"
                                     (lambda (response err)
                                       (setq result (list response err))))
        (should (= (length request-calls) 1))
        (let ((call (car request-calls)))
          (should (string= (nth 0 call) "POST"))
          (should (string= (nth 1 call) "/rest/api/3/issueLink"))
          (let ((data (nth 2 call)))
            (should (equal (cdr (assoc "inwardIssue" data))
                           (list (cons "key" "PROJ-1"))))
            (should (equal (cdr (assoc "outwardIssue" data))
                           (list (cons "key" "PROJ-2"))))))))))

(ert-deftest org-jira-test--async-sync-ticket-links-story ()
  "Async sync ticket links should create parent + blocks + blocked-by links."
  (let ((link-calls nil))
    (cl-letf (((symbol-function 'org-jira--async-create-link)
               (lambda (from to type callback)
                 (push (list from to type) link-calls)
                 (funcall callback nil nil))))
      (with-temp-buffer
        (org-mode)
        (insert "* Feature\n")
        (org-entry-put (point) "JIRA_KEY" "PROJ-100")
        (org-entry-put (point) "JIRA_TYPE" "Feature")
        (insert "** Story\n")
        (org-entry-put (point) "JIRA_KEY" "PROJ-200")
        (org-entry-put (point) "JIRA_TYPE" "Story")
        (org-entry-put (point) "PARENT" "PROJ-100")
        (org-entry-put (point) "BLOCKS" "PROJ-300")
        (let* ((doc (org-jira--parse-document))
               (story (car (org-jira--doc-stories doc)))
               (result nil))
          (org-jira--async-sync-ticket-links
           story (current-buffer)
           (lambda () (setq result t)))
          (should result)
          ;; Should have: parent link + blocks link = 2 calls
          (should (= (length link-calls) 2))
          ;; Parent link: story blocks parent
          (should (member (list "PROJ-200" "PROJ-100" "Blocks") link-calls))
          ;; Explicit blocks link
          (should (member (list "PROJ-200" "PROJ-300" "Blocks") link-calls)))))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test 2>&1 | grep "async-create-link\|async-sync-ticket-links"`
Expected: FAIL — functions are void

- [ ] **Step 3: Implement `org-jira--async-create-link`**

Add to `org-jira-api.el`, after the existing `org-jira--create-link` function:

```elisp
(defun org-jira--async-create-link (from-key to-key link-type callback)
  "Asynchronously create a link between two tickets.
FROM-KEY blocks TO-KEY via LINK-TYPE (typically \"Blocks\").
CALLBACK is (lambda (response err) ...) called on completion.
Goes through the rate-limit state machine via `org-jira--async-request'."
  (org-jira--async-request
   "POST" "/rest/api/3/issueLink"
   callback
   (list (cons 'type (list (cons "name" link-type)))
         (cons "inwardIssue" (list (cons "key" from-key)))
         (cons "outwardIssue" (list (cons "key" to-key))))))
```

- [ ] **Step 4: Implement `org-jira--async-sync-ticket-links`**

Add to `org-jira-sync.el`, after the existing `org-jira--sync-ticket-links` function:

```elisp
(defun org-jira--async-sync-ticket-links (ticket org-buffer callback)
  "Asynchronously sync block relationships for TICKET.
Collects all needed links (parent, blocks, blocked-by) and fires them
concurrently via `org-jira--async-batch'.
ORG-BUFFER is the source buffer.  CALLBACK is called when all complete."
  (cl-block org-jira--async-sync-ticket-links
    (let ((key (org-jira--ticket-key ticket))
          (type (org-jira--ticket-type ticket))
          (thunks nil))
      (unless (and key (stringp key) (> (length key) 0))
        (funcall callback)
        (cl-return-from org-jira--async-sync-ticket-links))
      ;; Implicit blocks link to parent (Stories only)
      (when (string= type "Story")
        (let* ((explicit-parent (org-jira--ticket-parent ticket))
               (parent-key (or explicit-parent
                               (org-jira--safe-with-buffer
                                org-buffer
                                (lambda ()
                                  (goto-char (org-element-property
                                              :begin (org-jira--ticket-org-node ticket)))
                                  (org-jira--find-parent-ticket-key))))))
          (when (and parent-key (> (length parent-key) 0)
                     (not (string= key parent-key)))
            (push (lambda (done)
                    (org-jira--async-create-link key parent-key "Blocks"
                                                 (lambda (_r _e) (funcall done nil nil))))
                  thunks))))
      ;; Explicit BLOCKS
      (dolist (blocked (org-jira--ticket-blocks ticket))
        (unless (string= key blocked)
          (push (lambda (done)
                  (org-jira--async-create-link key blocked "Blocks"
                                               (lambda (_r _e) (funcall done nil nil))))
                thunks)))
      ;; BLOCKED-BY (reverse direction)
      (dolist (blocker (org-jira--ticket-blocked-by ticket))
        (unless (string= key blocker)
          (push (lambda (done)
                  (org-jira--async-create-link blocker key "Blocks"
                                               (lambda (_r _e) (funcall done nil nil))))
                thunks)))
      (if thunks
          (org-jira--async-batch (nreverse thunks)
                                 (lambda (_results) (funcall callback)))
        (funcall callback)))))
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test 2>&1 | grep "async-create-link\|async-sync-ticket-links"`
Expected: All PASS

- [ ] **Step 6: Run full test suite**

Run: `make test`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add org-jira-api.el org-jira-sync.el org-jira-test-sync-flow.el
git commit -m "feat: add async link creation and ticket link sync"
```

---

### Task 6: Rewire Phase 2 Thunks to Use Async Functions

**Files:**
- Modify: `org-jira-sync-phases.el:260-321`
- Test: `org-jira-test-sync-flow.el`

- [ ] **Step 1: Write the failing test**

Add to `org-jira-test-sync-flow.el`:

```elisp
(ert-deftest org-jira-test--phase2-thunks-use-async ()
  "Phase 2 attachment thunk should call async download then upload."
  (let ((download-calls nil)
        (upload-calls nil)
        (link-calls nil))
    (cl-letf (((symbol-function 'org-jira--async-download-attachments)
               (lambda (key attachments callback)
                 (push key download-calls)
                 (funcall callback nil nil)))
              ((symbol-function 'org-jira--async-upload-attachments)
               (lambda (key jira-attachments callback)
                 (push key upload-calls)
                 (funcall callback nil nil)))
              ((symbol-function 'org-jira--async-sync-ticket-links)
               (lambda (ticket org-buffer callback)
                 (push (org-jira--ticket-key ticket) link-calls)
                 (funcall callback)))
              ((symbol-function 'org-jira--safe-with-buffer)
               (lambda (buffer body-fn) (funcall body-fn))))
      ;; Build a fake attachment thunk
      (let* ((result-plist (list :key "PROJ-1" :attachments '(("a")) :is-new nil))
             (thunk (org-jira--make-attachment-thunk
                     "PROJ-1" '(("a")) (current-buffer)))
             (done-result nil))
        (funcall thunk (lambda (r e) (setq done-result t)))
        (should done-result)
        (should (equal download-calls '("PROJ-1")))
        (should (equal upload-calls '("PROJ-1")))))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test 2>&1 | grep phase2-thunks-use-async`
Expected: FAIL — `org-jira--make-attachment-thunk` has wrong signature or calls sync functions

- [ ] **Step 3: Rewrite `org-jira--make-attachment-thunk`**

In `org-jira-sync-phases.el`, replace the existing `org-jira--make-attachment-thunk` function (around line 262):

```elisp
(defun org-jira--make-attachment-thunk (key attachments org-buffer)
  "Create a thunk that asynchronously syncs attachments for KEY.
ATTACHMENTS is the attachment list from Phase 1.  ORG-BUFFER is the source buffer."
  (lambda (done)
    (org-jira--safe-with-buffer
     org-buffer
     (lambda ()
       (org-jira--async-download-attachments
        key attachments
        (lambda (_dl-results _dl-err)
          (org-jira--safe-with-buffer
           org-buffer
           (lambda ()
             (org-jira--async-upload-attachments
              key attachments
              (lambda (_ul-results _ul-err)
                (funcall done nil nil)))))))))))
```

- [ ] **Step 4: Rewrite `org-jira--make-link-thunk`**

In `org-jira-sync-phases.el`, replace the existing `org-jira--make-link-thunk` function:

```elisp
(defun org-jira--make-link-thunk (ticket org-buffer)
  "Create a thunk that asynchronously syncs issue links for TICKET.
ORG-BUFFER is the source buffer."
  (lambda (done)
    (org-jira--async-sync-ticket-links
     ticket org-buffer
     (lambda () (funcall done nil nil)))))
```

- [ ] **Step 5: Update `org-jira--build-phase-2-thunks`**

In `org-jira-sync-phases.el`, update `org-jira--build-phase-2-thunks` to pass attachments to the attachment thunk:

```elisp
(defun org-jira--build-phase-2-thunks (doc phase-1-results org-buffer)
  "Build thunks for phase 2 from DOC, PHASE-1-RESULTS, and ORG-BUFFER."
  (let ((thunks nil))
    ;; Attachment thunks for tickets with keys
    (dolist (result phase-1-results)
      (let ((key (plist-get result :key))
            (attachments (plist-get result :attachments)))
        (when (and key (> (length key) 0))
          (push (org-jira--make-attachment-thunk key attachments org-buffer)
                thunks))))
    ;; Link thunks for all tickets
    (dolist (ticket (org-jira--doc-tickets doc))
      (push (org-jira--make-link-thunk ticket org-buffer) thunks))
    (nreverse thunks)))
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `make test 2>&1 | grep phase2-thunks-use-async`
Expected: PASS

- [ ] **Step 7: Run full test suite**

Run: `make test`
Expected: All tests pass. Some existing sync-flow tests may need mock updates — fix any that reference the old `org-jira--download-attachments` / `org-jira--upload-attachments` / `org-jira--sync-ticket-links` stubs.

- [ ] **Step 8: Commit**

```bash
git add org-jira-sync-phases.el org-jira-test-sync-flow.el
git commit -m "feat: rewire Phase 2 thunks to use async attachments and links"
```

---

### Task 7: Update `org-jira--sync-attachments` and `org-jira--add-block-link`

Non-pipeline callers also need to use async versions.

**Files:**
- Modify: `org-jira-attachments.el`
- Modify: `org-jira-sync.el`
- Test: `org-jira-test-attachments.el`

- [ ] **Step 1: Write the failing tests**

Add to `org-jira-test-attachments.el`:

```elisp
(ert-deftest org-jira-test--sync-attachments-uses-async ()
  "org-jira--sync-attachments should use async download/upload."
  (let ((download-calls nil)
        (upload-calls nil))
    (cl-letf (((symbol-function 'org-jira--get-attachments)
               (lambda (_key) (list (list (cons "filename" "f.txt")))))
              ((symbol-function 'org-jira--async-download-attachments)
               (lambda (key attachments callback)
                 (push key download-calls)
                 (funcall callback nil nil)))
              ((symbol-function 'org-jira--async-upload-attachments)
               (lambda (key jira-attachments callback)
                 (push key upload-calls)
                 (funcall callback nil nil))))
      (let ((ticket (org-jira--ticket-create :key "PROJ-1" :type "Story"
                                              :summary "Test")))
        (org-jira--sync-attachments ticket))
      (should (equal download-calls '("PROJ-1")))
      (should (equal upload-calls '("PROJ-1"))))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test 2>&1 | grep sync-attachments-uses-async`
Expected: FAIL — `org-jira--sync-attachments` still calls sync functions

- [ ] **Step 3: Rewrite `org-jira--sync-attachments`**

In `org-jira-attachments.el`, replace the existing `org-jira--sync-attachments`:

```elisp
(defun org-jira--sync-attachments (ticket)
  "Sync attachments for TICKET between Jira and org-attach.
Fetches attachment metadata, then downloads new and uploads new asynchronously."
  (let ((key (org-jira--ticket-key ticket)))
    (unless (and key (stringp key) (> (length key) 0))
      (when org-jira-debug
        (message "org-jira: Skipping attachment sync for ticket without a valid key"))
      (setq key nil))
    (when key
      (let ((jira-attachments (org-jira--get-attachments key)))
        (org-jira--async-download-attachments
         key jira-attachments
         (lambda (_dl-results _dl-err)
           (org-jira--async-upload-attachments
            key jira-attachments
            (lambda (_ul-results _ul-err)
              (when org-jira-debug
                (message "org-jira: Attachment sync complete for %s" key))))))))))
```

- [ ] **Step 4: Rewrite `org-jira--add-block-link`**

In `org-jira-sync.el`, replace the existing `org-jira--add-block-link`:

```elisp
(defun org-jira--add-block-link (from-key to-key)
  "Add a \"blocks\" link from FROM-KEY to TO-KEY.
This also adds the reverse \"blocked-by\" link automatically."
  (interactive "sBlocking ticket key: \nsBlocked ticket key: ")
  (org-jira--async-create-link from-key to-key "Blocks"
                               (lambda (_response err)
                                 (if err
                                     (message "org-jira: Failed to create link: %s" err)
                                   (message "org-jira: Created blocks link %s -> %s"
                                            from-key to-key))))
  ;; Update org properties immediately (local state)
  (org-jira--add-block-prop from-key to-key)
  (org-jira--add-blocked-by-prop to-key from-key))
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test 2>&1 | grep "sync-attachments-uses-async"`
Expected: PASS

- [ ] **Step 6: Run full test suite**

Run: `make test`
Expected: All tests pass.

- [ ] **Step 7: Commit**

```bash
git add org-jira-attachments.el org-jira-sync.el org-jira-test-attachments.el
git commit -m "feat: convert sync-attachments and add-block-link to async"
```

---

### Task 8: Remove Dead Synchronous Functions

**Files:**
- Modify: `org-jira-attachments.el`
- Modify: `org-jira-api.el`
- Modify: `org-jira-sync.el`
- Modify: `org-jira-sync-phases.el`

- [ ] **Step 1: Verify no remaining callers of sync functions**

Run these searches to confirm no callers remain:

```bash
grep -n 'org-jira--download-attachment[^s]' org-jira-*.el
grep -n 'org-jira--upload-attachment[^s]' org-jira-*.el
grep -n 'org-jira--sync-ticket-links[^-]' org-jira-*.el
```

Each should return only the function definition itself (or nothing if already deleted). If any callers remain, update them first.

- [ ] **Step 2: Remove `org-jira--download-attachment` (sync)**

In `org-jira-attachments.el`, delete the function `org-jira--download-attachment` (the one using `url-copy-file`).

- [ ] **Step 3: Remove `org-jira--upload-attachment` (sync)**

In `org-jira-attachments.el`, delete the function `org-jira--upload-attachment` (the one using `url-retrieve-synchronously`).

- [ ] **Step 4: Remove `org-jira--upload-attachments` (sync)**

In `org-jira-attachments.el`, delete the old `org-jira--upload-attachments` that called `org-jira--get-attachments` internally — it's been replaced by `org-jira--async-upload-attachments`.

- [ ] **Step 5: Remove `org-jira--download-attachments` (sync)**

In `org-jira-attachments.el`, delete the old `org-jira--download-attachments` — replaced by `org-jira--async-download-attachments`.

- [ ] **Step 6: Remove `org-jira--sync-ticket-links` (sync)**

In `org-jira-sync.el`, delete the `org-jira--sync-ticket-links` function — replaced by `org-jira--async-sync-ticket-links`.

- [ ] **Step 7: Remove `org-jira--create-link` (sync)**

In `org-jira-api.el`, delete `org-jira--create-link` — replaced by `org-jira--async-create-link`.

- [ ] **Step 8: Remove stale `declare-function` and mock stubs**

In `org-jira-sync-phases.el`, remove the `declare-function` for `org-jira--sync-ticket-links` if present.

In `org-jira-test-sync-flow.el`, update `org-jira-test--with-sync-mocks` to remove stubs for deleted functions (`org-jira--upload-attachments`, `org-jira--download-attachments`, `org-jira--sync-ticket-links`) and add stubs for new async functions if needed.

- [ ] **Step 9: Run full test suite**

Run: `make test`
Expected: All tests pass.

- [ ] **Step 10: Run byte-compile check**

Run: `make compile`
Expected: No warnings about undefined functions.

- [ ] **Step 11: Commit**

```bash
git add org-jira-attachments.el org-jira-api.el org-jira-sync.el org-jira-sync-phases.el org-jira-test-sync-flow.el
git commit -m "refactor: remove synchronous attachment/link functions"
```

---

### Task 9: Update `org-jira--create-story` to Use Async Link

**Files:**
- Modify: `org-jira-sync.el:36-66`

The `org-jira--create-story` function calls `org-jira--add-block-link` which is now async. Since `org-jira--create-story` is interactive, the link creation will fire asynchronously — this is fine because org properties are updated synchronously in `org-jira--add-block-link`.

- [ ] **Step 1: Verify `org-jira--create-story` works with async `org-jira--add-block-link`**

Read `org-jira-sync.el` lines 36-66. The call at line 65 is:
```elisp
(org-jira--add-block-link new-key blocked)
```

This already works — `org-jira--add-block-link` (rewritten in Task 7) fires the API call async and updates org properties synchronously. No code change needed.

- [ ] **Step 2: Run full test suite to confirm**

Run: `make test`
Expected: All tests pass.

- [ ] **Step 3: Run byte-compile**

Run: `make compile`
Expected: No warnings.

---

### Task 10: Final Integration Test and Cleanup

**Files:**
- Test: `org-jira-test-sync-flow.el`

- [ ] **Step 1: Write end-to-end Phase 2 integration test**

Add to `org-jira-test-sync-flow.el`:

```elisp
(ert-deftest org-jira-test--full-pipeline-phase2-async ()
  "Full pipeline: Phase 1 -> Phase 2 (async) -> Phase 3 completes without sync calls."
  (let ((sync-api-calls nil)
        (async-calls nil))
    (org-jira-test--with-sync-mocks
        (lambda (method endpoint callback &optional data)
          (push (list method endpoint) async-calls)
          (cond
           ((string= method "GET")
            (funcall callback (org-jira-test--make-get-response "Sprint-1" "2026-06-01") nil))
           ((string= method "PUT")
            (funcall callback nil nil))
           ((string= method "POST")
            (if (string-match "issueLink" endpoint)
                (funcall callback nil nil)
              (funcall callback (list (cons "key" "PROJ-NEW")) nil)))))
      ;; Ensure no sync API calls happen
      (cl-letf (((symbol-function 'org-jira--api-request)
                 (lambda (method endpoint &optional data)
                   (push (list method endpoint) sync-api-calls)
                   nil))
                ((symbol-function 'org-jira--async-download-attachments)
                 (lambda (_key _atts callback) (funcall callback nil nil)))
                ((symbol-function 'org-jira--async-upload-attachments)
                 (lambda (_key _atts callback) (funcall callback nil nil)))
                ((symbol-function 'org-jira--async-sync-ticket-links)
                 (lambda (_ticket _buf callback) (funcall callback))))
        (with-temp-buffer
          (org-mode)
          (org-jira-test--insert-feature "Feature" "PROJ-100")
          (org-jira-test--insert-story "Story" "PROJ-200" "PROJ-100")
          (org-jira--sync-to-jira)
          ;; No synchronous API calls should have been made during Phase 2
          (should (null sync-api-calls)))))))
```

- [ ] **Step 2: Run the integration test**

Run: `make test 2>&1 | grep full-pipeline-phase2-async`
Expected: PASS

- [ ] **Step 3: Run full test suite**

Run: `make test`
Expected: All tests pass.

- [ ] **Step 4: Run byte-compile**

Run: `make compile`
Expected: No warnings.

- [ ] **Step 5: Check file sizes**

Run: `wc -l org-jira-attachments.el org-jira-sync-phases.el org-jira-sync.el org-jira-api.el`
Expected: All under 750 lines. If any file exceeds the limit, split it.

- [ ] **Step 6: Commit**

```bash
git add org-jira-test-sync-flow.el
git commit -m "tests: add end-to-end integration test for async Phase 2 pipeline"
```
