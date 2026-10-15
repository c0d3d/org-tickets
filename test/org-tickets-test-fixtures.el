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
;; Also holds the end-to-end sync harness (`org-tickets-test--with-sync-mocks'
;; and the heading builders) shared by every test that drives
;; `org-tickets--sync-to-jira' with a stubbed HTTP layer.

;;; Code:

(require 'ert)
(require 'seq)
(require 'json)

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
                                (lambda (_ticket _buf callback) (funcall callback)))
                               (org-tickets--build-adf-description
                                (lambda (_desc _atts) nil))
                               (force-mode-line-update #'ignore)
                               (run-at-time #'ignore))
     (let ((org-tickets--jira-base-url "https://test.atlassian.net")
           (org-tickets--project-key "PROJ")
           (org-tickets--project-id "12345")
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

(provide 'org-tickets-test-fixtures)
;;; org-tickets-test-fixtures.el ends here
