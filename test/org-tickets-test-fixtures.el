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
;; Also holds the fake Jira site shared by every test that talks to the
;; HTTP layer: `--with-fake-config', the `url-retrieve' fake
;; `--with-url-responses', the request fake `--fake-jira-handler' with its
;; request log, `--with-fake-api' for the synchronous API, and the
;; end-to-end sync harness (`--with-sync-mocks', `--run-sync' and the
;; heading builders).

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

(defmacro org-tickets-test--recording-markers (var &rest body)
  "Run BODY with every marker made by `copy-marker' pushed onto VAR."
  (declare (indent 1))
  (let ((orig (make-symbol "orig")))
    `(let ((,orig (symbol-function 'copy-marker)))
       (org-tickets-test--with-stubs
           ((copy-marker (lambda (&rest args)
                           (let ((marker (apply ,orig args)))
                             (push marker ,var)
                             marker))))
         ,@body))))

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

;;;; Fake Jira site

(defconst org-tickets-test--host "test.atlassian.net"
  "Host of the fake Jira site every harness configures.")

(defmacro org-tickets-test--with-fake-config (&rest body)
  "Run BODY configured for the fake Jira site `org-tickets-test--host'.
Binds `org-tickets-base-url', `org-tickets-project-key' (\"PROJ\") and
`org-tickets-project-id' (\"12345\"), starts from an empty
`org-tickets--credentials-cache', and stubs `auth-source-search' to
return a fixed login, so credentials resolve without reading
~/.authinfo."
  (declare (indent 0) (debug (body)))
  `(org-tickets-test--with-stubs
       ((auth-source-search
         (lambda (&rest _)
           (list (list :host org-tickets-test--host
                       :user "user@test.com" :secret "token123")))))
     (let ((org-tickets-base-url (concat "https://" org-tickets-test--host))
           (org-tickets-project-key "PROJ")
           (org-tickets-project-id "12345")
           (org-tickets--credentials-cache nil))
       ,@body)))

;;;; Fake url-retrieve

(defun org-tickets-test--url-call (url callback)
  "Return the call-log entry for a `url-retrieve' of URL with CALLBACK.
A plist of :url, :method, :headers, :data (read from the url.el request
variables) and :callback."
  (list :url url :method url-request-method
        :headers url-request-extra-headers :data url-request-data
        :callback callback))

(defun org-tickets-test--url-respond (call response)
  "Answer the logged `url-retrieve' CALL with RESPONSE, a full HTTP string.
The callback runs in a fresh unibyte buffer, as url.el's would."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert response)
    (funcall (plist-get call :callback) nil)))

(defmacro org-tickets-test--with-url-responses (responses calls &rest body)
  "Run BODY against the fake Jira site with `url-retrieve' faked.
RESPONSES is a list of full HTTP response strings answered in order,
synchronously, one per request.  It may instead be the keyword
`:deferred': requests are then only logged, and the test answers each
one later with `org-tickets-test--url-respond'.  CALLS, unless nil, is
a variable each request is pushed onto (newest first) as the plist of
`org-tickets-test--url-call'.  `run-at-time' and
`force-mode-line-update' are stubbed out; the configuration comes from
`org-tickets-test--with-fake-config'."
  (declare (indent 2) (debug (form form body)))
  (let ((queue (make-symbol "queue"))
        (call (make-symbol "call"))
        (deferred (eq responses :deferred)))
    `(let ((,queue ,(unless deferred responses)))
       (ignore ,queue)
       (org-tickets-test--with-fake-config
         (org-tickets-test--with-stubs
             ((url-retrieve
               (lambda (url callback &rest _)
                 (let ((,call (org-tickets-test--url-call url callback)))
                   ,@(when calls `((push ,call ,calls)))
                   ,(if deferred
                        `(ignore ,call)
                      `(org-tickets-test--url-respond ,call (pop ,queue))))
                 nil))
              (run-at-time #'ignore)
              (force-mode-line-update #'ignore))
           ,@body)))))

;;;; Fake Jira request handler

(defun org-tickets-test--next-post-key (key-queue)
  "Return the next issue key from KEY-QUEUE, a one-element list of keys.
Keys are handed out in order; the last one repeats."
  (let ((keys (car key-queue)))
    (when (cdr keys)
      (setcar key-queue (cdr keys)))
    (car keys)))

(defun org-tickets-test--fake-jira-answer (method endpoint get key-queue)
  "Return the fake Jira response to a METHOD request on ENDPOINT.
GET answers every GET: a response, or a function of ENDPOINT returning
one.  An issue create (POST /rest/api/3/issue) answers with the next key
from KEY-QUEUE.  Everything else answers with an empty response."
  (pcase method
    ("GET" (if (functionp get) (funcall get endpoint) get))
    ("POST" (when (equal endpoint "/rest/api/3/issue")
              (org-tickets-test--json
               (format "{\"key\": \"%s\"}"
                       (org-tickets-test--next-post-key key-queue)))))))

(defmacro org-tickets-test--fake-jira-handler (&rest args)
  "Return a fake `org-tickets--async-request' that answers like Jira.
ARGS is a plist:
  :get        the response to every GET, or a function of the endpoint
              returning one (default: `org-tickets-test--make-get-response').
  :post-keys  issue keys handed out in order to issue creates
              (POST /rest/api/3/issue); the last repeats (default
              \(\"PROJ-NEW\")).
  :log        a variable; each request is pushed onto it as
              \(METHOD ENDPOINT DATA), newest first.  Filter it with
              `org-tickets-test--requests'.
Every other request succeeds with an empty response.  Callbacks run
synchronously.  The result also fits `org-tickets-test--with-fake-api'."
  (let ((get (make-symbol "get"))
        (key-queue (make-symbol "key-queue"))
        (log (plist-get args :log)))
    `(let ((,get ,(or (plist-get args :get)
                      '(org-tickets-test--make-get-response)))
           (,key-queue (list ,(or (plist-get args :post-keys)
                                  ''("PROJ-NEW")))))
       (lambda (method endpoint callback &optional data)
         ,@(when log `((push (list method endpoint data) ,log)))
         (funcall callback
                  (org-tickets-test--fake-jira-answer
                   method endpoint ,get ,key-queue)
                  nil)))))

(defun org-tickets-test--requests (log method &optional endpoint)
  "Return the requests in LOG made with METHOD, oldest first.
LOG is a `:log' variable of `org-tickets-test--fake-jira-handler'.
When ENDPOINT is given, only requests to exactly that endpoint count."
  (seq-filter (lambda (request)
                (and (equal (nth 0 request) method)
                     (or (null endpoint) (equal (nth 1 request) endpoint))))
              (reverse log)))

(defun org-tickets-test--payload-field (data field)
  "Return FIELD (a symbol) of the `fields' in request payload DATA."
  (cdr (assq field (cdr (assq 'fields data)))))

(defun org-tickets-test--logged-links (log)
  "Return the issue links POSTed in LOG as (BLOCKER BLOCKED TYPE) lists."
  (mapcar (lambda (request)
            (let ((data (nth 2 request)))
              (list (cdr (assoc "key" (cdr (assoc "inwardIssue" data))))
                    (cdr (assoc "key" (cdr (assoc "outwardIssue" data))))
                    (cdr (assoc "name" (cdr (assq 'type data)))))))
          (org-tickets-test--requests log "POST" "/rest/api/3/issueLink")))

(defun org-tickets-test--sync-api (handler)
  "Return a fake `org-tickets--api-request' answering through HANDLER.
HANDLER is an async request function such as a
`org-tickets-test--fake-jira-handler'; it must call back synchronously."
  (lambda (method endpoint &optional data)
    (let ((response nil))
      (funcall handler method endpoint
               (lambda (r _err) (setq response r))
               data)
      response)))

(defmacro org-tickets-test--with-fake-api (handler &rest body)
  "Run BODY with the synchronous Jira API answered by HANDLER.
`org-tickets--api-request' goes through HANDLER (see
`org-tickets-test--sync-api'), issue types are pre-resolved (Story is
10001), no default sprint is set, and the configuration comes from
`org-tickets-test--with-fake-config'."
  (declare (indent 1) (debug (form body)))
  `(org-tickets-test--with-fake-config
     (org-tickets-test--with-stubs
         ((org-tickets--api-request (org-tickets-test--sync-api ,handler))
          (org-tickets--ensure-issue-types #'ignore))
       (let ((org-tickets-default-sprint nil)
             (org-tickets--issue-type-ids '(("Story" . "10001"))))
         ,@body))))

;;;; End-to-end sync harness

(defun org-tickets-test--get-ticket-via-async (key)
  "Fetch issue KEY through `org-tickets--async-request' and return it.
Relies on the request handler calling back synchronously."
  (let ((response nil))
    (org-tickets--async-request "GET" (concat "/rest/api/3/issue/" key)
                                (lambda (r _err) (setq response r)))
    response))

(defconst org-tickets-test--stub-adf-description
  '((type . "doc") (version . 1) (content . []))
  "The ADF description `org-tickets-test--with-sync-mocks' converts every body to.")

(defun org-tickets-test--attachments-done (_key _attachments callback)
  "Stand in for an attachment batch function: report CALLBACK done."
  (funcall callback nil nil))

(eval-and-compile
  (defun org-tickets-test--sync-mock-stubs (request-handler)
    "Return the (SYMBOL FUNCTION-FORM) stubs of `--with-sync-mocks'.
REQUEST-HANDLER is the form answering `org-tickets--async-request'."
    `((org-tickets--async-request ,request-handler)
      (org-tickets--get-ticket #'org-tickets-test--get-ticket-via-async)
      (org-tickets--ensure-issue-types #'ignore)
      (org-tickets--clear-sprint-cache #'ignore)
      (org-tickets--async-upload-attachments #'org-tickets-test--attachments-done)
      (org-tickets--async-download-attachments #'org-tickets-test--attachments-done)
      (org-tickets--async-sync-ticket-links
       (lambda (_ticket callback) (funcall callback)))
      (org-tickets--build-adf-description
       (lambda (&rest _) org-tickets-test--stub-adf-description))
      (url-retrieve-synchronously
       (lambda (url &rest _)
         (error "Test reached the network: %s" url)))
      (force-mode-line-update #'ignore)
      (run-at-time #'ignore))))

(defmacro org-tickets-test--with-sync-mocks (request-handler &rest body)
  "Run BODY with the sync pipeline's Jira side faked.
REQUEST-HANDLER replaces `org-tickets--async-request': a function
\(METHOD ENDPOINT CALLBACK &optional DATA), usually a
`org-tickets-test--fake-jira-handler'; nil means a default one.

Stubbed out: issue-type and sprint-cache setup, both attachment batch
functions and `org-tickets--async-sync-ticket-links' (all report done
at once), and `org-tickets--build-adf-description' (returns the fixed
`org-tickets-test--stub-adf-description', so no conversion runs).  The synchronous `org-tickets--get-ticket' is
routed through REQUEST-HANDLER as a GET of /rest/api/3/issue/KEY, so
parent lookups (due-date and fix-version inheritance) see the same fake
Jira and appear in its log.  Any other synchronous request (e.g. sprint
name resolution) signals instead of reaching the real network.

BODY may start with `:real (FN ...)' to leave the named functions
unstubbed, e.g. `:real (org-tickets--async-sync-ticket-links)' to send
real link requests through REQUEST-HANDLER.  Configuration comes from
`org-tickets-test--with-fake-config'; Feature, New Feature and Story
issue types are pre-resolved."
  (declare (indent 1) (debug (form &rest form)))
  (let* ((real-p (eq (car body) :real))
         (real (and real-p (cadr body)))
         (stubs (org-tickets-test--sync-mock-stubs
                 (or request-handler '(org-tickets-test--fake-jira-handler)))))
    `(org-tickets-test--with-fake-config
       (org-tickets-test--with-stubs
           ,(seq-remove (lambda (stub) (memq (car stub) real)) stubs)
         (let ((org-tickets--issue-type-ids
                (list (cons "Feature" "10000")
                      (cons "New Feature" "10000")
                      (cons "Story" "10001"))))
           ,@(if real-p (cddr body) body))))))

(defun org-tickets-test--make-get-response (&optional sprint due-date)
  "Build a parsed GET /issue response from JSON.
SPRINT is an optional sprint name string, placed under
`org-tickets-sprint-field' as an array of sprint objects.
DUE-DATE is an optional due date string."
  (org-tickets-test--json
   (json-encode
    `((fields
       . ((attachment . [])
          (duedate . ,due-date)
          (,(intern org-tickets-sprint-field)
           . ,(if sprint
                  (vector `((name . ,sprint) (state . "active")))
                nil))))))))

(defun org-tickets-test--insert-ticket (level title &rest props)
  "Append a LEVEL heading titled TITLE with PROPS to the current buffer.
PROPS alternates property names and values, e.g. \"JIRA_TYPE\" \"Story\";
nil values are skipped.  Point is left at the end of the buffer."
  (goto-char (point-max))
  (insert (make-string level ?*) " " title "\n")
  (let ((heading (save-excursion (org-back-to-heading t) (point))))
    (while props
      (when (cadr props)
        (org-entry-put heading (car props) (cadr props)))
      (setq props (cddr props))))
  (goto-char (point-max)))

(defun org-tickets-test--insert-feature (title key &rest props)
  "Append a Feature heading with TITLE, KEY and extra PROPS.
PROPS is as for `org-tickets-test--insert-ticket'."
  (apply #'org-tickets-test--insert-ticket 1 title
         "JIRA_TYPE" "Feature" "JIRA_KEY" key props))

(defun org-tickets-test--insert-story (title key parent-key &rest props)
  "Append a Story heading with TITLE, KEY, PARENT-KEY and extra PROPS.
PROPS is as for `org-tickets-test--insert-ticket'."
  (apply #'org-tickets-test--insert-ticket 2 title
         "JIRA_TYPE" "Story" "JIRA_KEY" key "PARENT" parent-key props))

(defun org-tickets-test--run-sync ()
  "Run `org-tickets--sync-to-jira' in the current temp org buffer.
Clears the sync guard and the read-only lock first.
`org-tickets--progress-install' is stubbed for the run: it adds the
progress entry to the global default of `mode-line-misc-info' with
`setq-default', which would leak out of the test."
  (setq org-tickets--sync-in-progress nil)
  (setq buffer-read-only nil)
  (org-tickets-test--with-stubs ((org-tickets--progress-install #'ignore))
    (org-tickets--sync-to-jira)))

(defun org-tickets-test--issue-response (&rest args)
  "Build a parsed GET /issue?expand=changelog response from JSON.
ARGS is a plist: :key, :type (issue type name), :updated
\(fields.updated), :summary, :labels, and :histories, a list of
\(AUTHOR-ID AUTHOR-NAME CREATED FIELD-ID...).  A FIELD-ID that is a
cons, such as (field . \"Link\"), is used as the whole changelog item."
  (org-tickets-test--json
   (json-encode
    `((key . ,(plist-get args :key))
      (fields . ((attachment . [])
                 (issuetype . ((name . ,(plist-get args :type))))
                 (updated . ,(plist-get args :updated))
                 (summary . ,(plist-get args :summary))
                 (labels . ,(vconcat (plist-get args :labels)))))
      (changelog
       . ((histories
           . ,(vconcat
               (mapcar
                (lambda (h)
                  `((author . ((accountId . ,(nth 0 h))
                               (displayName . ,(nth 1 h))))
                    (created . ,(nth 2 h))
                    (items . ,(vconcat
                               (mapcar (lambda (id)
                                         (if (consp id) (list id)
                                           `((fieldId . ,id))))
                                       (nthcdr 3 h))))))
                (plist-get args :histories))))))))))

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
