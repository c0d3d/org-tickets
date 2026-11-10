;;; org-tickets-test-fields.el --- Tests for the unified field builder  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Neil Locketz

;; Author: Neil Locketz <neil@nlocketz.com>
;; Keywords: org, jira, tests

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Tests for `org-tickets-fields.el' — the unified Jira payload builder
;; (org-tickets--ticket-fields), covering create vs. update field sets and
;; the clearing semantics for LABELS / STORY_POINTS.  Split out of
;; org-tickets-test-sync-flow.el to keep that file under the line limit
;; (see docs/dev/testing.md: split by module tested).

;;; Code:

(require 'ert)
(require 'org-tickets-test-fixtures)

(require 'org-tickets)

;;;; Tests: Unified Field Builder (org-tickets-fields.el)

(defun org-tickets-test--fields-get (fields name)
  "Fetch NAME (string) from a payload FIELDS alist with symbol keys."
  (cdr (assq (intern name) fields)))

(ert-deftest org-tickets-test--ticket-fields-update-basic ()
  "An update payload carries every ticket field but none of the create-only ones."
  (let* ((ticket (org-tickets--ticket-create
                  :key "P-1" :type "Story" :summary "S"
                  :description "body" :fix-version "Aug2026"
                  :labels '("x") :story-points 3 :due-date "2026-08-01"))
         (fields (org-tickets--ticket-fields ticket)))
    (should (equal (org-tickets-test--fields-get fields "summary") "S"))
    (should (org-tickets-test--fields-get fields "description"))
    (should (equal (org-tickets-test--fields-get fields "labels") '("x")))
    (should (= (org-tickets-test--fields-get fields "customfield_10016") 3))
    (should (equal (org-tickets-test--fields-get fields "duedate") "2026-08-01"))
    ;; Update payloads never carry create-only fields.
    (should-not (org-tickets-test--fields-get fields "project"))
    (should-not (org-tickets-test--fields-get fields "issuetype"))
    (should-not (org-tickets-test--fields-get fields "parent"))))

(ert-deftest org-tickets-test--ticket-fields-create-omits-jira-parent-field ()
  "Regression: a create payload must NEVER carry Jira's `parent' field,
even for a Story that has a parent.  Parent relationships are modeled
as \"Blocks\" issue links (child blocks parent); setting the real
parent field requires a Premium plan and is not the intended
relationship.  Guards against reintroducing the parent push."
  (let* ((org-tickets-project-id "12345")
         (org-tickets--issue-type-ids '(("Story" . "1") ("New Feature" . "2")))
         (ticket (org-tickets--ticket-create :type "Story" :summary "S" :parent "P-7"))
         (fields (org-tickets--ticket-fields ticket :create-p t)))
    (should (equal (org-tickets-test--fields-get fields "project") '(("id" . "12345"))))
    (should (equal (org-tickets-test--fields-get fields "issuetype") '(("id" . "1"))))
    (should-not (org-tickets-test--fields-get fields "parent"))))

(ert-deftest org-tickets-test--ticket-fields-feature-maps-to-new-feature ()
  "A Feature ticket is created with the \"New Feature\" issue type id."
  (let* ((org-tickets-project-id "12345")
         (org-tickets--issue-type-ids '(("New Feature" . "2")))
         (fields (org-tickets--ticket-fields
                  (org-tickets--ticket-create :type "Feature" :summary "F")
                  :create-p t)))
    (should (equal (org-tickets-test--fields-get fields "issuetype") '(("id" . "2"))))))

(ert-deftest org-tickets-test--ticket-fields-unknown-type-errors-clearly ()
  "Creating a ticket whose type has no known issue type id signals an error."
  (let ((org-tickets-project-id "12345")
        (org-tickets--issue-type-ids '(("Story" . "1"))))
    (should-error (org-tickets--ticket-fields
                   (org-tickets--ticket-create :type "Epic" :summary "E")
                   :create-p t))))

(ert-deftest org-tickets-test--ticket-fields-clearing-semantics ()
  "Present-but-empty LABELS clears; story points 0 clears on update."
  (let ((fields (org-tickets--ticket-fields
                 (org-tickets--ticket-create
                  :key "P-1" :type "Story" :summary "S"
                  :labels nil :clear-labels t
                  :story-points 0 :clear-story-points t))))
    (should (equal (org-tickets-test--fields-get fields "labels") []))
    (should (eq (org-tickets-test--fields-get fields "customfield_10016") :json-null))
    ;; Encodes to JSON [] and null — mirrors the `json-null' binding that
    ;; `org-tickets--api-request' uses at the real request encode sites.
    (let ((json-null :json-null))
      (should (string-match-p "\"labels\":\\[\\]" (json-encode fields)))
      (should (string-match-p "\"customfield_10016\":null" (json-encode fields))))))

(ert-deftest org-tickets-test--parse-populates-clear-flags ()
  "An empty LABELS and a zero STORY_POINTS parse as requests to clear those fields."
  (with-temp-buffer
    (org-mode)
    (insert "* T\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-1\n"
            ":LABELS:\n:STORY_POINTS: 0\n:END:\n")
    (let ((tk (car (org-tickets--doc-tickets (org-tickets--parse-document)))))
      (should (org-tickets--ticket-clear-labels tk))
      (should (org-tickets--ticket-clear-story-points tk)))))

;;;; Story points parsing

(defun org-tickets-test--story-points-ticket (value)
  "Parse a keyed Story whose STORY_POINTS property is VALUE.
VALUE nil leaves the property out.  Returns the ticket and the list of
warning messages displayed while parsing, as (TICKET . WARNINGS)."
  (let ((warnings nil))
    (with-temp-buffer
      (org-mode)
      (insert "* T\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-1\n"
              (if value (format ":STORY_POINTS: %s\n" value) "")
              ":END:\n")
      (org-tickets-test--with-stubs
          ((display-warning (lambda (_type message &rest _)
                              (push message warnings))))
        (cons (car (org-tickets--doc-tickets (org-tickets--parse-document)))
              warnings)))))

(defun org-tickets-test--story-points-update (value)
  "Return the update payload fields for a Story with STORY_POINTS VALUE."
  (org-tickets--ticket-fields (car (org-tickets-test--story-points-ticket value))))

(ert-deftest org-tickets-test--non-numeric-story-points-leaves-jira-alone ()
  "A non-numeric STORY_POINTS sends no story points at all on update,
rather than clearing the estimate Jira already holds."
  (let ((fields (org-tickets-test--story-points-update "TBD")))
    (should-not (assq 'customfield_10016 fields))))

(ert-deftest org-tickets-test--non-numeric-story-points-warns-naming-ticket ()
  "A non-numeric STORY_POINTS is reported with the value and the ticket key."
  (let ((warnings (cdr (org-tickets-test--story-points-ticket "TBD"))))
    (should (= 1 (length warnings)))
    (should (string-match-p "TBD" (car warnings)))
    (should (string-match-p "P-1" (car warnings)))))

(ert-deftest org-tickets-test--story-points-zero-and-empty-still-clear ()
  "An explicit 0 or an emptied STORY_POINTS still clears Jira's estimate."
  (dolist (value '("0" ""))
    (should (eq (cdr (assq 'customfield_10016
                           (org-tickets-test--story-points-update value)))
                :json-null))))

(ert-deftest org-tickets-test--story-points-absent-or-numeric ()
  "An absent STORY_POINTS sends nothing; a number (decimals too) is sent."
  (should-not (assq 'customfield_10016 (org-tickets-test--story-points-update nil)))
  (should (= 3 (cdr (assq 'customfield_10016
                          (org-tickets-test--story-points-update "3")))))
  (should (= 2.5 (cdr (assq 'customfield_10016
                            (org-tickets-test--story-points-update "2.5")))))
  (should-not (cdr (org-tickets-test--story-points-ticket "3"))))

;;;; Create-only and clearing fields

(ert-deftest org-tickets-test--default-sprint-on-create-only ()
  "The configured default sprint is set on create and never on update."
  (let ((org-tickets-project-id "12345")
        (org-tickets--issue-type-ids '(("Story" . "1")))
        (org-tickets-default-sprint "Current Sprint")
        (ticket (org-tickets--ticket-create :key "P-1" :type "Story" :summary "S")))
    (org-tickets-test--with-stubs
        ((org-tickets--resolve-sprint-value
          (lambda (sprint) (and (equal sprint "Current Sprint") 42))))
      (should (equal (org-tickets-test--fields-get
                      (org-tickets--ticket-fields ticket :create-p t)
                      org-tickets-sprint-field)
                     42))
      (should-not (assq (intern org-tickets-sprint-field)
                        (org-tickets--ticket-fields ticket))))))

(ert-deftest org-tickets-test--create-never-sends-clearing-values ()
  "Emptied LABELS and STORY_POINTS send nothing on create: there is
nothing in Jira to clear yet."
  (let* ((org-tickets-project-id "12345")
         (org-tickets--issue-type-ids '(("Story" . "1")))
         (fields (org-tickets--ticket-fields
                  (org-tickets--ticket-create
                   :type "Story" :summary "S"
                   :clear-labels t :story-points 0 :clear-story-points t)
                  :create-p t)))
    (should-not (assq 'labels fields))
    (should-not (assq 'customfield_10016 fields))))

;;;; Description clearing

(ert-deftest org-tickets-test--invisible-description-clears-on-update ()
  "A description with no visible content (only a COMMENT subtree)
clears Jira's description on update instead of leaving stale text."
  (let ((ticket (org-tickets--ticket-create
                 :key "P-1" :type "Story" :summary "S"
                 :description "*** COMMENT notes\nprivate")))
    (should (eq (org-tickets-test--fields-get
                 (org-tickets--ticket-fields ticket) "description")
                :json-null))))

(ert-deftest org-tickets-test--invisible-description-omitted-on-create ()
  "A description with no visible content is left out of a create."
  (let* ((org-tickets-project-id "12345")
         (org-tickets--issue-type-ids '(("Story" . "1")))
         (fields (org-tickets--ticket-fields
                  (org-tickets--ticket-create
                   :type "Story" :summary "S"
                   :description "*** COMMENT notes\nprivate")
                  :create-p t)))
    (should-not (assq 'description fields))))

(ert-deftest org-tickets-test--absent-description-omitted-on-update ()
  "A ticket with no description body leaves Jira's description alone."
  (should-not (assq 'description
                    (org-tickets--ticket-fields
                     (org-tickets--ticket-create
                      :key "P-1" :type "Story" :summary "S")))))

(provide 'org-tickets-test-fields)
;;; org-tickets-test-fields.el ends here
