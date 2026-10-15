;;; org-tickets-test-options.el --- Tests for org-tickets workflow options  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for user options that tailor the ticket workflow:
;; `org-tickets-needs-sizing-label' and `org-tickets-fix-version-months'.

;;; Code:

(require 'ert)
(require 'org)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

(defmacro org-tickets-test--with-labeled-ticket (labels &rest body)
  "Run BODY in an Org buffer at ticket PROJ-1 whose LABELS property is LABELS."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert "* Test\n")
     (goto-char (point-min))
     (org-entry-put (point) "JIRA_KEY" "PROJ-1")
     (when ,labels
       (org-entry-put (point) "LABELS" ,labels))
     ,@body))

(ert-deftest org-tickets-test--sizing-label-is-configurable ()
  "A custom sizing label is added when unsized and removed once sized."
  (let ((org-tickets-needs-sizing-label "Unestimated"))
    (org-tickets-test--with-labeled-ticket "Other"
      (org-tickets--update-sizing-label "PROJ-1" nil)
      (should (equal (org-entry-get (point) "LABELS") "Other,Unestimated"))
      (org-tickets--update-sizing-label "PROJ-1" 3)
      (should (equal (org-entry-get (point) "LABELS") "Other")))))

(ert-deftest org-tickets-test--sizing-label-nil-leaves-labels-alone ()
  "With no sizing label configured, labels are never changed."
  (let ((org-tickets-needs-sizing-label nil))
    (org-tickets-test--with-labeled-ticket "NeedsSizing,Other"
      (org-tickets--update-sizing-label "PROJ-1" 3)
      (should (equal (org-entry-get (point) "LABELS") "NeedsSizing,Other"))
      (org-tickets--update-sizing-label "PROJ-1" nil)
      (should (equal (org-entry-get (point) "LABELS") "NeedsSizing,Other")))))

(ert-deftest org-tickets-test--fix-version-months-are-configurable ()
  "Fix Version validation accepts exactly the configured months."
  (let ((org-tickets-fix-version-months '("Jan" "Jul")))
    (should (org-tickets--validate-fix-version "Jul2026"))
    (should-not (org-tickets--validate-fix-version "Aug2026"))))

(provide 'org-tickets-test-options)

;;; org-tickets-test-options.el ends here
