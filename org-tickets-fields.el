;;; org-tickets-fields.el --- Unified Jira payload field builder  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Neil Locketz

;; Author: Neil Locketz <neil@nlocketz.com>
;; Keywords: outlines, comm, tools

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

;; Unified Jira payload field builder for org-tickets.
;; Builds the `fields' alist for both create (POST) and update (PUT)
;; requests from a single `org-tickets--ticket' struct, replacing the
;; duplicated builders that used to live in org-tickets-sync-phases.el and
;; org-tickets-api.el.

;;; Code:

(require 'org-tickets-core)

(declare-function org-tickets--build-adf-description "org-tickets-convert")
(declare-function org-tickets--resolve-sprint-value "org-tickets-api")

;; A clearing value is the `:json-null' sentinel, since nil means "field
;; absent".  `org-tickets--encode-request-data' (org-tickets-api.el) binds
;; `json-null' so the sentinel serializes to JSON null.

(defun org-tickets--field-present-p (value)
  "Non-nil when VALUE is a non-empty string."
  (and (stringp value) (> (length value) 0)))

(defun org-tickets--maybe-push-default-sprint (fields)
  "Push the default sprint onto FIELDS when configured.  Returns FIELDS."
  (let ((sprint-id (org-tickets--resolve-sprint-value
                    org-tickets-default-sprint)))
    (when sprint-id
      (push (cons (intern org-tickets-sprint-field) sprint-id) fields)))
  fields)

(defun org-tickets--create-only-fields (ticket)
  "Return the create-only fields for TICKET, in push (reversed) order.
These are project, issuetype (\"Feature\" maps to \"New Feature\") and the
default sprint.  Signals an error for an unknown issue type."
  (let* ((type (org-tickets--ticket-type ticket))
         (jira-type (if (string= type "Feature") "New Feature" type))
         (issue-type-id (cdr (assoc jira-type org-tickets--issue-type-ids)))
         (fields nil))
    (unless issue-type-id
      (error "Unknown issue type %S (known types: %S)"
             jira-type (mapcar #'car org-tickets--issue-type-ids)))
    (push (cons 'project (list (cons "id" (org-tickets--project-id)))) fields)
    (push (cons 'issuetype (list (cons "id" issue-type-id))) fields)
    (org-tickets--maybe-push-default-sprint fields)))

(defun org-tickets--clearable-fields (ticket create-p)
  "Return the labels and story-points fields for TICKET, in push order.
Unless CREATE-P, an emptied labels property yields an empty array and an
emptied story-points property yields `:json-null' so Jira clears them."
  (let ((fields nil)
        (labels (org-tickets--ticket-labels ticket))
        (story-points (org-tickets--ticket-story-points ticket)))
    (cond
     (labels (push (cons 'labels labels) fields))
     ((org-tickets--ticket-clear-labels ticket)
      (push (cons 'labels (vector)) fields)))
    (cond
     ((and (numberp story-points) (> story-points 0))
      (push (cons (intern org-tickets-story-points-field) story-points) fields))
     ((and (not create-p) (org-tickets--ticket-clear-story-points ticket))
      (push (cons (intern org-tickets-story-points-field) :json-null) fields)))
    fields))

(defun org-tickets--ticket-fields (ticket &rest args)
  "Build the Jira `fields' alist for TICKET.

ARGS is a plist accepting :create-p and :attachments.

With CREATE-P, include create-only fields: project, issuetype (with
\"Feature\" mapped to \"New Feature\") and the configured default
sprint.  ATTACHMENTS is Jira attachment metadata for resolving
attachment: links in the description.

Deliberately NEVER sets Jira's `parent' (issue-hierarchy) field: a
Story→Feature relationship is modeled purely as a \"Blocks\" issue
link (child blocks parent) in `org-tickets--async-sync-ticket-links'.
Setting the real parent field requires a Premium plan and is not the
relationship this tool intends -- do not re-add it here.  See
docs/dev/links.md.

On update (CREATE-P nil), org-absent fields are omitted;
`clear-labels' emits an empty array and `clear-story-points' emits
JSON null so emptied org properties actually clear in Jira."
  (let* ((create-p (plist-get args :create-p))
         (attachments (plist-get args :attachments))
         (fields (and create-p (org-tickets--create-only-fields ticket)))
         (summary (org-tickets--ticket-summary ticket))
         (description (org-tickets--ticket-description ticket))
         (fix-version (org-tickets--ticket-fix-version ticket))
         (due-date (org-tickets--ticket-due-date ticket)))
    (when summary
      (push (cons 'summary summary) fields))
    (when (org-tickets--field-present-p description)
      (let ((adf (org-tickets--build-adf-description description attachments)))
        (when adf
          (push (cons 'description adf) fields))))
    (when (org-tickets--field-present-p fix-version)
      (push (cons 'fixVersions (list (list (cons "name" fix-version)))) fields))
    (setq fields (append (org-tickets--clearable-fields ticket create-p) fields))
    (when (org-tickets--field-present-p due-date)
      (push (cons 'duedate due-date) fields))
    (nreverse fields)))

(provide 'org-tickets-fields)
;;; org-tickets-fields.el ends here
