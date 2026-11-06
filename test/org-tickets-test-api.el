;;; org-tickets-test-api.el --- Tests for org-tickets config and credentials  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests that requests read the configuration defcustoms and per-host
;; credentials at request time.  `auth-source-search' is always stubbed so
;; no test reads ~/.authinfo.

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

(provide 'org-tickets-test-api)
;;; org-tickets-test-api.el ends here
