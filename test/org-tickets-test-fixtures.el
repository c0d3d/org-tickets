;;; org-tickets-test-fixtures.el --- Shared test fixtures for org-tickets  -*- lexical-binding: t; -*-

;;; Commentary:

;; Shared helpers for building realistic test fixtures.
;;
;; API-response fixtures MUST be built through `org-tickets-test--json' from
;; literal JSON, never as hand-written alists.  json.el produces SYMBOL
;; keys and `:json-false' for false; hand-built string-key alists have a
;; different shape and have hidden real production bugs (string-key
;; `assoc' always returning nil; `:json-false' being truthy).
;;
;; Also holds the shared ADF/ticket-text helpers (`--adf-*', `--pull',
;; `--roundtrip', `--ticket-text') and the attachment environment macro.
;;
;; Also holds the end-to-end sync harness (`org-tickets-test--with-sync-mocks'
;; and the heading builders) shared by every test that drives
;; `org-tickets--sync-to-jira' with a stubbed HTTP layer.

;;; Code:

(require 'ert)
(require 'seq)
(require 'json)
(require 'org)
(require 'org-tickets)

;;;; Function stubbing

(defmacro org-tickets-test--with-stubs (stubs &rest body)
  "Evaluate BODY with function definitions temporarily replaced.

STUBS is a list of (SYMBOL FUNCTION) forms.  Each SYMBOL's function
cell is set to FUNCTION for the dynamic extent of BODY and restored
afterwards, including on a non-local exit.  Symbols that were unbound
beforehand are left unbound again.

All FUNCTION forms are evaluated before any function cell is replaced,
so a stub expression never sees a partially-stubbed world."
  (declare (indent 1) (debug ((&rest (symbolp form)) body)))
  (let ((new-vars (mapcar (lambda (_) (gensym "new-")) stubs))
        (old-vars (mapcar (lambda (_) (gensym "old-")) stubs))
        (names (mapcar #'car stubs)))
    `(let ,(seq-mapn (lambda (var stub) `(,var ,(cadr stub))) new-vars stubs)
       (let ,(seq-mapn (lambda (var name)
                         `(,var (and (fboundp ',name) (symbol-function ',name))))
                       old-vars names)
         (unwind-protect
             (progn
               ,@(seq-mapn (lambda (name var) `(fset ',name ,var)) names new-vars)
               ,@body)
           ,@(seq-mapn (lambda (name var)
                         `(if ,var
                              (fset ',name ,var)
                            (fmakunbound ',name)))
                       names old-vars))))))

(defun org-tickets-test--json (json-string)
  "Parse JSON-STRING exactly as `org-tickets--api-request' parses responses.
Returns alists with symbol keys, lists for arrays, and `:json-false'
for JSON false."
  (let ((json-object-type 'alist)
        (json-array-type 'list))
    (json-read-from-string json-string)))

(ert-deftest org-tickets-test--json-fixture-shape ()
  "The fixture helper reproduces production JSON parsing exactly."
  (let ((parsed (org-tickets-test--json
                 "{\"fields\": {\"isLast\": false, \"labels\": [\"a\"]}}")))
    ;; Symbol keys, not strings.
    (should (equal (mapcar #'car parsed) '(fields)))
    (should-not (assoc "fields" parsed))
    ;; false is :json-false (truthy!), arrays are lists.
    (let ((fields (cdr (assq 'fields parsed))))
      (should (eq (cdr (assq 'isLast fields)) :json-false))
      (should (equal (cdr (assq 'labels fields)) '("a"))))))

;;;; End-to-end sync harness

(defmacro org-tickets-test--with-sync-mocks (request-handler &rest body)
  "Execute BODY with sync infrastructure mocked.
REQUEST-HANDLER is a lambda (method endpoint callback &optional data)
called instead of `org-tickets--async-request'.
All side-effectful helpers (attachments, links, config) are stubbed out."
  (declare (indent 1))
  `(org-tickets-test--with-stubs ((org-tickets--async-request ,request-handler)
                               (org-tickets--get-ticket
                                (lambda (key)
                                  (let ((response nil))
                                    (org-tickets--async-request
                                     "GET" (concat "/rest/api/3/issue/" key)
                                     (lambda (r _err) (setq response r)))
                                    response)))
                               (org-tickets--resolve-config #'ignore)
                               (org-tickets--ensure-issue-types #'ignore)
                               (org-tickets--clear-sprint-cache #'ignore)
                               (org-tickets--async-upload-attachments
                                (lambda (_key _atts callback) (funcall callback nil nil)))
                               (org-tickets--async-download-attachments
                                (lambda (_key _atts callback) (funcall callback nil nil)))
                               (org-tickets--async-sync-ticket-links
                                (lambda (_ticket callback) (funcall callback)))
                               (org-tickets--build-adf-description
                                (lambda (_desc _atts) nil))
                               (force-mode-line-update #'ignore)
                               (run-at-time #'ignore))
     (let ((org-tickets-base-url "https://test.atlassian.net")
           (org-tickets-project-key "PROJ")
           (org-tickets-project-id "12345")
           (org-tickets--issue-type-ids
            (list (cons "Feature" "10000")
                  (cons "New Feature" "10000")
                  (cons "Story" "10001"))))
       ,@body)))

(defun org-tickets-test--make-get-response (&optional sprint due-date)
  "Build a fake GET /issue response plist.
SPRINT is an optional sprint name string.
DUE-DATE is an optional due date string."
  (let ((fields (list (cons "attachment" nil)
                      (cons "duedate" due-date)
                      (cons "customfield_10020"
                            (when sprint
                              (list (list (cons "name" sprint)
                                          (cons "state" "active"))))))))
    (list (cons "fields" fields))))

(defun org-tickets-test--insert-feature (title key)
  "Insert a Feature heading with TITLE and KEY at current point."
  (insert (format "* %s\n" title))
  (org-entry-put (point) "JIRA_TYPE" "Feature")
  (when key
    (org-entry-put (point) "JIRA_KEY" key)))

(defun org-tickets-test--insert-story (title key parent-key)
  "Insert a Story heading with TITLE, KEY, and PARENT-KEY."
  (insert (format "** %s\n" title))
  (org-entry-put (point) "JIRA_TYPE" "Story")
  (when key
    (org-entry-put (point) "JIRA_KEY" key))
  (when parent-key
    (org-entry-put (point) "PARENT" parent-key)))

(defun org-tickets-test--run-sync ()
  "Run `org-tickets--sync-to-jira' in the current temp org buffer.
Clears the sync guard and the read-only lock the pipeline sets, and
makes `mode-line-misc-info' buffer-local so progress reporting cannot
leak between tests."
  (setq org-tickets--sync-in-progress nil)
  (setq buffer-read-only nil)
  (make-local-variable 'mode-line-misc-info)
  (setq mode-line-misc-info nil)
  (org-tickets--sync-to-jira))

;;;; ADF and ticket helpers

(defconst org-tickets-test--parent-types
  '("Feature" "New Feature" "Improvement" "Epic")
  "Parent issue types, all imported at org level 1.")

(defun org-tickets-test--adf-texts (nodes)
  "Return every text string under ADF NODES, a list of content nodes.
Walks nested \"content\" the way an ADF renderer would."
  (mapcan (lambda (node)
            (when (listp node)
              (let ((text (cdr (assoc "text" node))))
                (if text
                    (list text)
                  (org-tickets-test--adf-texts (cdr (assoc "content" node)))))))
          nodes))

(defun org-tickets-test--adf-blocks (org-text)
  "Return the top-level ADF blocks pushed for ORG-TEXT."
  (cdr (assoc "content" (org-tickets--build-adf-description org-text))))

(defun org-tickets-test--block-type (block)
  "Return the ADF type of BLOCK."
  (cdr (assoc "type" block)))

(defun org-tickets-test--adf-heading-level (block)
  "Return BLOCK's heading level, or nil when BLOCK is not a heading."
  (when (equal (org-tickets-test--block-type block) "heading")
    (cdr (assoc "level" (cdr (assoc "attrs" block))))))

(defun org-tickets-test--block-text (block)
  "Return all text under ADF BLOCK concatenated."
  (apply #'concat (org-tickets-test--adf-texts (list block))))

(defun org-tickets-test--adf-outline (org-text)
  "Summarize the ADF pushed for ORG-TEXT as (TYPE-OR-LEVEL . TEXT) pairs.
Headings report their level number; other blocks their type string."
  (mapcar (lambda (block)
            (cons (or (org-tickets-test--adf-heading-level block)
                      (org-tickets-test--block-type block))
                  (org-tickets-test--block-text block)))
          (org-tickets-test--adf-blocks org-text)))

(defun org-tickets-test--adf-first-paragraph (org-text)
  "Return the inline nodes of the first paragraph pushed for ORG-TEXT.
Searches nested blocks (list items, quotes) depth first."
  (let ((found nil))
    (named-let walk ((nodes (org-tickets-test--adf-blocks org-text)))
      (dolist (node nodes)
        (unless found
          (if (equal (org-tickets-test--block-type node) "paragraph")
              (setq found (cdr (assoc "content" node)))
            (walk (cdr (assoc "content" node)))))))
    found))

(defun org-tickets-test--inline-summary (org-text)
  "Summarize ORG-TEXT's first paragraph as texts and the symbol `br'."
  (mapcar (lambda (node)
            (if (equal (cdr (assoc "type" node)) "hardBreak")
                'br
              (cdr (assoc "text" node))))
          (org-tickets-test--adf-first-paragraph org-text)))

(defun org-tickets-test--adf-doc (&rest blocks)
  "Return a JSON-decoded ADF doc of BLOCKS, shaped like an API response."
  (org-tickets-test--json
   (json-encode `(("type" . "doc") ("version" . 1)
                  ("content" . ,(vconcat blocks))))))

(defun org-tickets-test--adf-heading (level text &optional marks)
  "Return an ADF heading block at LEVEL holding TEXT with MARKS."
  (let ((node (list (cons "type" "text") (cons "text" text))))
    (when marks
      (setq node (append node (list (cons "marks" (vconcat marks))))))
    (list (cons "type" "heading")
          (cons "attrs" (list (cons "level" level)))
          (cons "content" (vector node)))))

(defun org-tickets-test--adf-para (text)
  "Return an ADF paragraph block holding TEXT."
  `(("type" . "paragraph") ("content" . [(("type" . "text") ("text" . ,text))])))

(defun org-tickets-test--pull (adf-or-json)
  "Import ADF-OR-JSON, an ADF doc or its JSON text, to org text.
An ADF doc passes through JSON first so the importer sees symbol keys,
exactly like a real GET response."
  (org-tickets--parse-adf-description
   (org-tickets-test--json (if (stringp adf-or-json)
                               adf-or-json
                             (json-encode adf-or-json)))))

(defun org-tickets-test--roundtrip (org-text)
  "Push ORG-TEXT to ADF, then pull it back as the API would return it."
  (let ((adf (org-tickets--build-adf-description org-text)))
    (should adf)
    (org-tickets-test--pull adf)))

(defun org-tickets-test--roundtrip-n (org-text n)
  "Push and pull ORG-TEXT N times; return the final text."
  (dotimes (_ n org-text)
    (setq org-text (org-tickets-test--roundtrip org-text))))

(defun org-tickets-test--ticket-text (stars type title body &optional key)
  "Return org text for a ticket heading.
STARS is the heading prefix, TYPE its JIRA_TYPE, TITLE its title, BODY
the text after the drawer, KEY an optional JIRA_KEY."
  (concat stars " " title "\n:PROPERTIES:\n:JIRA_TYPE: " type "\n"
          (if key (concat ":JIRA_KEY: " key "\n") "")
          ":END:\n" body))

(defun org-tickets-test--parse-tickets (text)
  "Parse org TEXT and return its tickets as (TITLE . DESCRIPTION) pairs."
  (with-temp-buffer
    (insert text)
    (org-mode)
    (mapcar (lambda (ticket)
              (cons (org-tickets--ticket-summary ticket)
                    (org-tickets--ticket-description ticket)))
            (org-tickets--doc-tickets (org-tickets--parse-document)))))

(defun org-tickets-test--description-of (text title)
  "Return the parsed description of the ticket titled TITLE in org TEXT."
  (cdr (assoc title (org-tickets-test--parse-tickets text))))

(defun org-tickets-test--pushed-outline (text title)
  "Return the ADF outline pushed for ticket TITLE parsed from org TEXT."
  (org-tickets-test--adf-outline (org-tickets-test--description-of text title)))

(defconst org-tickets-test--reported-item
  (concat "1. We then need to sign the header, which occupies the range "
          "~[0x0000, 0x1000)~ (inclusive left, exclusive right, offset "
          "~0x1000~ is the first byte of the prolog, which was included in "
          "the payload hash).\n"
          "   That signature should be done with ECDSA using SHA-384 and a "
          "Nist P-384 key.")
  "The ordered item from the bug report.")

(defmacro org-tickets-test--with-org-buffer-at (text target &rest body)
  "Run BODY in an org buffer of TEXT with point at the start of TARGET."
  (declare (indent 2))
  `(with-temp-buffer
     (insert ,text)
     (org-mode)
     (goto-char (point-min))
     (search-forward ,target)
     (goto-char (match-beginning 0))
     ,@body))

(defun org-tickets-test--prop-of (key prop)
  "Return property PROP of the heading whose JIRA_KEY is KEY."
  (save-excursion
    (goto-char (org-tickets--find-ticket-by-key key))
    (org-entry-get (point) prop)))

;;;; Attachment environment

(defun org-tickets-test--uuid-attach-path (id)
  "Return the relative path org-attach uses for ID under org-attach-id-dir.
org-attach splits the ID into a 2-char prefix subdirectory, followed by
the remaining characters of the ID, matching org-attach's directory layout."
  (format "%s/%s" (substring id 0 2) (substring id 2)))

(defmacro org-tickets-test--with-attach-env (target-id local-files org-content &rest body)
  "Set up an org-attach environment for cross-reference regression tests.
TARGET-ID is the ID property of the ticket heading that should be found.
LOCAL-FILES is a list of filenames to create in that ticket's attach dir.
ORG-CONTENT is a string to insert into a temp buffer in org-mode.
BODY is the test body, which can access `uploaded-to' — a list of
\(ticket-key . filename) pairs recorded by the mocked upload function."
  (declare (indent 3))
  `(let* ((attach-base (expand-file-name (format "test-attach-%s" (gensym))
                                         temporary-file-directory))
          (id-subdir (expand-file-name (org-tickets-test--uuid-attach-path ,target-id)
                                       attach-base))
          (uploaded-to (list)))
     (make-directory id-subdir t)
     (dolist (f ,local-files)
       (with-temp-file (expand-file-name f id-subdir)
         (insert "test content")))
     (unwind-protect
         (org-tickets-test--with-stubs ((org-tickets--async-upload-attachment
                                         (lambda (ticket-key file-path callback)
                                           (push (cons ticket-key (file-name-nondirectory file-path))
                                                 uploaded-to)
                                           (funcall callback nil nil)))
                                        (org-attach-dir
                                         (lambda (&optional _create-if-not-exists-p)
                                           id-subdir)))
           (with-temp-buffer
             (insert ,org-content)
             (org-mode)
             ,@body))
       (delete-directory attach-base t))))

(provide 'org-tickets-test-fixtures)
;;; org-tickets-test-fixtures.el ends here
