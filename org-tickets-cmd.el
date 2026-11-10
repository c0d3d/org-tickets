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
(defun org-tickets-refresh-issue-types ()
  "Force refresh of issue type IDs from Jira."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an Org buffer"))
  (org-tickets--resolve-config)
  (org-tickets--fetch-and-save-issue-types)
  (message "org-tickets: Issue types refreshed from Jira: %s" org-tickets--issue-type-ids))

;;;; Templates

(defconst org-tickets--template-keep-empty-props
  '("LABELS" "BLOCKS" "BLOCKED-BY" "STORY_POINTS")
  "Template properties that are written even when their value is empty.")

(defun org-tickets--insert-ticket-template (stars type summary props)
  "Insert the heading \"STARS SUMMARY\" at point and put properties on it.
TYPE is stored as JIRA_TYPE.  PROPS is an alist of (NAME . VALUE) pairs
stored on the new heading, in order.  Pairs whose value is nil or \"\"
are skipped, except names in `org-tickets--template-keep-empty-props',
which are written empty.  From mid-line, the heading starts on the next
line.  Point ends after the new entry's property drawer."
  (unless (bolp)
    (forward-line 1)
    (unless (bolp) (insert "\n")))
  (let ((start (point)))
    (insert stars " " summary "\n")
    (goto-char start)
    (dolist (prop (cons (cons "JIRA_TYPE" type) props))
      (when (or (member (car prop) org-tickets--template-keep-empty-props)
                (not (member (cdr prop) '(nil ""))))
        (org-entry-put (point) (car prop) (or (cdr prop) ""))))
    (org-end-of-meta-data)))

;;;###autoload
(defun org-tickets-insert-feature-template (summary &optional fix-version due-date)
  "Insert a Feature template at point.
SUMMARY is the feature title.
FIX-VERSION is optional.
DUE-DATE is optional (YYYY-MM-DD format)."
  (interactive "sFeature summary: \nsFix Version (optional): \nsDue Date (optional, YYYY-MM-DD): ")
  (org-tickets--insert-ticket-template
   "*" "New Feature" summary
   `(("FIX_VERSION" . ,fix-version) ("LABELS") ("BLOCKS") ("DUE_DATE" . ,due-date))))

;;;###autoload
(defun org-tickets-insert-improvement-template (summary &optional fix-version due-date)
  "Insert an Improvement template at point.
SUMMARY is the improvement title.
FIX-VERSION is optional.
DUE-DATE is optional (YYYY-MM-DD format)."
  (interactive "sImprovement summary: \nsFix Version (optional): \nsDue Date (optional, YYYY-MM-DD): ")
  (org-tickets--insert-ticket-template
   "*" "Improvement" summary
   `(("FIX_VERSION" . ,fix-version) ("LABELS") ("BLOCKS") ("DUE_DATE" . ,due-date))))

;;;###autoload
(defun org-tickets-insert-story-template (summary parent-key &optional fix-version)
  "Insert a Story template under a Feature/Improvement.
SUMMARY is the story title.
PARENT-KEY is the parent Feature/Improvement key.
FIX-VERSION is optional (will inherit if not specified)."
  (interactive "sStory summary: \nsParent key: \nsFix Version (optional): ")
  (org-tickets--insert-ticket-template
   "**" "Story" summary
   `(("PARENT" . ,parent-key) ("BLOCKS") ("BLOCKED-BY") ("STORY_POINTS")
     ("LABELS") ("FIX_VERSION" . ,fix-version))))

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
      (org-id-get-create)
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
      (let* ((names (org-tickets--attachment-names heading-key))
             (local-files (car names))
             (remote-files (cdr names)))
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
    (org-id-get-create)
    (org-attach-reveal)))

;;;###autoload
(defun org-tickets-attach-remove (filename)
  "Remove attachment FILENAME from the current heading's ticket.
Deletes from Jira when the ticket has it there, and from the local
org-attach directory when present.  Interactively, completes over the
union of local and Jira attachment names."
  (interactive
   (list (org-tickets--at-ticket-heading
           (let* ((key (or (org-entry-get (point) "JIRA_KEY")
                           (user-error "No JIRA_KEY property on this heading")))
                  (all (org-tickets--attachment-names key))
                  (names (delete-dups (append (car all) (cdr all)))))
             (unless names
               (user-error "No attachments found for %s" key))
             (completing-read "Remove attachment: " names nil t)))))
  (org-tickets--at-ticket-heading
    (org-tickets--remove-attachment filename)))

(defun org-tickets--jira-attachment-ids (ticket-key filename)
  "Return the ids of every Jira attachment of TICKET-KEY named FILENAME."
  (delq nil
        (mapcar (lambda (att)
                  (and (equal (org-tickets--attachment-filename att) filename)
                       (org-tickets--attachment-id att)))
                (org-tickets--get-attachments ticket-key))))

(defun org-tickets--remove-attachment (filename)
  "Remove attachment FILENAME for the ticket heading at point.
Deletes it from Jira (every attachment with that name) and from the
local org-attach directory, whichever have it, and reports where it
was removed from."
  (let* ((heading-key (or (org-entry-get (point) "JIRA_KEY")
                          (error "No JIRA_KEY property on this heading")))
         (attach-dir (org-tickets--get-ticket-attach-dir nil))
         (attachment-ids (org-tickets--jira-attachment-ids heading-key filename))
         (local-path (and attach-dir (expand-file-name filename attach-dir)))
         (local-exists (and local-path (file-exists-p local-path)))
         (removed nil))
    (unless (or attachment-ids local-exists)
      (error "File %s not found in attachment directory or Jira" filename))
    (when attachment-ids
      (dolist (id attachment-ids)
        (org-tickets--delete-attachment heading-key id))
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

(defun org-tickets--browse-url (ticket-key)
  "Return the Jira browse URL for TICKET-KEY, or signal if no base URL is set."
  (concat (org-tickets--base-url) "/browse/" ticket-key))

(defun org-tickets--copy-ticket-link-to-clipboard (ticket-key)
  "Copy Jira ticket link for TICKET-KEY to clipboard."
  (let ((url (org-tickets--browse-url ticket-key)))
    (when (and (fboundp 'gui-set-selection) (display-graphic-p))
      (gui-set-selection 'PRIMARY url))
    (kill-new url)
    (message "Copied %s to clipboard" url)))

;;;###autoload
(defun org-tickets-copy-link ()
  "Copy the Jira browse link for the ticket at point."
  (interactive)
  (let ((key (org-tickets--at-ticket-heading (org-entry-get (point) "JIRA_KEY"))))
    (unless (org-tickets--non-empty-string key)
      (user-error "No JIRA_KEY property on this heading"))
    (org-tickets--copy-ticket-link-to-clipboard key)))

;;;; Insert Hyperlink Commands

(defun org-tickets--insert-ticket-hyperlink (ticket-key)
  "Insert a hyperlink to TICKET-KEY at point."
  (insert (format "[[%s][%s]]" (org-tickets--browse-url ticket-key) ticket-key)))

;;;###autoload
(defun org-tickets-insert-ticket-link ()
  "Insert a link to another Jira ticket."
  (interactive)
  (let ((ticket-key (string-trim (read-string "Ticket key: "))))
    (when (string-empty-p ticket-key)
      (user-error "No ticket key given"))
    (org-tickets--insert-ticket-hyperlink ticket-key)))

;;;; Navigation Commands

(defun org-tickets--goto-ticket-heading (step)
  "Move to the next ticket heading in direction STEP (1 or -1).
Description headings are skipped.  Leave point alone and signal a
`user-error' when there is no further ticket heading."
  (let ((origin (point))
        (move (if (> step 0) #'outline-next-heading #'outline-previous-heading)))
    (when (> step 0) (end-of-line))
    (when (< step 0) (beginning-of-line))
    (while (and (funcall move) (not (org-tickets--ticket-heading-p))))
    (unless (and (org-at-heading-p) (org-tickets--ticket-heading-p)
                 (/= (point) origin))
      (goto-char origin)
      (user-error "No %s ticket heading" (if (> step 0) "next" "previous")))))

;;;###autoload
(defun org-tickets-next-ticket ()
  "Move to the next ticket heading."
  (interactive)
  (org-tickets--goto-ticket-heading 1))

;;;###autoload
(defun org-tickets-previous-ticket ()
  "Move to the preceding ticket heading."
  (interactive)
  (org-tickets--goto-ticket-heading -1))

(with-eval-after-load 'org
  (define-key org-mode-map (kbd "s-<up>") #'org-tickets-previous-ticket)
  (define-key org-mode-map (kbd "s-<down>") #'org-tickets-next-ticket))

(provide 'org-tickets-cmd)

;;; org-tickets-cmd.el ends here
