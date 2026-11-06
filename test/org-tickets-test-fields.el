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

(provide 'org-tickets-test-fields)
;;; org-tickets-test-fields.el ends here
