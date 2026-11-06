;;; org-tickets-test-api.el --- Tests for org-tickets config and credentials  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests that requests read the configuration defcustoms and per-host
;; credentials at request time.  `auth-source-search' is stubbed, or
;; `auth-sources' bound to a temp file, so no test reads ~/.authinfo.

;;; Code:

(require 'ert)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

(defun org-tickets-test--fake-auth (&rest spec)
  "Return an auth-source result for SPEC's :host, user \"user@HOST\"."
  (let ((host (plist-get spec :host)))
    (list (list :user (concat "user@" host) :secret (concat "token-" host)))))

(defmacro org-tickets-test--with-captured-requests (requests &rest body)
  "Run BODY with `url-retrieve' recording (URL . HEADERS) onto REQUESTS.
Credentials come from `org-tickets-test--fake-auth'; requests never
complete."
  (declare (indent 1))
  `(with-temp-buffer
     (org-tickets--rate-limit-reset)
     (let ((org-tickets--credentials-cache nil)
           (org-tickets-project-key "PROJ")
           (org-tickets-project-id "12345")
           (org-tickets-max-concurrent-requests 10))
       (org-tickets-test--with-stubs
           ((url-retrieve (lambda (url _cb &rest _)
                            (push (cons url url-request-extra-headers) ,requests)
                            nil))
            (auth-source-search #'org-tickets-test--fake-auth))
         ,@body))))

(defun org-tickets-test--basic-auth (user token)
  "Return the Authorization header value for USER and TOKEN."
  (concat "Basic " (base64-encode-string (concat user ":" token) t)))

(ert-deftest org-tickets-test--base-url-change-takes-effect ()
  "Setting `org-tickets-base-url' between requests redirects the next one."
  (let ((org-tickets-base-url "https://a.example")
        (requests nil))
    (org-tickets-test--with-captured-requests requests
      (org-tickets--async-request "GET" "/first" #'ignore)
      (setq org-tickets-base-url "https://b.example")
      (org-tickets--async-request "GET" "/second" #'ignore))
    (should (equal (mapcar #'car requests)
                   '("https://b.example/second" "https://a.example/first")))))

(ert-deftest org-tickets-test--credentials-follow-base-url-host ()
  "Each host's requests carry that host's credentials from auth-source."
  (let ((org-tickets-base-url "https://a.example")
        (requests nil))
    (org-tickets-test--with-captured-requests requests
      (org-tickets--async-request "GET" "/1" #'ignore)
      (setq org-tickets-base-url "https://b.example")
      (org-tickets--async-request "GET" "/2" #'ignore))
    (should (equal (mapcar (lambda (r) (cdr (assoc "Authorization" (cdr r))))
                           requests)
                   (list (org-tickets-test--basic-auth "user@b.example" "token-b.example")
                         (org-tickets-test--basic-auth "user@a.example" "token-a.example"))))))

(ert-deftest org-tickets-test--credentials-looked-up-once-per-host ()
  "Repeated requests to one host query auth-source once."
  (let ((org-tickets-base-url "https://a.example")
        (requests nil)
        (lookups 0))
    (org-tickets-test--with-captured-requests requests
      (org-tickets-test--with-stubs
          ((auth-source-search (lambda (&rest spec)
                                 (setq lookups (1+ lookups))
                                 (apply #'org-tickets-test--fake-auth spec))))
        (org-tickets--async-request "GET" "/1" #'ignore)
        (org-tickets--async-request "GET" "/2" #'ignore)))
    (should (= lookups 1))
    (should (= (length requests) 2))))

(ert-deftest org-tickets-test--missing-config-is-user-error ()
  "Requests with an unset configuration signal `user-error'."
  (let ((org-tickets-base-url nil)
        (requests nil))
    (org-tickets-test--with-captured-requests requests
      (should-error (org-tickets--async-request "GET" "/x" #'ignore)
                    :type 'user-error))
    (should-not requests)))

(ert-deftest org-tickets-test--credentials-reread-per-command ()
  "A token rotated in auth-source is used from the next command on.
Within one command, repeated requests look credentials up once."
  (let ((org-tickets-base-url "https://a.example")
        (requests nil)
        (token "old")
        (lookups 0))
    (org-tickets-test--with-captured-requests requests
      (org-tickets-test--with-stubs
          ((auth-source-search (lambda (&rest _)
                                 (setq lookups (1+ lookups))
                                 (list (list :user "u" :secret token)))))
        (org-tickets--resolve-config)
        (org-tickets--async-request "GET" "/1" #'ignore)
        (org-tickets--async-request "GET" "/2" #'ignore)
        (should (= lookups 1))
        (setq token "new")
        (org-tickets--resolve-config)
        (org-tickets--async-request "GET" "/3" #'ignore)))
    (should (equal (cdr (assoc "Authorization" (cdar requests)))
                   (org-tickets-test--basic-auth "u" "new")))))

(ert-deftest org-tickets-test--authinfo-entry-without-login-is-rejected ()
  "An authinfo entry with no login signals an error and sends nothing."
  (let ((org-tickets-base-url "https://a.example")
        (requests nil))
    (org-tickets-test--with-captured-requests requests
      (org-tickets-test--with-stubs
          ((auth-source-search (lambda (&rest _) (list (list :secret "t")))))
        (should (string-match-p
                 "API user is not set.*authinfo"
                 (error-message-string
                  (should-error (org-tickets--async-request "GET" "/x" #'ignore)))))))
    (should-not requests)))

(defun org-tickets-test--write-authinfo (file host token)
  "Write FILE as an authinfo with one entry for HOST holding TOKEN.
The mtime is set from TOKEN's length so successive writes always differ."
  (with-temp-file file
    (insert (format "machine %s login u password %s\n" host token)))
  (set-file-times file (time-add (current-time) (length token))))

(ert-deftest org-tickets-test--rotated-authinfo-token-used-next-command ()
  "A token rewritten in a real authinfo file is used from the next command.
auth-source's own result cache is left active, so this proves the
re-read reaches the file rather than a cached search result."
  (let* ((file (make-temp-file "org-tickets-authinfo"))
         (host "rotate.example.invalid")
         (auth-sources (list file))
         (auth-source-do-cache t)
         (org-tickets-base-url (concat "https://" host))
         (org-tickets-project-key "PROJ")
         (org-tickets-project-id "12345")
         (org-tickets--credentials-cache nil))
    (unwind-protect
        (progn
          (org-tickets-test--write-authinfo file host "old")
          (should (equal (org-tickets--resolve-config) '("u" . "old")))
          (org-tickets-test--write-authinfo file host "rotated")
          (should (equal (org-tickets--resolve-config) '("u" . "rotated"))))
      (auth-source-forget+ :host host)
      (delete-file file))))

;;;; Issue types

(ert-deftest org-tickets-test--save-issue-types-preserves-kill-ring ()
  "Saving issue types must not push the old line onto the kill ring."
  (with-temp-buffer
    (org-mode)
    (insert "#+JIRA_ISSUE_TYPES: Story=1\nbody\n")
    (let ((kill-ring nil))
      (org-tickets--save-issue-types '(("Story" . "2")))
      (should (null kill-ring))
      (should (string-match-p "^#\\+JIRA_ISSUE_TYPES: Story=2$" (buffer-string)))
      ;; No blank line accumulation on repeated saves.
      (org-tickets--save-issue-types '(("Story" . "2")))
      (should-not (string-match-p "\n\n\n" (buffer-string))))))

(ert-deftest org-tickets-test--save-issue-types-while-narrowed ()
  "Saving while narrowed to a ticket rewrites the one keyword line at the top.
The narrowing is left as it was."
  (with-temp-buffer
    (org-mode)
    (insert "#+JIRA_ISSUE_TYPES: Story=1\n* A\nbody A\n* B\nbody B\n")
    (goto-char (point-min))
    (re-search-forward "^\\* B")
    (org-narrow-to-subtree)
    (org-tickets--save-issue-types '(("Story" . "2")))
    (should (equal (buffer-string) "* B\nbody B\n"))
    (widen)
    (should (equal (buffer-string)
                   "#+JIRA_ISSUE_TYPES: Story=2\n* A\nbody A\n* B\nbody B\n"))))

(defconst org-tickets-test--createmeta-json
  "{\"projects\": [{\"issuetypes\": [
     {\"name\": \"Story\", \"id\": \"10001\"},
     {\"name\": \"New Feature\", \"id\": \"10002\"}]}]}"
  "A createmeta response listing two issue types.")

(ert-deftest org-tickets-test--fetch-issue-types-returns-alist-only ()
  "Fetching issue types returns them and leaves the buffer untouched."
  (with-temp-buffer
    (org-mode)
    (let ((org-tickets-project-key "TEST"))
      (org-tickets-test--with-stubs
          ((org-tickets--api-request
            (lambda (&rest _) (org-tickets-test--json org-tickets-test--createmeta-json))))
        (should (equal (org-tickets--fetch-issue-types)
                       '(("Story" . "10001") ("New Feature" . "10002"))))
        (should (equal (buffer-string) ""))))))

(ert-deftest org-tickets-test--ensure-issue-types-prefers-document ()
  "Issue types in the document are used without asking Jira."
  (with-temp-buffer
    (org-mode)
    (insert "#+JIRA_ISSUE_TYPES: Story=1\n")
    (let ((org-tickets--issue-type-ids nil))
      (org-tickets-test--with-stubs
          ((org-tickets--resolve-config #'ignore)
           (org-tickets--api-request (lambda (&rest _) (error "Unexpected request"))))
        (org-tickets--ensure-issue-types)
        (should (equal org-tickets--issue-type-ids '(("Story" . "1"))))))))

(ert-deftest org-tickets-test--ensure-issue-types-fetches-and-saves ()
  "Without a keyword, issue types are fetched and written to the document."
  (with-temp-buffer
    (org-mode)
    (insert "* H\n")
    (let ((org-tickets--issue-type-ids nil)
          (org-tickets-project-key "TEST"))
      (org-tickets-test--with-stubs
          ((org-tickets--resolve-config #'ignore)
           (org-tickets--api-request
            (lambda (&rest _) (org-tickets-test--json org-tickets-test--createmeta-json))))
        (org-tickets--ensure-issue-types)
        (should (equal org-tickets--issue-type-ids
                       '(("Story" . "10001") ("New Feature" . "10002"))))
        (should (equal (buffer-string)
                       "#+JIRA_ISSUE_TYPES: Story=10001,New Feature=10002\n* H\n"))))))

(ert-deftest org-tickets-test--request-data-is-utf-8-bytes ()
  "Request bodies are unibyte UTF-8 that decodes back to the original text."
  (let* ((encoded (org-tickets--encode-request-data
                   '((summary . "Caf\u00e9 r\u00e9sum\u00e9")
                     (emoji . "\U0001F389 party \U0001F30D"))))
         (decoded (json-read-from-string (decode-coding-string encoded 'utf-8))))
    (should-not (multibyte-string-p encoded))
    (should (equal (cdr (assq 'summary decoded)) "Caf\u00e9 r\u00e9sum\u00e9"))
    (should (equal (cdr (assq 'emoji decoded)) "\U0001F389 party \U0001F30D"))))

(ert-deftest org-tickets-test--request-data-nil-is-nil ()
  "No data means no request body."
  (should-not (org-tickets--encode-request-data nil)))

(ert-deftest org-tickets-test--api-request-nil-buffer-is-clear-error ()
  "A request that yields no response buffer signals an error."
  (org-tickets-test--with-fake-config
    (org-tickets-test--with-stubs ((url-retrieve-synchronously
                                 (lambda (&rest _) nil)))
      (should-error (org-tickets--api-request "GET" "/x")))))

(ert-deftest org-tickets-test--api-request-kills-response-buffer-and-tolerates-percent ()
  "The sync path must kill its response buffer and never treat the URL
as a format string (URLs with %20 crashed `message')."
  (let ((made-buffer nil))
    (org-tickets-test--with-fake-config
      (org-tickets-test--with-stubs ((url-retrieve-synchronously
                                   (lambda (_url &rest _)
                                     (setq made-buffer (generate-new-buffer " test-http"))
                                     (with-current-buffer made-buffer
                                       (insert "HTTP/1.1 200 OK\n\n{\"ok\": true}"))
                                     made-buffer)))
        (let ((response (org-tickets--api-request "GET" "/rest/api/3/search?jql=a%20b")))
          (should (eq (cdr (assq 'ok response)) t))
          (should-not (buffer-live-p made-buffer)))))))

(ert-deftest org-tickets-test--http-parse-json-body-shapes ()
  "Blank bodies parse to nil; JSON false parses to :json-false."
  (should (null (org-tickets--http-parse-json-body "")))
  (should (null (org-tickets--http-parse-json-body "  \n ")))
  (let ((parsed (org-tickets--http-parse-json-body "{\"key\": \"P-1\", \"ok\": false}")))
    (should (equal (cdr (assq 'key parsed)) "P-1"))
    (should (eq (cdr (assq 'ok parsed)) :json-false))))

(ert-deftest org-tickets-test--http-split-response-basic ()
  "A raw HTTP response splits into its status line and body."
  (with-temp-buffer
    (insert "HTTP/1.1 200 OK\nContent-Type: application/json\n\n{\"a\": 1}")
    (let ((parsed (org-tickets--http-split-response)))
      (should (string-match-p "200 OK" (plist-get parsed :status)))
      (should (equal (string-trim (plist-get parsed :body)) "{\"a\": 1}")))))

(ert-deftest org-tickets-test--get-sprints-paginates ()
  "Test that fetch-board-sprints fetches all pages."
  (let ((pages (list (org-tickets-test--json
                      "{\"values\": [{\"id\": 3453, \"name\": \"Sprint 1\"}], \"isLast\": false}")
                     (org-tickets-test--json
                      "{\"values\": [{\"id\": 3454, \"name\": \"Sprint 2\"}], \"isLast\": true}")))
        (call-count 0))
    (org-tickets-test--with-stubs ((org-tickets--api-request
                                    (lambda (_method _endpoint &rest _args)
                                      (setq call-count (1+ call-count))
                                      (pop pages)))
                                   (org-tickets--resolve-config #'ignore))
      (let ((sprints (org-tickets--fetch-board-sprints "210")))
        (should (= call-count 2))
        (should (= (length sprints) 2))
        (should (string= (caar sprints) "Sprint 1"))
        (should (string= (car (cadr sprints)) "Sprint 2"))))))

(ert-deftest org-tickets-test--get-board-id-with-symbol-keys ()
  "Test that get-board-id-for-project reads a parsed JSON board listing.
Regression test: previously used (assoc \"values\" ...) which fails on
symbol-keyed alists from json-read-from-string."
  (let ((page (org-tickets-test--json
               "{\"values\": [{\"id\": 210, \"name\": \"My Board\"}]}")))
    (org-tickets-test--with-stubs ((org-tickets--api-request
                                    (lambda (_method _endpoint &rest _args) page))
                                   (org-tickets--resolve-config #'ignore))
      (let ((org-tickets-project-key "PROJ"))
        (should (= (org-tickets--get-board-id-for-project) 210))))))

(ert-deftest org-tickets-test--get-sprints-with-symbol-keys ()
  "Test that fetch-board-sprints reads a parsed JSON sprint listing.
Regression test: json-read-from-string produces symbol keys, but the
sprint functions previously used string keys with assoc, silently failing."
  (let ((page (org-tickets-test--json
               "{\"values\": [{\"id\": 3453, \"name\": \"Sprint 1\", \"state\": \"active\"}, {\"id\": 3454, \"name\": \"Sprint 2\", \"state\": \"future\"}], \"isLast\": true}")))
    (org-tickets-test--with-stubs ((org-tickets--api-request
                                    (lambda (_method _endpoint &rest _args) page))
                                   (org-tickets--resolve-config #'ignore))
      (let ((sprints (org-tickets--fetch-board-sprints "210")))
        (should (equal (mapcar #'car sprints) '("Sprint 1" "Sprint 2")))
        (should (= (cdar sprints) 3453))))))

(ert-deftest org-tickets-test--clear-sprint-cache-empties-cache ()
  "Clearing the sprint cache leaves it empty."
  (let ((org-tickets--sprint-cache '(("Old Sprint" . "3453"))))
    (org-tickets--clear-sprint-cache)
    (should (null org-tickets--sprint-cache))))

(ert-deftest org-tickets-test--issue-sprint-reads-configured-field ()
  "The sprint is read from `org-tickets-sprint-field', whatever its id."
  (let ((org-tickets-sprint-field "customfield_99999"))
    (let ((response (org-tickets-test--json
                     "{\"fields\": {\"customfield_99999\": [{\"name\": \"Sprint 42\", \"state\": \"active\"}]}}")))
      (should (string= (org-tickets--issue-sprint response)
                       "Sprint 42")))))

(ert-deftest org-tickets-test--resolve-sprint-value-unresolvable ()
  "Test that resolve-sprint-value returns nil for unresolvable name."
  (org-tickets-test--with-stubs ((org-tickets--resolve-sprint-id
                               (lambda (_name) nil)))
    (should (null (org-tickets--resolve-sprint-value "Nonexistent Sprint")))))

(ert-deftest org-tickets-test--resolve-sprint-value-from-number ()
  "Test that resolve-sprint-value passes through a number."
  (should (= (org-tickets--resolve-sprint-value 3453) 3453)))

(ert-deftest org-tickets-test--resolve-sprint-value-from-numeric-string ()
  "Test that resolve-sprint-value converts a numeric string to number."
  (should (= (org-tickets--resolve-sprint-value "3453") 3453)))

(ert-deftest org-tickets-test--resolve-sprint-value-from-name ()
  "Test that resolve-sprint-value resolves a name to numeric ID."
  (org-tickets-test--with-stubs ((org-tickets--resolve-sprint-id
                               (lambda (_name) 3453)))
    (should (= (org-tickets--resolve-sprint-value "Sprint 1") 3453))))

(ert-deftest org-tickets-test--resolve-sprint-id-looks-up-by-name ()
  "The sprint cache maps names to IDs; unknown names resolve to nil."
  (let ((org-tickets--sprint-cache '(("Test Sprint" . "3453")
                                     ("Next Sprint" . "3454"))))
    (should (equal (org-tickets--resolve-sprint-id "Test Sprint") "3453"))
    (should (equal (org-tickets--resolve-sprint-id "Next Sprint") "3454"))
    (should-not (org-tickets--resolve-sprint-id "Nonexistent Sprint"))))

(ert-deftest org-tickets-test--with-sprint-field-leaves-fields-for-no-sprint ()
  "Nil, empty and unresolvable sprints leave FIELDS unchanged."
  (let ((fields '((summary . "S") (customfield_10020 . 1))))
    (org-tickets-test--with-stubs ((org-tickets--resolve-sprint-id
                                 (lambda (_name) nil)))
      (should (equal (org-tickets--with-sprint-field fields nil) fields))
      (should (equal (org-tickets--with-sprint-field fields "") fields))
      (should (equal (org-tickets--with-sprint-field fields "No Such Sprint")
                     fields)))))

(ert-deftest org-tickets-test--with-sprint-field-adds-resolved-name ()
  "A sprint name is resolved to its ID and added."
  (org-tickets-test--with-stubs ((org-tickets--resolve-sprint-id
                               (lambda (_name) 3453)))
    (should (equal (org-tickets--with-sprint-field '((summary . "S")) "Sprint 1")
                   '((summary . "S") (customfield_10020 . 3453))))))

(ert-deftest org-tickets-test--with-sprint-field-replaces-existing-sprint ()
  "A resolvable sprint replaces any sprint entry already in FIELDS."
  (should (equal (org-tickets--with-sprint-field
                  '((summary . "S") (customfield_10020 . 1)) 3453)
                 '((summary . "S") (customfield_10020 . 3453)))))

(ert-deftest org-tickets-test--get-attachments-response-parsing ()
  "Test that attachment ID can be extracted from issue endpoint response."
  (let* ((issue-response (org-tickets-test--json "{\"expand\": \"names,schema\", \"key\": \"PROJ-12752\", \"id\": \"108903\", \"self\": \"https://your-domain.atlassian.net/rest/api/3/issue/108903\", \
    \"fields\": {\"summary\": \"Test story\", \"attachment\": [{\"self\": \"https://your-domain.atlassian.net/rest/api/3/attachment/10001\", \
    \"id\": \"10001\", \"filename\": \"screenshot.png\", \"content\": \"https://your-domain.atlassian.net/rest/api/3/attachment/content/10001\", \
    \"thumbnail\": \"https://your-domain.atlassian.net/rest/api/3/attachment/thumbnail/10001\", \
    \"mimeType\": \"image/png\", \"size\": 45678, \"created\": \"2024-10-15T10:30:00.000Z\", \
    \"author\": {\"accountId\": \"123456789\", \"displayName\": \"Test User\"}}]}}")))
    (let ((attachments (org-tickets--issue-attachments issue-response)))
      (should attachments)
      (let ((attachment (car attachments)))
        (should (string= (org-tickets--attachment-id attachment) "10001"))
        (should (string= (org-tickets--attachment-filename attachment) "screenshot.png"))
        (should (string= (org-tickets--attachment-content-url attachment)
                         "https://your-domain.atlassian.net/rest/api/3/attachment/content/10001"))
        (should (equal (org-tickets--alist-get "size" attachment) 45678))))))

(ert-deftest org-tickets-test--issue-attachments-absent-or-null-is-nil ()
  "An issue with no fields, or a null attachment field, has no attachments."
  (should-not (org-tickets--issue-attachments
               (org-tickets-test--json "{\"key\": \"PROJ-123\", \"id\": \"1\"}")))
  (should-not (org-tickets--issue-attachments
               (org-tickets-test--json
                "{\"key\": \"PROJ-123\", \"fields\": {\"attachment\": null}}"))))

(provide 'org-tickets-test-api)
;;; org-tickets-test-api.el ends here
