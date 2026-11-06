;;; org-tickets-cmd.el --- Interactive commands for org-tickets  -*- lexical-binding: t; -*-

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

;; Interactive commands for org-tickets.
;; Contains templates and interactive functions.

;;; Code:

(require 'org-tickets-core)
(require 'org-tickets-api)
(require 'org-tickets-sync)
(require 'org-tickets-import)
(require 'org-tickets-parse)
(require 'org-tickets-attachments)

;;;; Setup and Configuration

;;;###autoload
(defun org-tickets-setup (jira-url project-key)
  "Configure org-tickets with JIRA-URL and PROJECT-KEY.
Credentials are fetched from authinfo on first use, not passed here."
  (setopt org-tickets-base-url jira-url
          org-tickets-project-key project-key)
  (message "org-tickets: Config updated. Credentials will be fetched from authinfo on first use."))

;;;###autoload
(defun org-tickets-refresh-issue-types ()
  "Force refresh of issue type IDs from Jira."
  (interactive)
  (org-tickets--resolve-config)
  (org-tickets--fetch-issue-types)
  (message "org-tickets: Issue types refreshed from Jira: %s" org-tickets--issue-type-ids))

;;;; Templates

;;;###autoload
(defun org-tickets-insert-feature-template (summary &optional fix-version due-date)
  "Insert a Feature/Improvement template at point.
SUMMARY is the feature title.
FIX-VERSION is optional.
DUE-DATE is optional (YYYY-MM-DD format)."
  (interactive "sFeature summary: \nsFix Version (optional): \nsDue Date (optional, YYYY-MM-DD): ")
  (insert "* " summary "\n")
  (org-entry-put (point) "JIRA_TYPE" "New Feature")
  (when (and fix-version (not (string= fix-version "")))
    (org-entry-put (point) "FIX_VERSION" fix-version))
  (org-entry-put (point) "LABELS" "")
  (org-entry-put (point) "BLOCKS" "")
  (when (and due-date (not (string= due-date "")))
    (org-entry-put (point) "DUE_DATE" due-date)))

;;;###autoload
(defun org-tickets-insert-improvement-template (summary &optional fix-version due-date)
  "Insert an Improvement template at point.
SUMMARY is the improvement title.
FIX-VERSION is optional.
DUE-DATE is optional (YYYY-MM-DD format)."
  (interactive "sImprovement summary: \nsFix Version (optional): \nsDue Date (optional, YYYY-MM-DD): ")
  (insert "* " summary "\n")
  (org-entry-put (point) "JIRA_TYPE" "Improvement")
  (when (and fix-version (not (string= fix-version "")))
    (org-entry-put (point) "FIX_VERSION" fix-version))
  (org-entry-put (point) "LABELS" "")
  (org-entry-put (point) "BLOCKS" "")
  (when (and due-date (not (string= due-date "")))
    (org-entry-put (point) "DUE_DATE" due-date)))

;;;###autoload
(defun org-tickets-insert-story-template (summary parent-key &optional fix-version)
  "Insert a Story template under a Feature/Improvement.
SUMMARY is the story title.
PARENT-KEY is the parent Feature/Improvement key.
FIX-VERSION is optional (will inherit if not specified)."
  (interactive "sStory summary: \nsParent key: ")
  (insert "** " summary "\n")
  (org-entry-put (point) "JIRA_TYPE" "Story")
  (org-entry-put (point) "PARENT" parent-key)
  (org-entry-put (point) "BLOCKS" "")
  (org-entry-put (point) "BLOCKED-BY" "")
  (org-entry-put (point) "STORY_POINTS" "")
  (org-entry-put (point) "LABELS" "")
  (when (and fix-version (not (string= fix-version "")))
    (org-entry-put (point) "FIX_VERSION" fix-version)))

;;;; Sync Command

;;;###autoload
(defun org-tickets-sync-to-jira ()
  "Sync all tickets in the org document to Jira.
Creates new tickets for any that don't have JIRA_KEY property.
Updates existing tickets if they've changed.

Attachments are synced immediately after each ticket is created/updated,
so files attached before the initial sync will be uploaded when the
ticket is created."
  (interactive)
  (org-tickets--sync-to-jira))

;;;; Interactive Attachment Commands

;;;###autoload
(defun org-tickets-attach-add (file)
  "Attach FILE to the current org heading (ticket).
This works even without a JIRA_KEY - the file will be uploaded when the ticket
is created during sync.  Files can be attached before syncing to Jira, and will
be uploaded when the ticket is created.
Uses org-attach to manage the attachment locally."
  (interactive "fAttach file: ")
  (require 'org-attach)
  (org-tickets--at-ticket-heading
    (let ((heading-key (org-entry-get (point) "JIRA_KEY")))
      ;; Ensure we have an ID for org-attach - works even without a JIRA_KEY
      (org-tickets--ensure-org-attach-id-for-current-heading)
      ;; Use org-attach to add the file
      (org-attach-attach file nil 'cp)
      (if heading-key
          (message "org-tickets: Attached %s to %s. Run org-tickets-sync-to-jira to upload."
                   (file-name-nondirectory file) heading-key)
        (message "org-tickets: Attached %s to current heading. File will be uploaded when ticket is created during sync."
                 (file-name-nondirectory file))))))

;;;###autoload
(defun org-tickets-attach-list ()
  "List local and Jira attachments for the ticket at point."
  (interactive)
  (org-tickets--at-ticket-heading
    (let ((heading-key (org-entry-get (point) "JIRA_KEY")))
      (unless heading-key
        (user-error "No JIRA_KEY property on this heading"))
      (let* ((local-dir (org-tickets--get-ticket-attach-dir nil))
             (local-files (and local-dir (org-attach-file-list local-dir)))
             (remote-files (mapcar #'org-tickets--attachment-filename
                                   (org-tickets--get-attachments heading-key))))
        (message "org-tickets: local: %s | jira: %s"
                 (if local-files (mapconcat #'identity local-files ", ") "none")
                 (if remote-files (mapconcat #'identity remote-files ", ") "none"))))))

;;;###autoload
(defun org-tickets-attach-open ()
  "Open the attachment directory for the current heading using Dired.
Works before the ticket exists in Jira — org-attach needs only the
heading's ID property, which is created on demand."
  (interactive)
  (require 'org-attach)
  (org-tickets--at-ticket-heading
    (org-tickets--ensure-org-attach-id-for-current-heading)
    (org-attach-reveal)))

;;;###autoload
(defun org-tickets-attach-remove (filename)
  "Remove attachment FILENAME from the current heading's ticket.
Deletes from Jira when the ticket has it there, and from the local
org-attach directory when present.  Interactively, completes over the
union of local and Jira attachment names (the old \"f\" spec read an
absolute path that could never match)."
  (interactive
   (list (org-tickets--at-ticket-heading
           (let* ((key (or (org-entry-get (point) "JIRA_KEY")
                           (user-error "No JIRA_KEY property on this heading")))
                  (dir (org-tickets--get-ticket-attach-dir nil))
                  (local (and dir (org-attach-file-list dir)))
                  (remote (mapcar #'org-tickets--attachment-filename
                                  (org-tickets--get-attachments key)))
                  (names (delete-dups (append local remote))))
             (unless names
               (user-error "No attachments found for %s" key))
             (completing-read "Remove attachment: " names nil t)))))
  (org-tickets--at-ticket-heading
    (org-tickets--remove-attachment filename)))

(defun org-tickets--remove-attachment (filename)
  "Remove attachment FILENAME for the ticket heading at point.
Deletes it from Jira and from the local org-attach directory, whichever
have it, and reports where it was removed from."
  (let* ((heading-key (or (org-entry-get (point) "JIRA_KEY")
                          (error "No JIRA_KEY property on this heading")))
         (attach-dir (org-tickets--get-ticket-attach-dir nil))
         (attachment (seq-find
                      (lambda (att)
                        (string= (org-tickets--attachment-filename att) filename))
                      (org-tickets--get-attachments heading-key)))
         (attachment-id (and attachment (org-tickets--attachment-id attachment)))
         (local-path (and attach-dir (expand-file-name filename attach-dir)))
         (local-exists (and local-path (file-exists-p local-path)))
         (removed nil))
    (unless (or attachment-id local-exists)
      (error "File %s not found in attachment directory or Jira" filename))
    (when attachment-id
      (org-tickets--delete-attachment heading-key attachment-id)
      (push "Jira" removed))
    (when local-exists
      (delete-file local-path)
      (push "local directory" removed))
    (message "org-tickets: removed %s from %s"
             filename (mapconcat #'identity (nreverse removed) " and "))))

;;;; Pull Remote Changes

;;;###autoload
(defun org-tickets-pull-remote-changes ()
  "Pull remote changes from Jira for the ticket at point.
Fetches the current ticket data from Jira and updates the org heading
with the latest values for summary, description, type, labels, sprint,
and more.  Use this when teammates have made changes to a Jira ticket
and you need to sync those changes into your local org buffer."
  (interactive)
  (org-tickets--pull-remote-changes-for-current-ticket))

;;;; Clipboard Commands

(defun org-tickets--copy-ticket-link-to-clipboard (ticket-key)
  "Copy Jira ticket link for TICKET-KEY to clipboard."
  (unless org-tickets-base-url
    (user-error "`org-tickets-base-url' is not set; customize it or set it in your init file"))
  (let* ((url (concat org-tickets-base-url "/browse/" ticket-key)))
    (when (and (fboundp 'gui-set-selection) (display-graphic-p))
      (gui-set-selection 'PRIMARY url))
    (kill-new url)
    (message "Copied %s to clipboard" url)))

;;;###autoload
(defun org-tickets-copy-link ()
  "Copy the Jira browse link for the ticket at point."
  (interactive)
  (let ((key (org-tickets--at-ticket-heading (org-entry-get (point) "JIRA_KEY"))))
    (unless (and key (> (length key) 0))
      (user-error "No JIRA_KEY property on this heading"))
    (org-tickets--copy-ticket-link-to-clipboard key)))

;;;; Insert Hyperlink Commands

(defun org-tickets--insert-ticket-hyperlink (ticket-key)
  "Insert a hyperlink to TICKET-KEY at point."
  (unless org-tickets-base-url
    (user-error "`org-tickets-base-url' is not set; customize it or set it in your init file"))
  (let* ((url (concat org-tickets-base-url "/browse/" ticket-key))
         (link (format "[[%s][%s]]" url ticket-key)))
    (insert link)))

;;;###autoload
(defun org-tickets-insert-ticket-link ()
  "Insert a link to another Jira ticket."
  (interactive)
  (let ((ticket-key (read-string "Ticket key: ")))
    (org-tickets--insert-ticket-hyperlink ticket-key)))

(provide 'org-tickets-cmd)

;;; org-tickets-cmd.el ends here
