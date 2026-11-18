;;; org-tickets-test-conflict.el --- Tests for foreign change classification  -*- lexical-binding: t; -*-

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

;; Tests for Jira time comparison, foreign change detection, conflict
;; descriptions and metadata pulls.

;;; Code:

(require 'ert)
(require 'org-tickets-test-fixtures)
(require 'org-tickets)

(defconst org-tickets-test--since "2026-11-18T10:00:00.000+0000"
  "Baseline timestamp used by the foreign change tests.")

(defconst org-tickets-test--after "2026-11-18T10:05:00.000+0000"
  "A timestamp after `org-tickets-test--since'.")

(ert-deftest org-tickets-test--jira-time-later-p-compares-across-offsets ()
  "Timestamps are compared as instants, not strings."
  (let ((a "2026-11-18T10:00:00.000-0500")
        (b "2026-11-18T14:30:00.000+0000"))
    (should (org-tickets--jira-time-later-p a b))
    (should-not (org-tickets--jira-time-later-p b a))
    (should-not (org-tickets--jira-time-later-p a a))))

(ert-deftest org-tickets-test--jira-time-later-p-honours-milliseconds ()
  "Timestamps within the same second still order correctly."
  (should (org-tickets--jira-time-later-p "2026-11-18T10:00:00.500+0000"
                                          "2026-11-18T10:00:00.100+0000")))

(ert-deftest org-tickets-test--foreign-changes-ignores-my-edits ()
  "Changes authored by the current account are not foreign."
  (let ((response (org-tickets-test--issue-response
                   :histories `(("me" "Me" ,org-tickets-test--after "labels")))))
    (should-not (org-tickets--foreign-changes
                 response "me" org-tickets-test--since))))

(ert-deftest org-tickets-test--foreign-changes-ignores-edits-at-or-before-baseline ()
  "Edits created at or before the baseline are already accounted for."
  (let ((response (org-tickets-test--issue-response
                   :histories `(("bob" "Bob" ,org-tickets-test--since "labels")
                                ("bob" "Bob" "2026-11-18T09:00:00.000+0000"
                                 "summary")))))
    (should-not (org-tickets--foreign-changes
                 response "me" org-tickets-test--since))))

(ert-deftest org-tickets-test--foreign-changes-lists-each-item ()
  "Every changelog item of a later foreign history is listed."
  (let* ((response (org-tickets-test--issue-response
                    :histories `(("bob" "Bob" ,org-tickets-test--after
                                  "labels" "description"))))
         (changes (org-tickets--foreign-changes
                   response "me" org-tickets-test--since)))
    (should (equal (sort (copy-sequence changes)
                         (lambda (a b) (string< (car a) (car b))))
                   '(("description" . "Bob") ("labels" . "Bob"))))))

(ert-deftest org-tickets-test--content-change-p ()
  "Only summary and description count as content changes."
  (should (org-tickets--content-change-p '("summary" . "Bob")))
  (should (org-tickets--content-change-p '("description" . "Bob")))
  (should-not (org-tickets--content-change-p '("labels" . "Bob")))
  (should-not (org-tickets--content-change-p '("customfield_10020" . "Bob"))))

(ert-deftest org-tickets-test--conflict-line-lists-content-only ()
  "The conflict line names content changes and skips other fields."
  (should (equal (org-tickets--conflict-line
                  "PROJ-12" '(("labels" . "Bob") ("summary" . "Alice")
                              ("description" . "Bob")))
                 "PROJ-12: summary changed by Alice, description changed by Bob")))

(ert-deftest org-tickets-test--conflict-line-names-unknown-author-someone ()
  "A change without an author name is attributed to \"someone\"."
  (should (equal (org-tickets--conflict-line "PROJ-12" '(("summary")))
                 "PROJ-12: summary changed by someone")))

(ert-deftest org-tickets-test--foreign-changes-names-link-items-by-field ()
  "An issue-link item without a fieldId is named by its field, \"Link\"."
  (let ((response (org-tickets-test--issue-response
                   :histories `(("bob" "Bob" ,org-tickets-test--after
                                 (field . "Link"))))))
    (should (equal (org-tickets--foreign-changes
                    response "me" org-tickets-test--since)
                   '(("Link" . "Bob"))))))

(ert-deftest org-tickets-test--changed-properties-maps-tracked-fields ()
  "Tracked Jira fields map to their org properties; others to none."
  (let ((org-tickets-sprint-field "customfield_1")
        (org-tickets-story-points-field "customfield_2"))
    (should (equal (sort (org-tickets--changed-properties
                          '("labels" "fixVersions" "duedate" "issuetype"
                            "customfield_1" "customfield_2" "Link"))
                         #'string<)
                   '("BLOCKED-BY" "BLOCKS" "DUE_DATE" "FIX_VERSION"
                     "JIRA_TYPE" "LABELS" "SPRINT" "STORY_POINTS")))
    (should-not (org-tickets--changed-properties
                 '("status" "assignee" "Rank" "resolution" nil)))))

(defmacro org-tickets-test--with-heading (properties &rest body)
  "Run BODY at a temp org heading \"Old title\" with PROPERTIES.
PROPERTIES is an alist of (NAME . VALUE); the body text is \"Local body\"."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert "* Old title\n:PROPERTIES:\n"
             (mapconcat (lambda (p) (format ":%s: %s\n" (car p) (cdr p)))
                        ,properties "")
             ":END:\nLocal body\n")
     (goto-char (point-min))
     ,@body))

(defun org-tickets-test--pull-response ()
  "Return an issue response with a new title, label and description."
  (let ((response (org-tickets-test--issue-response
                   :summary "New title" :labels '("b"))))
    (append '((key . "PROJ-12")) response)))

(ert-deftest org-tickets-test--pull-metadata-updates-properties-not-content ()
  "Metadata is refreshed while headline, body and JIRA_SYNCED stay put."
  (org-tickets-test--with-heading '(("LABELS" . "a") ("JIRA_SYNCED" . "X"))
    (org-tickets--pull-ticket-metadata (org-tickets-test--pull-response)
                                       '("LABELS"))
    (should (equal (org-entry-get (point) "LABELS") "b"))
    (should (equal (org-entry-get (point) "JIRA_SYNCED") "X"))
    (should (equal (org-get-heading t t t t) "Old title"))
    (should (string-match-p "Local body" (buffer-string)))
    (should-not (string-match-p "New title" (buffer-string)))))

(ert-deftest org-tickets-test--pull-metadata-keeps-local-parent ()
  "A local PARENT survives a pull from an issue without a parent field."
  (org-tickets-test--with-heading '(("PARENT" . "PROJ-1"))
    (org-tickets--pull-ticket-metadata (org-tickets-test--pull-response)
                                       '("LABELS"))
    (should (equal (org-entry-get (point) "PARENT") "PROJ-1"))))

(ert-deftest org-tickets-test--pull-metadata-adds-no-empty-parent ()
  "A heading without PARENT does not gain an empty one."
  (org-tickets-test--with-heading '(("LABELS" . "a"))
    (org-tickets--pull-ticket-metadata (org-tickets-test--pull-response)
                                       '("LABELS"))
    (should-not (org-entry-get (point) "PARENT"))))

(ert-deftest org-tickets-test--pull-metadata-keeps-unchanged-properties ()
  "Properties not named for the pull keep their local values or absence."
  (org-tickets-test--with-heading '(("LABELS" . "a") ("STORY_POINTS" . "3"))
    (org-tickets--pull-ticket-metadata (org-tickets-test--pull-response)
                                       '("LABELS"))
    (should (equal (org-entry-get (point) "LABELS") "b"))
    (should (equal (org-entry-get (point) "STORY_POINTS") "3"))
    (should-not (org-entry-get (point) "SPRINT"))
    (should-not (org-entry-get (point) "FIX_VERSION"))))

(provide 'org-tickets-test-conflict)
;;; org-tickets-test-conflict.el ends here
