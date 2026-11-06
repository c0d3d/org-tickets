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

(defun org-tickets--first-fix-version-name (fields)
  "Return the name of the first fixVersion in Jira FIELDS, or nil."
  (let ((fix-versions (org-tickets--alist-get "fixVersions" fields)))
    (when fix-versions
      (let ((fv-list (if (listp fix-versions)
                         fix-versions
                       (append fix-versions nil))))
        (when fv-list
          (org-tickets--alist-get "name" (car fv-list)))))))

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

(defun org-tickets--parse-attachments (fields)
  "Parse the attachment list from Jira FIELDS into a list of alists.
Each element has keys id, filename, url, size, and media-api-file-id."
  (let ((attachments-data (org-tickets--alist-get "attachment" fields))
        (result nil))
    (dolist (att (if (listp attachments-data)
                     attachments-data
                   (append attachments-data nil)))
      (push (list (cons 'id (org-tickets--alist-get "id" att))
                  (cons 'filename (org-tickets--alist-get "filename" att))
                  (cons 'url (org-tickets--alist-get "content" att))
                  (cons 'size (org-tickets--alist-get "size" att))
                  (cons 'media-api-file-id
                        (org-tickets--alist-get "mediaApiFileId" att)))
            result))
    (nreverse result)))

(defun org-tickets--build-attachment-id-map (attachments)
  "Build an alist mapping attachment IDs to filenames from ATTACHMENTS.
Indexes each attachment by both its numeric Jira id and its
mediaApiFileId (UUID) so ADF media nodes — which reference the UUID —
resolve to a filename either way."
  (let ((map nil))
    (dolist (att attachments map)
      (let ((id (cdr (assoc 'id att)))
            (filename (cdr (assoc 'filename att)))
            (media-id (cdr (assoc 'media-api-file-id att))))
        (when (and id filename)
          (push (cons id filename) map))
        (when (and media-id filename)
          (push (cons media-id filename) map))))))

(defun org-tickets--parse-description-adf (description-adf key)
  "Parse DESCRIPTION-ADF into org text, or nil when absent or unparsable.
On a parse error a warning naming ticket KEY is emitted and nil returned.
Relies on `org-tickets--adf-attachment-id-map' being dynamically bound."
  (when description-adf
    (condition-case err
        (org-tickets--parse-adf-description description-adf)
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
         (attachments (org-tickets--parse-attachments fields))
         ;; Bound dynamically so the description ADF parse below can resolve
         ;; media nodes by attachment id/UUID.
         (org-tickets--adf-attachment-id-map
          (org-tickets--build-attachment-id-map attachments)))
    (org-tickets--ticket-create
     :id (org-tickets--alist-get "id" jira-response)
     :key key
     :type (org-tickets--alist-get "name" issuetype)
     :summary (org-tickets--alist-get "summary" fields)
     :description (org-tickets--parse-description-adf
                   (org-tickets--alist-get "description" fields) key)
     :fix-version (org-tickets--first-fix-version-name fields)
     :labels (append (org-tickets--alist-get "labels" fields) nil)
     :story-points (org-tickets--alist-get org-tickets-story-points-field fields)
     :blocks (car links)
     :blocked-by (cdr links)
     :parent (org-tickets--alist-get "key" (org-tickets--alist-get "parent" fields))
     :attachments attachments
     :sprint (org-tickets--parse-sprint-from-jira-response
              (org-tickets--alist-get org-tickets-sprint-field fields))
     :due-date (org-tickets--alist-get "duedate" fields)
     :org-node nil)))

(defun org-tickets--issue-to-org (ticket)
  "Insert TICKET as an org heading with Jira properties."
  (let* ((type (org-tickets--ticket-type ticket))
         (summary (org-tickets--ticket-summary ticket))
         (key (org-tickets--ticket-key ticket))
         (description (org-tickets--ticket-description ticket))
         (fix-version (org-tickets--ticket-fix-version ticket))
         (labels (org-tickets--ticket-labels ticket))
         (story-points (org-tickets--ticket-story-points ticket))
         (blocks (org-tickets--ticket-blocks ticket))
         (blocked-by (org-tickets--ticket-blocked-by ticket))
         (parent (org-tickets--ticket-parent ticket))
         (attachments (org-tickets--ticket-attachments ticket))
         (sprint (org-tickets--ticket-sprint ticket))
         (due-date (org-tickets--ticket-due-date ticket)))

    ;; Strip type prefix from summary if present (Jira includes it in the summary)
    (let ((clean-summary (org-tickets--strip-type-prefix type summary)))
      ;; Determine heading level and prefix based on type
      (pcase type
        ((or "New Feature" "Feature" "Improvement")
         (insert "* " clean-summary "\n"))
        ("Story"
         (insert "** " clean-summary "\n"))
        (_
         (insert "* " clean-summary "\n"))))

    ;; Set properties - org-entry-put works on current heading in org-mode
    (org-entry-put (point) "JIRA_KEY" key)
    (org-entry-put (point) "JIRA_TYPE" type)
    (when fix-version
      (org-entry-put (point) "FIX_VERSION" fix-version))
    (org-entry-put (point) "LABELS" (if labels (mapconcat 'identity labels ",") ""))
    (when blocks
      (org-entry-put (point) "BLOCKS" (mapconcat 'identity blocks ",")))
    (when blocked-by
      (org-entry-put (point) "BLOCKED-BY" (mapconcat 'identity blocked-by ",")))
    (when parent
      (org-entry-put (point) "PARENT" parent))
    (when story-points
      (org-entry-put (point) "STORY_POINTS" (number-to-string story-points)))
    (when sprint
      (org-entry-put (point) "SPRINT" sprint))
    (when due-date
      (org-entry-put (point) "DUE_DATE" due-date))

    ;; Insert description if present
    (when description
      (insert "\n" description "\n"))

    ;; Insert attachments if present
    (when attachments
      (dolist (att attachments)
        (let ((filename (cdr (assoc 'filename att)))
              (url (cdr (assoc 'url att))))
          (when filename
            (insert "\n- " filename " ")
            (org-insert-link nil url filename)))))))

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

(defun org-tickets--update-org-heading-from-ticket (ticket)
  "Update the org heading at point with data from TICKET.
TICKET is an org-tickets--ticket struct parsed from a Jira API response.
Updates: headline title (from summary), JIRA_TYPE, FIX_VERSION, LABELS,
STORY_POINTS, BLOCKS, BLOCKED-BY, PARENT, SPRINT, and description body."
  (let* ((type (org-tickets--ticket-type ticket))
         (summary (org-tickets--ticket-summary ticket))
         (key (org-tickets--ticket-key ticket))
         (description (org-tickets--ticket-description ticket))
         (fix-version (org-tickets--ticket-fix-version ticket))
         (labels (org-tickets--ticket-labels ticket))
         (story-points (org-tickets--ticket-story-points ticket))
         (blocks (org-tickets--ticket-blocks ticket))
         (blocked-by (org-tickets--ticket-blocked-by ticket))
         (parent (org-tickets--ticket-parent ticket))
         (sprint (org-tickets--ticket-sprint ticket))
         (due-date (org-tickets--ticket-due-date ticket)))

    (org-tickets--check-ticket-level type summary (org-current-level))
    ;; 1. Update the headline title to reflect the Jira summary (strip type prefix if present)
    (org-edit-headline (org-tickets--strip-type-prefix type summary))

    ;; 2. Update properties
    (org-entry-put (point) "JIRA_KEY" key)
    (org-entry-put (point) "JIRA_TYPE" type)
    (org-entry-put (point) "FIX_VERSION" (or fix-version ""))
    (org-entry-put (point) "LABELS" (if labels (mapconcat 'identity labels ",") ""))
    (org-entry-put (point) "BLOCKS" (if blocks (mapconcat 'identity blocks ",") ""))
    (org-entry-put (point) "BLOCKED-BY" (if blocked-by (mapconcat 'identity blocked-by ",") ""))
    (org-entry-put (point) "PARENT" (or parent ""))
    (if story-points
        (org-entry-put (point) "STORY_POINTS" (number-to-string story-points))
      (when (fboundp 'org-entry-delete)
        (org-entry-delete (point) "STORY_POINTS")))
    (org-entry-put (point) "SPRINT" (or sprint ""))
    (org-entry-put (point) "DUE_DATE" (or due-date ""))

    ;; 3. Update description body.
    ;; IMPORTANT: compute the region only now — org-edit-headline and the
    ;; org-entry-put calls above changed buffer positions, so any element
    ;; captured earlier is stale.  The description ends at the first child
    ;; ticket heading, same rule as `org-tickets--get-ticket-description'.
    (save-excursion
      (org-back-to-heading t)
      (let* ((element (org-element-at-point))
             (content-begin (org-element-property :contents-begin element))
             (content-end (or (org-element-property :contents-end element)
                              content-begin)))
        (when content-begin
          (let ((desc-start content-begin)
                (desc-end (org-tickets--description-end content-end)))
            (goto-char content-begin)
            (when (re-search-forward org-property-start-re desc-end t)
              (re-search-forward org-property-end-re desc-end t)
              (setq desc-start (point)))
            (when (< desc-start desc-end)
              (delete-region desc-start desc-end))
            (goto-char desc-start)
            ;; desc-start sits at the end of the :END: line; always restore
            ;; the newline the deletion consumed.
            (if description
                (insert "\n" description "\n")
              (insert "\n"))))))))

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
