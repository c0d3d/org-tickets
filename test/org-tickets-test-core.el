;;; org-tickets-test-core.el --- Tests for org-tickets core configuration  -*- lexical-binding: t; -*-

;;; Commentary:

;; Required configuration accessors and the parent/child issue type
;; predicates from org-tickets-core.el.

;;; Code:

(require 'ert)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; Configuration

(defun org-tickets-test--config-error (fn)
  "Return the `user-error' message FN signals."
  (cadr (should-error (funcall fn) :type 'user-error)))

(ert-deftest org-tickets-test--project-key-unset-names-variable ()
  "An unset or blank project key is a user-error naming the variable."
  (dolist (value '(nil "" "  "))
    (let ((org-tickets-project-key value))
      (should (string-match-p "org-tickets-project-key"
                              (org-tickets-test--config-error
                               #'org-tickets--project-key))))))

(ert-deftest org-tickets-test--project-id-unset-names-variable ()
  "An unset or blank project id is a user-error naming the variable."
  (dolist (value '(nil "" "  "))
    (let ((org-tickets-project-id value))
      (should (string-match-p "org-tickets-project-id"
                              (org-tickets-test--config-error
                               #'org-tickets--project-id))))))

(ert-deftest org-tickets-test--base-url-unset-names-variable ()
  "An unset or blank base URL is a user-error naming the variable."
  (dolist (value '(nil ""))
    (let ((org-tickets-base-url value))
      (should (string-match-p "org-tickets-base-url"
                              (org-tickets-test--config-error
                               #'org-tickets--base-url))))))

(ert-deftest org-tickets-test--config-values-returned-when-set ()
  "Set configuration values come back unchanged."
  (let ((org-tickets-project-key "PROJ")
        (org-tickets-project-id "12345")
        (org-tickets-base-url "https://x.test"))
    (should (equal (org-tickets--project-key) "PROJ"))
    (should (equal (org-tickets--project-id) "12345"))
    (should (equal (org-tickets--base-url) "https://x.test"))))

(ert-deftest org-tickets-test--base-url-drops-trailing-slashes ()
  "A base URL ending in slashes yields one without them."
  (let ((org-tickets-base-url "https://x.test//"))
    (should (equal (org-tickets--base-url) "https://x.test"))))

;;;; Issue type predicates

(ert-deftest org-tickets-test--parent-type-p-recognizes-parent-types ()
  "Only the listed parent types are parents; other values are not."
  (dolist (type '("Feature" "New Feature" "Improvement" "Epic"))
    (should (eq (org-tickets--parent-type-p type) t)))
  (dolist (type '("Story" "feature" "" nil Feature))
    (should-not (org-tickets--parent-type-p type))))

(ert-deftest org-tickets-test--child-type-p-rejects-blank-and-parents ()
  "Blank, non-string and parent types are not children; anything else is."
  (dolist (type '("" "  " nil Story "Feature" "Epic"))
    (should-not (org-tickets--child-type-p type)))
  (dolist (type '("Story" "Task" "Merge" "Sub-task"))
    (should (org-tickets--child-type-p type))))

(provide 'org-tickets-test-core)

;;; org-tickets-test-core.el ends here
