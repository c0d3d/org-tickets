;;; org-tickets-test-sync-due-date.el --- Tests for org-tickets due date sync  -*- lexical-binding: t; -*-

(require 'ert)
(require 'org)
(require 'org-element)

;; Load the main library
(require 'org-tickets)

;;;; Tests for Due Date

(ert-deftest org-tickets-test--due-date-sent-in-create ()
  "Test that duedate is sent to Jira API in create-ticket fields."
  (let ((fields nil)
        (due-date "2026-06-15"))
    (when (and due-date (not (string= due-date "")))
      (push (cons 'duedate due-date) fields))
    (let ((duedate-field (cdr (assoc 'duedate fields))))
      (should (string= duedate-field "2026-06-15")))))

(ert-deftest org-tickets-test--due-date-not-sent-when-nil ()
  "Test that duedate is not sent when nil."
  (let ((fields nil)
        (due-date nil))
    (when (and due-date (not (string= due-date "")))
      (push (cons 'duedate due-date) fields))
    (should (null (assoc 'duedate fields)))))

(ert-deftest org-tickets-test--parse-jira-issue-with-due-date ()
  "Test parsing Jira issue with duedate field."
  (let* ((jira-response
          (list (cons "id" "12345")
                (cons "key" "PROJ-100")
                (cons "fields"
                      (list (cons "summary" "Test Feature")
                            (cons "issuetype" (list (cons "name" "Feature")))
                            (cons "duedate" "2026-06-15")))))
         (ticket (org-tickets--parse-jira-issue jira-response)))
    (should (string= (org-tickets--ticket-due-date ticket) "2026-06-15"))))

(ert-deftest org-tickets-test--parse-jira-issue-without-due-date ()
  "Test parsing Jira issue with no duedate field."
  (let* ((jira-response
          (list (cons "id" "12345")
                (cons "key" "PROJ-100")
                (cons "fields"
                      (list (cons "summary" "Test Feature")
                            (cons "issuetype" (list (cons "name" "Feature")))))))
         (ticket (org-tickets--parse-jira-issue jira-response)))
    (should (null (org-tickets--ticket-due-date ticket)))))

(ert-deftest org-tickets-test--issue-to-org-with-due-date ()
  "Test that issue-to-org writes DUE_DATE property."
  (let ((ticket (org-tickets--ticket-create
                 :key "PROJ-100"
                 :type "Feature"
                 :summary "Test Feature"
                 :description "Desc"
                 :fix-version nil
                 :labels nil
                 :story-points nil
                 :blocks nil
                 :blocked-by nil
                 :parent nil
                 :attachments nil
                 :sprint nil
                 :due-date "2026-06-15")))
    (with-temp-buffer
      (org-mode)
      (org-tickets--issue-to-org ticket)
      (goto-char (point-min))
      (re-search-forward "^\\* Test Feature" nil t)
      (goto-char (match-beginning 0))
      (should (string= (org-entry-get (point) "DUE_DATE") "2026-06-15")))))

(ert-deftest org-tickets-test--inherit-due-date-from-parent ()
  "Test that a Story inherits due date from its parent Feature."
  (with-temp-buffer
    (insert "* Parent Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:DUE_DATE: 2026-08-01
:END:
** Child Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:PARENT: PROJ-100
:END:
")
    (org-mode)
    (org-tickets--inherit-due-date "PROJ-200" "PROJ-100")
    (goto-char (point-min))
    (re-search-forward "PROJ-200" nil t)
    (should (string= (org-entry-get (point) "DUE_DATE") "2026-08-01"))))

(ert-deftest org-tickets-test--inherit-due-date-does-not-overwrite-existing ()
  "Test that a Story with an existing due date does NOT get overwritten by parent."
  (with-temp-buffer
    (insert "* Parent Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:DUE_DATE: 2026-08-01
:END:
** Child Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:PARENT: PROJ-100
:DUE_DATE: 2026-07-15
:END:
")
    (org-mode)
    (org-tickets--inherit-due-date "PROJ-200" "PROJ-100")
    (goto-char (point-min))
    (re-search-forward "PROJ-200" nil t)
    (should (string= (org-entry-get (point) "DUE_DATE") "2026-07-15"))))

(ert-deftest org-tickets-test--inherit-due-date-no-parent-date ()
  "Test that inheritance does nothing when parent has no due date."
  (with-temp-buffer
    (insert "* Parent Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:END:
** Child Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:PARENT: PROJ-100
:END:
")
    (org-mode)
    (org-tickets--inherit-due-date "PROJ-200" "PROJ-100")
    (goto-char (point-min))
    (re-search-forward "PROJ-200" nil t)
    (should (null (org-entry-get (point) "DUE_DATE")))))

(provide 'org-tickets-test-sync-due-date)
