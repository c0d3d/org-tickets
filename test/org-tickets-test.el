;;; org-tickets-test.el --- Test aggregator for org-tickets  -*- lexical-binding: t; -*-

;; This file aggregates all org-tickets tests.
;; Load this file to run all tests, or load individual test files for specific suites.

(require 'ert)

;; Load all test modules
(require 'org-tickets)
(require 'org-tickets-test-fixtures)
(require 'org-tickets-test-parse)
(require 'org-tickets-test-sync)
(require 'org-tickets-test-sync-links)
(require 'org-tickets-test-sync-sprint)
(require 'org-tickets-test-sync-due-date)
(require 'org-tickets-test-inheritance)
(require 'org-tickets-test-convert)
(require 'org-tickets-test-convert-nodes)
(require 'org-tickets-test-import)
(require 'org-tickets-test-attachments-upload)
(require 'org-tickets-test-attachments-sync)
(require 'org-tickets-test-macro)
(require 'org-tickets-test-cmd)
(require 'org-tickets-test-async)
(require 'org-tickets-test-sync-flow)
(require 'org-tickets-test-attachments-async)
(require 'org-tickets-test-roundtrip)
(require 'org-tickets-test-headings-push)
(require 'org-tickets-test-headings-pull)
(require 'org-tickets-test-cmd-ticket-at-point)
(require 'org-tickets-test-list-continuation)
(require 'org-tickets-test-ordered-start)
(require 'org-tickets-test-fields)
(require 'org-tickets-test-sync-flow-phase2)
(require 'org-tickets-test-record)
(require 'org-tickets-test-options)
(require 'org-tickets-test-api)

;;;; API Sprint tests

(ert-deftest org-tickets-test--get-sprints ()
  "Test fetching available sprints for a project."
  (let* ((org-tickets-base-url "https://test.atlassian.net")
         (org-tickets-project-key "TEST")
         (org-tickets-project-id "12345")
         (api-response
          (org-tickets-test--json
           "{\"values\": [{\"id\": 3453, \"name\": \"Sprint 1\", \"state\": \"active\"}, {\"id\": 3454, \"name\": \"Sprint 2\", \"state\": \"future\"}], \"isLast\": true}")))
    (org-tickets-test--with-stubs ((org-tickets--resolve-config #'ignore)
                                (org-tickets--api-request
                                 (lambda (method endpoint &rest args)
                                   api-response)))
      (let ((sprints (mapcar #'car (org-tickets--fetch-board-sprints "210"))))
        (should (equal (length sprints) 2))
        (should (equal (car sprints) "Sprint 1"))))))

(ert-deftest org-tickets-test--get-sprints-paginates-past-json-false ()
  "isLast=false parses to :json-false (truthy!) — pagination must not stop."
  (let ((pages (list (org-tickets-test--json
                      "{\"isLast\": false, \"values\": [{\"id\": 1, \"name\": \"S1\"}]}")
                     (org-tickets-test--json
                      "{\"isLast\": true, \"values\": [{\"id\": 2, \"name\": \"S2\"}]}")))
        (calls 0))
    (org-tickets-test--with-stubs ((org-tickets--resolve-config #'ignore)
                                (org-tickets--api-request
                                 (lambda (_method _endpoint &rest _)
                                   (setq calls (1+ calls))
                                   (pop pages))))
      (let ((sprints (mapcar #'car (org-tickets--fetch-board-sprints "210"))))
        (should (= calls 2))
        (should (equal sprints '("S1" "S2")))))))

(ert-deftest org-tickets-test--resolve-sprint-id-looks-up-by-name ()
  "Test that resolve-sprint-id correctly maps a sprint name to its ID.
The cache is built as ((name . id) ...). Lookup must search by name."
  (let ((org-tickets--sprint-cache
         (list (cons "Test Sprint" "3453")
               (cons "Next Sprint" "3454"))))
    (should (string= (org-tickets--resolve-sprint-id "Test Sprint") "3453"))
    (should (string= (org-tickets--resolve-sprint-id "Next Sprint") "3454"))
    (should (null (org-tickets--resolve-sprint-id "Nonexistent Sprint")))))

(ert-deftest org-tickets-test--api-request-encodes-unicode ()
  "Test that unicode characters are correctly encoded in API requests.
Regression test: Jira's REST API requires UTF-8 encoding. The request
data path uses (encode-coding-string (json-encode data) 'utf-8)."
  (let* ((data (list (cons 'fields
                           (list (cons "summary" "Café résumé — español")
                                 (cons "description" (list (cons "type" "doc")
                                                           (cons "content" nil)))))))
         (json-string (json-encode data))
         (encoded (encode-coding-string json-string 'utf-8)))
    ;; The JSON string (before byte-encoding) should contain the unicode chars
    (should (string-match-p "Café" json-string))
    (should (string-match-p "résumé" json-string))
    (should (string-match-p "español" json-string))
    ;; encode-coding-string should produce a longer byte string for multibyte chars
    (should (> (length encoded) (length json-string)))
    ;; JSON-encode should produce valid JSON
    (should json-string)
    (should (> (length json-string) 0))
    ;; Re-decode to verify it's valid JSON
    (let ((json-object-type 'alist))
      (should (json-read-from-string json-string)))))

(provide 'org-tickets-test)
