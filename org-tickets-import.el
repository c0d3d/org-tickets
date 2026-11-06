;;; org-tickets-import.el --- Import functions for org-tickets  -*- lexical-binding: t; -*-

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

;; Import functions for org-tickets.
;; Contains Jira import and ADF parsing.

;;; Code:

(require 'org-tickets-api)
(require 'org-tickets-convert)
(require 'org-tickets-adf-import)
(require 'org-tickets-parse)

(defun org-tickets--strip-type-prefix (type summary)
  "Return SUMMARY with a leading \"TYPE: \" prefix removed, if present.
Jira often prepends the issue type to the summary; strip it so the org
headline shows only the summary text."
  (if (and type (string-match (concat "^" (regexp-quote type) ": ") summary))
      (substring summary (match-end 0))
    summary))

;;;; Import Functions

(defun org-tickets--parse-issuelinks (issuelinks)
  "Parse ISSUELINKS into a cons (BLOCKS-KEYS . BLOCKED-BY-KEYS).
Only \"Blocks\"-type links contribute: an outwardIssue key is blocked by
this issue, an inwardIssue key blocks it.  Keys are in reverse link
order, matching the historical parse."
  (let ((blocks nil)
        (blocked-by nil))
    (dolist (link issuelinks)
      (let* ((type-info (org-tickets--alist-get "type" link))
             (type-name (org-tickets--alist-get "name" type-info))
             (outward (org-tickets--alist-get "outwardIssue" link))
             (inward (org-tickets--alist-get "inwardIssue" link)))
        (when (string= type-name "Blocks")
          (when outward
            (push (org-tickets--alist-get "key" outward) blocks))
          (when inward
            (push (org-tickets--alist-get "key" inward) blocked-by)))))
    (cons blocks blocked-by)))

(defun org-tickets--build-attachment-id-map (attachments)
  "Build an alist mapping attachment IDs to filenames from ATTACHMENTS.
Indexes each attachment by both its numeric Jira id and its
mediaApiFileId (UUID) so ADF media nodes — which reference the UUID —
resolve to a filename either way."
  (let ((map nil))
    (dolist (att attachments map)
      (let ((id (org-tickets--attachment-id att))
            (filename (org-tickets--attachment-filename att))
            (media-id (org-tickets--attachment-media-id att)))
        (when (and id filename)
          (push (cons id filename) map))
        (when (and media-id filename)
          (push (cons media-id filename) map))))))

(defun org-tickets--parse-description-adf (description-adf key id-map)
  "Parse DESCRIPTION-ADF into org text, or nil when absent or unparsable.
ID-MAP resolves media nodes to attachment filenames.
On a parse error a warning naming ticket KEY is emitted and nil returned."
  (when description-adf
    (condition-case err
        (org-tickets--parse-adf-description description-adf id-map)
      (error
       (display-warning
        'org-tickets
        (format "Failed to parse ADF description for %s: %S" key err)
        :warning)
       nil))))

(defun org-tickets--parse-jira-issue (jira-response)
  "Parse Jira API RESPONSE into an org-tickets--ticket struct.
JIRA-RESPONSE is the parsed JSON response from the Jira REST API."
  (let* ((key (org-tickets--alist-get "key" jira-response))
         (fields (org-tickets--alist-get "fields" jira-response))
         (issuetype (org-tickets--alist-get "issuetype" fields))
         (issuelinks (append (org-tickets--alist-get "issuelinks" fields) nil))
         (links (org-tickets--parse-issuelinks issuelinks))
         (attachments (org-tickets--issue-attachments jira-response))
         (id-map (org-tickets--build-attachment-id-map attachments)))
    (org-tickets--ticket-create
     :key key
     :type (org-tickets--alist-get "name" issuetype)
     :summary (org-tickets--alist-get "summary" fields)
     :description (org-tickets--parse-description-adf
                   (org-tickets--alist-get "description" fields) key id-map)
     :fix-version (org-tickets--issue-fix-version jira-response)
     :labels (append (org-tickets--alist-get "labels" fields) nil)
     :story-points (org-tickets--alist-get org-tickets-story-points-field fields)
     :blocks (car links)
     :blocked-by (cdr links)
     :parent (org-tickets--alist-get "key" (org-tickets--alist-get "parent" fields))
     :attachments attachments
     :sprint (org-tickets--issue-sprint jira-response)
     :due-date (org-tickets--issue-due-date jira-response))))

(defun org-tickets--put-property-unless-nil (name value)
  "Set property NAME at point to VALUE, skipping it when VALUE is nil."
  (when value
    (org-entry-put (point) name value)))

(defun org-tickets--write-ticket-properties (ticket &optional clear-missing)
  "Write TICKET's Jira properties to the heading at point.
Absent values are skipped, except LABELS which is always written.  When
CLEAR-MISSING is non-nil, absent values instead overwrite the property
with an empty string, and an absent STORY_POINTS is deleted."
  (let* ((story-points (org-tickets--ticket-story-points ticket))
         (empty (and clear-missing "")))
    (org-entry-put (point) "JIRA_KEY" (org-tickets--ticket-key ticket))
    (org-entry-put (point) "JIRA_TYPE" (org-tickets--ticket-type ticket))
    (org-tickets--put-property-unless-nil
     "FIX_VERSION" (or (org-tickets--ticket-fix-version ticket) empty))
    (org-entry-put (point) "LABELS"
                   (mapconcat #'identity (org-tickets--ticket-labels ticket) ","))
    (dolist (spec `(("BLOCKS" . ,(org-tickets--ticket-blocks ticket))
                    ("BLOCKED-BY" . ,(org-tickets--ticket-blocked-by ticket))))
      (org-tickets--put-property-unless-nil
       (car spec)
       (if (cdr spec) (mapconcat #'identity (cdr spec) ",") empty)))
    (org-tickets--put-property-unless-nil
     "PARENT" (or (org-tickets--ticket-parent ticket) empty))
    (if story-points
        (org-entry-put (point) "STORY_POINTS" (number-to-string story-points))
      (when clear-missing
        (org-entry-delete (point) "STORY_POINTS")))
    (org-tickets--put-property-unless-nil
     "SPRINT" (or (org-tickets--ticket-sprint ticket) empty))
    (org-tickets--put-property-unless-nil
     "DUE_DATE" (or (org-tickets--ticket-due-date ticket) empty))))

(defun org-tickets--issue-to-org (ticket)
  "Insert TICKET as an org heading with Jira properties."
  (let ((type (org-tickets--ticket-type ticket))
        (description (org-tickets--ticket-description ticket))
        (attachments (org-tickets--ticket-attachments ticket)))
    ;; Jira includes the type in the summary; strip it from the headline.
    (insert (if (equal type "Story") "** " "* ")
            (org-tickets--strip-type-prefix
             type (org-tickets--ticket-summary ticket))
            "\n")
    (org-tickets--write-ticket-properties ticket)
    (when description
      (insert "\n" description "\n"))
    (dolist (att attachments)
      (let ((filename (org-tickets--attachment-filename att))
            (url (org-tickets--attachment-content-url att)))
        (when filename
          (insert "\n- " filename " ")
          (org-insert-link nil url filename))))))

;;;###autoload
(defun org-tickets-import-feature (ticket-key)
  "Import an existing Jira feature into the current org buffer.
Prompts for TICKET-KEY (e.g., \"PROJ-123\"), fetches from Jira,
and inserts as an org heading with all properties."
  (interactive "sJira ticket key (e.g., PROJ-123): ")
  (org-tickets--resolve-config)
  (let* ((jira-response (org-tickets--get-ticket ticket-key))
         (ticket (org-tickets--parse-jira-issue jira-response)))
    (org-tickets--issue-to-org ticket)
    (message "org-tickets: Imported %s" ticket-key)))

(defun org-tickets--replace-description (description)
  "Replace the description of the ticket heading at point with DESCRIPTION.
The region starts at the end of the :END: line, so the newline the
deletion consumes is always restored; a nil DESCRIPTION leaves an empty
body.  Point is preserved."
  (let ((region (org-tickets--description-region)))
    (when region
      (save-excursion
        (delete-region (car region) (cdr region))
        (goto-char (car region))
        (insert "\n" (if description (concat description "\n") ""))))))

(defun org-tickets--update-org-heading-from-ticket (ticket)
  "Update the org heading at point with data from TICKET.
TICKET is an org-tickets--ticket struct parsed from a Jira API response.
Updates: headline title (from summary), JIRA_TYPE, FIX_VERSION, LABELS,
STORY_POINTS, BLOCKS, BLOCKED-BY, PARENT, SPRINT, and description body."
  (let ((type (org-tickets--ticket-type ticket))
        (summary (org-tickets--ticket-summary ticket))
        (description (org-tickets--ticket-description ticket)))
    (org-tickets--check-ticket-level type summary (org-current-level))
    ;; Update the headline to the Jira summary (type prefix stripped).
    (org-edit-headline (org-tickets--strip-type-prefix type summary))
    (org-tickets--write-ticket-properties ticket t)

    ;; Only now: the edits above shifted the description's positions.
    (org-tickets--replace-description description)))

(defun org-tickets--pull-remote-changes-for-current-ticket ()
  "Fetch the ticket at point from Jira and update its org heading.
Point may be anywhere inside the ticket, including its description
headings; the owning heading must have a JIRA_KEY property."
  (org-tickets--at-ticket-heading
    (let ((ticket-key (org-entry-get (point) "JIRA_KEY")))
      (unless ticket-key
        (user-error "No JIRA_KEY property on this heading; cannot pull remote changes"))
      (org-tickets--resolve-config)
      (let* ((jira-response (org-tickets--get-ticket ticket-key))
             (ticket (org-tickets--parse-jira-issue jira-response)))
        (org-tickets--update-org-heading-from-ticket ticket)
        (message "org-tickets: Pulled remote changes for %s" ticket-key)))))

(provide 'org-tickets-import)

;;; org-tickets-import.el ends here
