;;; org-tickets-sync.el --- Sync functions for org-tickets  -*- lexical-binding: t; -*-

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

;; Sync functions for org-tickets.
;; Contains sync logic, story creation, block links, fix version management.

;;; Code:

(require 'org-tickets-api)
(require 'org-tickets-parse)
(require 'org-tickets-convert)
(require 'org-tickets-attachments)
(require 'org-tickets-async)
(require 'org-tickets-links)
(require 'org-tickets-inherit)
(require 'org-tickets-sync-phases)
(require 'org-tickets-import)

;;;; Story Creation

;;;###autoload
(defun org-tickets-create-story (feature-key summary &optional description blocks-list sprint)
  "Create a new Story under FEATURE-KEY.
SUMMARY is the story title.  DESCRIPTION is optional body.
BLOCKS-LIST is story keys this story blocks.
SPRINT is the Sprint name (defaults to `org-tickets-default-sprint')."
  (interactive "sFeature/Improvement key: \nsStory summary: \nsDescription (optional): ")
  (let* ((parent (org-tickets--story-parent-values feature-key))
         (sprint (or sprint
                     org-tickets-default-sprint
                     (when (called-interactively-p 'any)
                       (read-string "Sprint (leave empty for none): "))))
         (labels (or (plist-get parent :labels)
                     (org-tickets--needs-sizing-labels)))
         ;; No Jira parent field: the inserted heading carries a PARENT
         ;; property, so the Story→Feature "Blocks" link is created on the
         ;; next sync (see `org-tickets--async-sync-ticket-links').
         (result (org-tickets--create-ticket
                  (org-tickets--ticket-create
                   :type "Story" :summary summary :description description
                   :fix-version (plist-get parent :fix-version)
                   :labels labels :sprint sprint
                   :due-date (plist-get parent :due-date))))
         (new-key (alist-get 'key result)))
    (org-tickets--insert-story-heading summary feature-key new-key sprint labels)
    (dolist (blocked blocks-list)
      (org-tickets-add-block-link new-key blocked))
    new-key))

(defun org-tickets--story-parent-values (feature-key)
  "Return a plist of FEATURE-KEY's :fix-version, :due-date and :labels.
Read from the feature's heading when it is in the buffer, otherwise from
Jira.  Signals an error when Jira cannot return the feature either."
  (let ((feature (seq-find (lambda (f)
                             (string= (org-tickets--ticket-key f) feature-key))
                           (org-tickets--doc-features (org-tickets--parse-document)))))
    (if feature
        (list :fix-version (org-tickets--ticket-fix-version feature)
              :due-date (org-tickets--ticket-due-date feature)
              :labels (org-tickets--ticket-labels feature))
      (let ((issue (org-tickets--get-ticket feature-key)))
        (list :fix-version (org-tickets--issue-fix-version issue)
              :due-date (org-tickets--issue-due-date issue)
              :labels (org-tickets--response-field issue "labels"))))))

(defun org-tickets--insert-story-heading (summary parent-key new-key &optional sprint labels)
  "Insert a Story heading as a child of PARENT-KEY's heading.
A PARENT-KEY absent from the buffer gets a top-level heading at the end
of the buffer instead; its PARENT property still names the feature.
SUMMARY is the heading text and NEW-KEY its JIRA_KEY.  SPRINT, when
non-nil, is recorded as the SPRINT property.  LABELS is the label list
actually sent to Jira, recorded verbatim so local state matches the
remote ticket."
  (let ((parent-pos (org-tickets--find-ticket-by-key parent-key)))
    (if parent-pos
        (progn
          (goto-char parent-pos)
          (let ((stars (make-string (1+ (or (org-current-level) 1)) ?*)))
            (org-end-of-subtree t)
            (insert "\n" stars " " summary "\n")))
      (goto-char (point-max))
      (unless (bolp) (insert "\n"))
      (insert "* " summary "\n"))
    (org-entry-put (point) "JIRA_KEY" new-key)
    (org-entry-put (point) "JIRA_TYPE" "Story")
    (org-entry-put (point) "PARENT" parent-key)
    (org-entry-put (point) "BLOCKS" "")
    (org-entry-put (point) "LABELS"
                   (mapconcat #'identity
                              (or labels (org-tickets--needs-sizing-labels))
                              ","))
    (when sprint
      (org-entry-put (point) "SPRINT" (format "%s" sprint)))))

;;;; Block Relationship Management

;;;###autoload
(defun org-tickets-add-block-link (from-key to-key)
  "Add a \"blocks\" link from FROM-KEY to TO-KEY.
This also adds the reverse \"blocked-by\" link automatically."
  (interactive "sBlocking ticket key: \nsBlocked ticket key: ")
  (org-tickets--async-create-link from-key to-key "Blocks"
                               (lambda (_response err)
                                 (if err
                                     (message "org-tickets: Failed to create link: %s" err)
                                   (message "org-tickets: Created blocks link %s -> %s"
                                            from-key to-key))))
  ;; Update org properties immediately (local state)
  (org-tickets--add-block-prop from-key to-key)
  (org-tickets--add-blocked-by-prop to-key from-key))

(defun org-tickets--add-block-prop (ticket-key blocked-key)
  "Add BLOCKED-KEY to the BLOCKS property of TICKET-KEY in org."
  (org-tickets--with-ticket-at-key ticket-key
    (org-tickets--append-csv-property "BLOCKS" blocked-key)))

(defun org-tickets--add-blocked-by-prop (ticket-key blocker-key)
  "Add BLOCKER-KEY to the BLOCKED-BY property of TICKET-KEY in org."
  (org-tickets--with-ticket-at-key ticket-key
    (org-tickets--append-csv-property "BLOCKED-BY" blocker-key)))

;;;; Fix Version and Label Management

(defun org-tickets--validate-fix-version (version)
  "Return non-nil when VERSION is exactly MONTHYYYY with a valid month."
  (and (stringp version)
       (string-match "\\`\\([A-Za-z]+\\)[0-9]\\{4\\}\\'" version)
       (member (match-string 1 version) org-tickets-fix-version-months)))

;;;###autoload
(defun org-tickets-set-fix-version (ticket-key version)
  "Set the Fix Version for a ticket.
TICKET-KEY is the ticket key.
VERSION is the Fix Version string (e.g., \"Aug2026\")."
  (interactive "sTicket key: \nsFix Version (e.g., Aug2026): ")
  (unless (org-tickets--validate-fix-version version)
    (error "Invalid Fix Version: %s. Valid months are: %s"
           version (mapconcat 'identity org-tickets-fix-version-months ",")))
  (org-tickets--update-ticket
   (org-tickets--ticket-create :key ticket-key :fix-version version))
  (org-tickets--set-org-fix-version ticket-key version))

(defun org-tickets--set-org-fix-version (ticket-key version)
  "Set the FIX_VERSION property in org for TICKET-KEY."
  (org-tickets--with-ticket-at-key ticket-key
    (org-entry-put (point) "FIX_VERSION" version)))

;;;###autoload
(defun org-tickets-update-story-sizing (story-key story-points)
  "Update story sizing for STORY-KEY.
STORY-POINTS of 0 or nil removes the estimate in Jira and org, and
restores `org-tickets-needs-sizing-label'."
  (interactive "sStory key: \nNStory points (0 to remove): ")
  (let ((points (and (numberp story-points) (> story-points 0) story-points)))
    (org-tickets--update-ticket
     (org-tickets--ticket-create :key story-key :story-points points
                                 :clear-story-points (not points)))
    (org-tickets--set-org-story-points story-key points)
    (org-tickets--update-sizing-label story-key points)))

(defun org-tickets--set-org-story-points (ticket-key points)
  "Set STORY_POINTS property in org for TICKET-KEY."
  (org-tickets--with-ticket-at-key ticket-key
    (if points
        (org-entry-put (point) "STORY_POINTS" (number-to-string points))
      (org-entry-delete (point) "STORY_POINTS"))))

(defun org-tickets--needs-sizing-labels ()
  "Return the default label list for an unsized ticket."
  (when org-tickets-needs-sizing-label
    (list org-tickets-needs-sizing-label)))

(defun org-tickets--update-sizing-label (ticket-key story-points)
  "Add or remove `org-tickets-needs-sizing-label' on TICKET-KEY.
Non-nil positive STORY-POINTS removes it; otherwise it is ensured.
Does nothing when that option is nil.  Operates on the label LIST, so
other labels are never mangled."
  (when-let* ((label org-tickets-needs-sizing-label))
    (org-tickets--with-ticket-at-key ticket-key
      (let* ((labels (split-string (or (org-entry-get (point) "LABELS") "")
                                   "," t))
             (sized-p (and (numberp story-points) (> story-points 0)))
             (new-labels (cond
                          (sized-p (remove label labels))
                          ((member label labels) labels)
                          (t (append labels (list label))))))
        (org-entry-put (point) "LABELS"
                       (mapconcat #'identity new-labels ","))))))

;;;; Sync from Org to Jira

;;;###autoload
(defun org-tickets-sync-reset ()
  "Forcibly clear a stuck sync in the current buffer.
Use when an async sync hung (network stall, callback error): unlocks
the buffer, clears the in-progress flag and progress indicator, and
resets rate-limit state.  In-flight HTTP responses that arrive later
are handled by their trapped callbacks and cannot re-lock the buffer."
  (interactive)
  (org-tickets--rate-limit-reset)
  (org-tickets--sync-cleanup)
  (message "org-tickets: sync state reset"))

(defun org-tickets--sync-to-jira ()
  "Sync all tickets in the org document to Jira via async pipeline.
Phase 0 (setup): parse document, check preconditions, mark buffer read-only.
Phase 1: create/update tickets and fetch remote data concurrently.
Phase 2: sync attachments and issue links concurrently.
Phase 3: apply all results to the org buffer synchronously."
  (interactive)
  (catch 'org-tickets--sync-done
    (when org-tickets--sync-in-progress
      (message "org-tickets: Sync already in progress")
      (throw 'org-tickets--sync-done nil))
    (org-tickets--clear-sprint-cache)
    (org-tickets--ensure-issue-types)
    ;; Inherit before parsing so the payloads carry the inherited values.
    (org-tickets--inherit-parent-properties-in-buffer)
    (let* ((doc (org-tickets--parse-document))
           (all-features-exist-p (org-tickets--all-features-exist-p doc))
           (org-buffer (current-buffer))
           (ticket-count (length (org-tickets--doc-tickets doc))))
      (setq org-tickets--sync-prior-read-only buffer-read-only)
      (setq buffer-read-only t)
      (setq org-tickets--sync-in-progress t)
      (org-tickets--sync-save-point)
      (org-tickets--progress-init ticket-count)
      (condition-case err
          (org-tickets--sync-phase-1 doc all-features-exist-p org-buffer)
        (error
         (org-tickets--sync-cleanup)
         (message "org-tickets: Sync failed: %S" err))))))

(provide 'org-tickets-sync)

;;; org-tickets-sync.el ends here
