;;; org-tickets-test-sync-sprint.el --- Tests for org-tickets sprint sync  -*- lexical-binding: t; -*-

(require 'ert)
(require 'org)
(require 'org-element)

;; Load the main library
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; Tests for Sprint Sync

(ert-deftest org-tickets-test--sync-sprint-to-jira ()
  "Test syncing Sprint property to Jira."
  (let ((org-tickets-project-key "TEST")
        (org-tickets-project-id "12345"))
    (with-temp-buffer
      (insert "* Test\n")
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "\\*" nil t)
      (org-entry-put (point) "JIRA_KEY" "TEST-123")
      (org-entry-put (point) "JIRA_TYPE" "Task")
      (org-entry-put (point) "SPRINT" "Sprint 1")
      (let ((ticket (org-tickets--parse-ticket-at-point)))
        (should (string= (org-tickets--ticket-sprint ticket) "Sprint 1"))))))

(ert-deftest org-tickets-test--import-pulls-sprint-from-jira ()
  "Test that import pulls sprint from Jira when org is missing sprint."
  ;; Verify that org-tickets--parse-jira-issue extracts sprint field
  (let* ((jira-response
          (org-tickets-test--json "{\"id\": \"12345\", \"key\": \"PROJ-100\", \"fields\": {\"summary\": \"Test ticket\", \
    \"issuetype\": {\"name\": \"Story\"}, \"customfield_10020\": [{\"name\": \"Sprint 42\"}]}}"))
         (ticket (org-tickets--parse-jira-issue jira-response)))
    (should (string= (org-tickets--ticket-sprint ticket) "Sprint 42"))))

;;;; Tests for Sprint API Format

(defmacro org-tickets-test--capturing-requests (requests &rest body)
  "Run BODY against a fake Jira API that logs each request on REQUESTS.
REQUESTS is a `:log' variable of `org-tickets-test--fake-jira-handler';
issue creates answer with key PROJ-9 and sprint names resolve to 3453."
  (declare (indent 1))
  `(org-tickets-test--with-fake-api
       (org-tickets-test--fake-jira-handler :post-keys '("PROJ-9") :log ,requests)
     (org-tickets-test--with-stubs ((org-tickets--resolve-sprint-id (lambda (_name) 3453)))
       ,@body)))

(defun org-tickets-test--sent-field (request field)
  "Return FIELD (a symbol) from the fields of a captured REQUEST."
  (cdr (assq field (cdr (assq 'fields (nth 2 request))))))

(ert-deftest org-tickets-test--sprint-sent-as-id-in-update ()
  "Updating a ticket with a sprint name PUTs the resolved numeric ID."
  (let ((requests nil))
    (org-tickets-test--capturing-requests requests
      (org-tickets--update-ticket
       (org-tickets--ticket-create :key "PROJ-100" :sprint "Sprint 1")))
    (should (equal (butlast (car requests)) '("PUT" "/rest/api/3/issue/PROJ-100")))
    (should (eql (org-tickets-test--sent-field (car requests) 'customfield_10020)
                 3453))))

(ert-deftest org-tickets-test--sprint-sent-as-id-numeric ()
  "A numeric sprint value is passed through as-is."
  (let ((requests nil))
    (org-tickets-test--capturing-requests requests
      (org-tickets--update-ticket
       (org-tickets--ticket-create :key "PROJ-100" :sprint 3453)))
    (should (eql (org-tickets-test--sent-field (car requests) 'customfield_10020)
                 3453))))

(ert-deftest org-tickets-test--sprint-sent-as-id-in-create ()
  "Creating a ticket with a sprint name POSTs the resolved numeric ID."
  (let ((requests nil))
    (org-tickets-test--capturing-requests requests
      (should (equal (alist-get 'key (org-tickets--create-ticket
                                      (org-tickets--ticket-create
                                       :type "Story" :summary "Test"
                                       :sprint "Sprint 1")))
                     "PROJ-9")))
    (let ((request (car requests)))
      (should (equal (butlast request) '("POST" "/rest/api/3/issue")))
      (should (equal (org-tickets-test--sent-field request 'summary) "Test"))
      (should (equal (org-tickets-test--sent-field request 'issuetype)
                     '(("id" . "10001"))))
      (should (eql (org-tickets-test--sent-field request 'customfield_10020)
                   3453)))))

(ert-deftest org-tickets-test--update-ticket-without-changes-sends-nothing ()
  "A ticket record with nothing to update issues no request."
  (let ((requests nil))
    (org-tickets-test--capturing-requests requests
      (should-not (org-tickets--update-ticket
                   (org-tickets--ticket-create :key "PROJ-100"))))
    (should-not requests)))

;;;; Tests for with-sprint-field

(ert-deftest org-tickets-test--with-sprint-field-replaces-existing-sprint ()
  "A resolvable sprint replaces any sprint entry already in FIELDS."
  (should (equal (org-tickets--with-sprint-field
                  '((summary . "S") (customfield_10020 . 1)) 3453)
                 '((summary . "S") (customfield_10020 . 3453)))))

(ert-deftest org-tickets-test--with-sprint-field-adds-resolved-name ()
  "A sprint name is resolved to its ID and added."
  (org-tickets-test--with-stubs ((org-tickets--resolve-sprint-id
                               (lambda (_name) 3453)))
    (should (equal (org-tickets--with-sprint-field '((summary . "S")) "Sprint 1")
                   '((summary . "S") (customfield_10020 . 3453))))))

(ert-deftest org-tickets-test--with-sprint-field-leaves-fields-for-no-sprint ()
  "Nil, empty and unresolvable sprints leave FIELDS unchanged."
  (let ((fields '((summary . "S") (customfield_10020 . 1))))
    (org-tickets-test--with-stubs ((org-tickets--resolve-sprint-id
                                 (lambda (_name) nil)))
      (should (equal (org-tickets--with-sprint-field fields nil) fields))
      (should (equal (org-tickets--with-sprint-field fields "") fields))
      (should (equal (org-tickets--with-sprint-field fields "No Such Sprint")
                     fields)))))

;;;; Tests for resolve-sprint-value

(ert-deftest org-tickets-test--resolve-sprint-value-from-name ()
  "Test that resolve-sprint-value resolves a name to numeric ID."
  (org-tickets-test--with-stubs ((org-tickets--resolve-sprint-id
                               (lambda (_name) 3453)))
    (should (= (org-tickets--resolve-sprint-value "Sprint 1") 3453))))

(ert-deftest org-tickets-test--resolve-sprint-value-from-numeric-string ()
  "Test that resolve-sprint-value converts a numeric string to number."
  (should (= (org-tickets--resolve-sprint-value "3453") 3453)))

(ert-deftest org-tickets-test--resolve-sprint-value-from-number ()
  "Test that resolve-sprint-value passes through a number."
  (should (= (org-tickets--resolve-sprint-value 3453) 3453)))

(ert-deftest org-tickets-test--resolve-sprint-value-unresolvable ()
  "Test that resolve-sprint-value returns nil for unresolvable name."
  (org-tickets-test--with-stubs ((org-tickets--resolve-sprint-id
                               (lambda (_name) nil)))
    (should (null (org-tickets--resolve-sprint-value "Nonexistent Sprint")))))

(ert-deftest org-tickets-test--extract-sprint-honors-custom-field ()
  "`org-tickets--issue-sprint' reads the configured
`org-tickets-sprint-field', not a hardcoded customfield_10020."
  (let ((org-tickets-sprint-field "customfield_99999"))
    (let ((response (org-tickets-test--json
                     "{\"fields\": {\"customfield_99999\": [{\"name\": \"Sprint 42\", \"state\": \"active\"}]}}")))
      (should (string= (org-tickets--issue-sprint response)
                       "Sprint 42")))))

(ert-deftest org-tickets-test--fix-version-sent-as-array ()
  "Creating a ticket sends fixVersions as an array of name objects."
  (let ((requests nil))
    (org-tickets-test--capturing-requests requests
      (org-tickets--create-ticket
       (org-tickets--ticket-create :type "Story" :summary "S"
                                   :fix-version "Aug2026")))
    (should (equal (org-tickets-test--sent-field (car requests) 'fixVersions)
                   '((("name" . "Aug2026")))))))

(ert-deftest org-tickets-test--fix-version-sent-as-array-update ()
  "Updating a ticket sends fixVersions as an array of name objects."
  (let ((requests nil))
    (org-tickets-test--capturing-requests requests
      (org-tickets--update-ticket
       (org-tickets--ticket-create :key "PROJ-100" :fix-version "Aug2026")))
    (should (equal (org-tickets-test--sent-field (car requests) 'fixVersions)
                   '((("name" . "Aug2026")))))))

;;;; Tests for sprint cache clearing

(ert-deftest org-tickets-test--sprint-cache-is-cleared-between-syncs ()
  "Test that the sprint cache is cleared between sync sessions."
  (let ((org-tickets--sprint-cache (org-tickets-test--json "{\"Old Sprint\": \"3453\"}")))
    (org-tickets--clear-sprint-cache)
    (should (null org-tickets--sprint-cache))))

;;;; Regression tests for symbol-key JSON responses
;; Emacs json-read-from-string with json-object-type 'alist produces symbol
;; keys, not string keys.  These tests verify sprint functions handle both.

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

(provide 'org-tickets-test-sync-sprint)
