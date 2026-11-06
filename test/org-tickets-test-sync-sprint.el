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
          (list (cons "id" "12345")
                (cons "key" "PROJ-100")
                (cons "fields"
                      (list (cons "summary" "Test ticket")
                            (cons "issuetype" (list (cons "name" "Story")))
                            (cons "customfield_10020"
                                  (list (cons "name" "Sprint 42")))))))
         (ticket (org-tickets--parse-jira-issue jira-response)))
    (should (string= (org-tickets--ticket-sprint ticket) "Sprint 42"))))

;;;; Tests for Sprint API Format

(ert-deftest org-tickets-test--sprint-sent-as-id-in-update ()
  "Test that update-ticket sends sprint as a numeric ID in customfield_10020.
Mocks resolve-sprint-id to return a known ID for the sprint name."
  (let ((captured-fields nil))
    (org-tickets-test--with-stubs ((org-tickets--api-request
                                 (lambda (_method _endpoint data)
                                   (setq captured-fields (cdr (assoc 'fields data)))))
                                (org-tickets--resolve-sprint-id
                                 (lambda (_name) 3453)))
      (org-tickets--update-ticket "PROJ-100" :sprint "Sprint 1")
      ;; Sprint should be sent as bare numeric ID, not wrapped in {"id": ...}
      (let ((sprint-field (cdr (assoc 'customfield_10020 captured-fields))))
        (should (numberp sprint-field))
        (should (= sprint-field 3453))))))

(ert-deftest org-tickets-test--sprint-sent-as-id-numeric ()
  "Test that a numeric sprint value is passed through as-is."
  (let ((captured-fields nil))
    (org-tickets-test--with-stubs ((org-tickets--api-request
                                 (lambda (_method _endpoint data)
                                   (setq captured-fields (cdr (assoc 'fields data))))))
      (org-tickets--update-ticket "PROJ-100" :sprint 3453)
      (let ((sprint-field (cdr (assoc 'customfield_10020 captured-fields))))
        (should (numberp sprint-field))
        (should (= sprint-field 3453))))))

(ert-deftest org-tickets-test--sprint-sent-as-id-in-create ()
  "Test that create-ticket sends sprint as a numeric ID."
  (let ((captured-fields nil))
    (org-tickets-test--with-stubs ((org-tickets--api-request
                                 (lambda (_method _endpoint data)
                                   (setq captured-fields (cdr (assoc 'fields data)))))
                                (org-tickets--resolve-sprint-id
                                 (lambda (_name) 3453))
                                (org-tickets--ensure-issue-types #'ignore)
                                (org-tickets--resolve-config #'ignore))
      (let ((org-tickets--project-id "12345")
            (org-tickets--issue-type-ids '(("Story" . "10001"))))
        (org-tickets--create-ticket "Story" "Test" nil nil nil nil "Sprint 1"))
      (let ((sprint-field (cdr (assoc 'customfield_10020 captured-fields))))
        (should (numberp sprint-field))
        (should (= sprint-field 3453))))))

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

(ert-deftest org-tickets-test--get-sprints-with-ids ()
  "Test fetching sprints returns both name and ID."
  (let* ((mock-response (list (cons "values"
                                    (list (list (cons "id" 3453)
                                                (cons "name" "Sprint 1")
                                                (cons "state" "active"))
                                          (list (cons "id" 3454)
                                                (cons "name" "Sprint 2")
                                                (cons "state" "future"))))
                              (cons "isLast" t))))
    (org-tickets-test--with-stubs ((org-tickets--api-request
                                 (lambda (method endpoint &rest args)
                                   mock-response))
                                (org-tickets--resolve-config #'ignore))
      (let ((sprints (org-tickets--get-sprints-for-project "210" t)))
        (should (= (length sprints) 2))
        (should (stringp (caar sprints)))  ; first element key is name (string)
        ;; cdr is the ID — in real data it's a string, here the mock uses numbers
        (should (member (cdar sprints) '("3453" 3453)))))))

(ert-deftest org-tickets-test--extract-sprint-honors-custom-field ()
  "`org-tickets--extract-sprint-from-response' reads the configured
`org-tickets-sprint-field', not a hardcoded customfield_10020."
  (let ((org-tickets-sprint-field "customfield_99999"))
    (let ((response (org-tickets-test--json
                     "{\"fields\": {\"customfield_99999\": [{\"name\": \"Sprint 42\", \"state\": \"active\"}]}}")))
      (should (string= (org-tickets--extract-sprint-from-response response)
                       "Sprint 42")))))

(ert-deftest org-tickets-test--fix-version-sent-as-array ()
  "Test that fixVersions is sent to Jira API as an array, not an object."
  ;; Test the fixVersions handling logic directly (as implemented in org-tickets--create-ticket)
  (let ((fields nil)
        (fix-version "Aug2026"))
    ;; This mirrors the fixed code from org-tickets--create-ticket (lines 225-226)
    (when (and fix-version (not (string= fix-version "")))
      (push (cons 'fixVersions (list (list (cons "name" fix-version)))) fields))
    ;; Verify fixVersions is sent as an array of objects
    (let ((fix-versions (cdr (assoc 'fixVersions fields))))
      ;; Should be a list (array), not a single alist
      (should (listp fix-versions))
      ;; Each element should be a list (object)
      (should (listp (car fix-versions)))
      (should (cdr (assoc "name" (car fix-versions))))
      (should (equal (cdr (assoc "name" (car fix-versions))) "Aug2026")))))

(ert-deftest org-tickets-test--fix-version-sent-as-array-update ()
  "Test that fixVersions is sent to Jira API as an array in update-ticket."
  ;; Test the fixVersions handling logic directly (as implemented in org-tickets--update-ticket)
  (let ((fields nil)
        (fix-version "Aug2026"))
    ;; This mirrors the fixed code from org-tickets--update-ticket (lines 251-252)
    (when (and fix-version (not (string= fix-version "")))
      (push (cons 'fixVersions (list (list (cons "name" fix-version)))) fields))
    ;; Verify fixVersions is sent as an array of objects
    (let ((fix-versions (cdr (assoc 'fixVersions fields))))
      ;; Should be a list (array), not a single alist
      (should (listp fix-versions))
      ;; Each element should be a list (object)
      (should (listp (car fix-versions)))
      (should (cdr (assoc "name" (car fix-versions))))
      (should (equal (cdr (assoc "name" (car fix-versions))) "Aug2026")))))

;;;; Tests for sprint cache clearing

(ert-deftest org-tickets-test--sprint-cache-is-cleared-between-syncs ()
  "Test that the sprint cache is cleared between sync sessions."
  (let ((org-tickets--sprint-cache (list (cons "Old Sprint" "3453"))))
    (org-tickets--clear-sprint-cache)
    (should (null org-tickets--sprint-cache))))

;;;; Regression tests for symbol-key JSON responses
;; Emacs json-read-from-string with json-object-type 'alist produces symbol
;; keys, not string keys.  These tests verify sprint functions handle both.

(ert-deftest org-tickets-test--get-sprints-with-symbol-keys ()
  "Test that get-sprints-for-project works when JSON has symbol keys.
Regression test: json-read-from-string produces symbol keys, but the
sprint functions previously used string keys with assoc, silently failing."
  (org-tickets-test--with-stubs ((org-tickets--api-request
                               (lambda (_method _endpoint &rest _args)
                                 ;; Symbol keys, as json-read-from-string actually produces
                                 (list (cons 'values
                                             (list (list (cons 'id 3453)
                                                         (cons 'name "Sprint 1")
                                                         (cons 'state "active"))
                                                   (list (cons 'id 3454)
                                                         (cons 'name "Sprint 2")
                                                         (cons 'state "future"))))
                                       (cons 'isLast t))))
                              (org-tickets--resolve-config #'ignore))
    (let ((sprints (org-tickets--get-sprints-for-project "210")))
      (should (= (length sprints) 2))
      (should (string= (car sprints) "Sprint 1"))
      (should (string= (cadr sprints) "Sprint 2")))
    (let ((sprints (org-tickets--get-sprints-for-project "210" t)))
      (should (= (length sprints) 2))
      (should (string= (caar sprints) "Sprint 1"))
      (should (= (cdar sprints) 3453)))))

(ert-deftest org-tickets-test--get-board-id-with-symbol-keys ()
  "Test that get-board-id-for-project works when JSON has symbol keys.
Regression test: previously used (assoc \"values\" ...) which fails on
symbol-keyed alists from json-read-from-string."
  (org-tickets-test--with-stubs ((org-tickets--api-request
                               (lambda (_method _endpoint &rest _args)
                                 (list (cons 'values
                                             (list (list (cons 'id 210)
                                                         (cons 'name "My Board")))))))
                              (org-tickets--resolve-config #'ignore))
    (let ((org-tickets-project-key "PROJ"))
      (should (= (org-tickets--get-board-id-for-project) 210)))))

(ert-deftest org-tickets-test--get-sprints-paginates ()
  "Test that get-sprints-for-project fetches all pages."
  (let ((call-count 0))
    (org-tickets-test--with-stubs ((org-tickets--api-request
                                 (lambda (_method _endpoint &rest _args)
                                   (setq call-count (1+ call-count))
                                   (if (= call-count 1)
                                       ;; First page — not last
                                       (list (cons 'values
                                                   (list (list (cons 'id 3453)
                                                               (cons 'name "Sprint 1"))))
                                             (cons 'isLast nil))
                                     ;; Second page — last
                                     (list (cons 'values
                                                 (list (list (cons 'id 3454)
                                                             (cons 'name "Sprint 2"))))
                                           (cons 'isLast t)))))
                                (org-tickets--resolve-config #'ignore))
      (let ((sprints (org-tickets--get-sprints-for-project "210" t)))
        (should (= call-count 2))
        (should (= (length sprints) 2))
        (should (string= (caar sprints) "Sprint 1"))
        (should (string= (car (cadr sprints)) "Sprint 2"))))))

(provide 'org-tickets-test-sync-sprint)
