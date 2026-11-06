;;; org-tickets-test-sync-sprint.el --- Tests for org-tickets sprint sync  -*- lexical-binding: t; -*-

(require 'ert)
(require 'org)
(require 'org-element)

;; Load the main library
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

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

;;;; Tests for sprint resolution

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

;;;; Sprint listing API

(provide 'org-tickets-test-sync-sprint)
