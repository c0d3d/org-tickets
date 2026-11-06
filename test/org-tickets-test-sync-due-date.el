;;; org-tickets-test-sync-due-date.el --- Tests for org-tickets due date sync  -*- lexical-binding: t; -*-

(require 'ert)
(require 'org)
(require 'org-element)

(require 'org-tickets)
(require 'org-tickets-test-fixtures)

(defun org-tickets-test--created-due-date (due-date)
  "Create a story with DUE-DATE against a fake Jira; return the sent duedate."
  (let ((requests nil))
    (org-tickets-test--with-fake-api
        (org-tickets-test--fake-jira-handler :post-keys '("PROJ-9") :log requests)
      (org-tickets--create-ticket
       (org-tickets--ticket-create :type "Story" :summary "S" :due-date due-date)))
    (org-tickets-test--payload-field
     (nth 2 (car (org-tickets-test--requests requests "POST" "/rest/api/3/issue")))
     'duedate)))

(ert-deftest org-tickets-test--due-date-sent-in-create ()
  "Creating a ticket with a due date POSTs it as duedate."
  (should (equal (org-tickets-test--created-due-date "2026-06-15") "2026-06-15")))

(ert-deftest org-tickets-test--due-date-not-sent-when-absent ()
  "Creating a ticket with no, or an empty, due date sends no duedate."
  (should-not (org-tickets-test--created-due-date nil))
  (should-not (org-tickets-test--created-due-date "")))

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

(ert-deftest org-tickets-test--due-date-inheritance-external-parent-without-date ()
  "An external parent with no due date in Jira leaves the child unset."
  (org-tickets-test--with-stubs
      ((org-tickets--get-ticket (lambda (_key) (org-tickets-test--make-get-response))))
    (with-temp-buffer
      (insert "* My Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:PARENT: PROJ-500
:END:
")
      (org-mode)
      (org-tickets--inherit-due-date "PROJ-200" "PROJ-500")
      (goto-char (point-min))
      (re-search-forward "PROJ-200" nil t)
      (should-not (org-entry-get (point) "DUE_DATE")))))

(ert-deftest org-tickets-test--due-date-inherited-from-external-parent ()
  "A parent absent from the buffer supplies its due date from Jira."
  (org-tickets-test--with-stubs
      ((org-tickets--get-ticket
        (lambda (_key) (org-tickets-test--make-get-response nil "2026-11-01"))))
    (with-temp-buffer
      (insert "* My Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:PARENT: PROJ-500
:END:
")
      (org-mode)
      (org-tickets--inherit-due-date "PROJ-200" "PROJ-500")
      (goto-char (point-min))
      (re-search-forward "PROJ-200" nil t)
      (should (equal (org-entry-get (point) "DUE_DATE") "2026-11-01")))))

(provide 'org-tickets-test-sync-due-date)

;;; org-tickets-test-sync-due-date.el ends here
