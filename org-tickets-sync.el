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
                  "Story" summary description (plist-get parent :fix-version)
                  labels nil sprint nil (plist-get parent :due-date)))
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
      (let ((fields (org-tickets--alist-get "fields"
                                         (org-tickets--get-ticket feature-key))))
        (list :fix-version (org-tickets--first-fix-version-name fields)
              :due-date (org-tickets--fields-due-date fields)
              :labels (org-tickets--alist-get "labels" fields))))))

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
  (org-tickets--update-ticket ticket-key :fix-version version)
  (org-tickets--set-org-fix-version ticket-key version))

(defun org-tickets--set-org-fix-version (ticket-key version)
  "Set the FIX_VERSION property in org for TICKET-KEY."
  (org-tickets--with-ticket-at-key ticket-key
    (org-entry-put (point) "FIX_VERSION" version)))

(defconst org-tickets--inherited-properties '("DUE_DATE" "FIX_VERSION")
  "Drawer properties a ticket takes from its parent when it has none.
Both are payload fields (`duedate' and `fixVersions'), so inheritance
has to happen before the sync builds its requests.")

(defun org-tickets--fields-due-date (fields)
  "Return the duedate in Jira issue FIELDS, or nil."
  (org-tickets--alist-get "duedate" fields))

(defconst org-tickets--remote-inherited-fields
  '(("DUE_DATE" . org-tickets--fields-due-date)
    ("FIX_VERSION" . org-tickets--first-fix-version-name))
  "Inherited properties read from Jira when the PARENT is not in the buffer.
Each maps to a function of the issue's fields that returns the value.")

(defvar org-tickets--remote-parent-cache nil
  "Hash of parent key to its Jira issue, bound for one inheritance pass.")

(defun org-tickets--fetch-parent-issue (parent-key)
  "Return the Jira issue PARENT-KEY, or nil when the fetch fails."
  (condition-case err
      (org-tickets--get-ticket parent-key)
    (error
     (message "org-tickets: could not fetch parent %s: %s"
              parent-key (error-message-string err))
     nil)))

(defun org-tickets--remote-parent-issue (parent-key)
  "Return the Jira issue PARENT-KEY, fetching it at most once per pass.
Fetches uncached when no pass has bound `org-tickets--remote-parent-cache'.
Returns nil when the fetch fails."
  (if (not org-tickets--remote-parent-cache)
      (org-tickets--fetch-parent-issue parent-key)
    (let ((cached (gethash parent-key org-tickets--remote-parent-cache 'missing)))
      (if (not (eq cached 'missing))
          cached
        (puthash parent-key (org-tickets--fetch-parent-issue parent-key)
                 org-tickets--remote-parent-cache)))))

(defun org-tickets--remote-parent-property (parent-key property)
  "Return PARENT-KEY's PROPERTY as Jira has it, or nil.
Only properties in `org-tickets--remote-inherited-fields' are looked up."
  (let ((extract (cdr (assoc property org-tickets--remote-inherited-fields))))
    (when extract
      (let ((value (funcall extract
                            (org-tickets--alist-get
                             "fields" (org-tickets--remote-parent-issue parent-key)))))
        (and (stringp value) (not (string-blank-p value)) value)))))

(defun org-tickets--ancestor-property (property)
  "Return PROPERTY of the nearest ancestor ticket heading carrying it, or nil."
  (save-excursion
    (catch 'ancestor-value
      (while (org-up-heading-safe)
        (when (org-entry-get (point) "JIRA_TYPE")
          (let ((value (org-tickets--heading-property property)))
            (when value
              (throw 'ancestor-value value))))))))

(defun org-tickets--parent-key-property (parent-key property)
  "Return PROPERTY of the ticket PARENT-KEY, or nil.
Read from its heading when it is in the buffer, otherwise from Jira."
  (let ((parent-pos (org-tickets--find-ticket-by-key parent-key)))
    (if parent-pos
        (save-excursion
          (goto-char parent-pos)
          (org-tickets--heading-property property))
      (org-tickets--remote-parent-property parent-key property))))

(defun org-tickets--explicit-parent-property (property)
  "Return PROPERTY of the ticket named by the heading's PARENT, or nil."
  (let ((parent-key (org-entry-get (point) "PARENT")))
    (when (org-tickets--valid-ticket-key-p parent-key)
      (org-tickets--parent-key-property parent-key property))))

(defun org-tickets--parent-property (property)
  "Return the PROPERTY value the ticket heading at point inherits, or nil.
Prefers the ticket named by the heading's PARENT property, which need
not be an outline ancestor nor in the buffer -- it is also the ticket the
\"Blocks\" link goes to.  Failing that, the nearest ancestor ticket
heading that carries PROPERTY.  Non-ticket headings are never a source:
only headings with a JIRA_TYPE count."
  (or (org-tickets--explicit-parent-property property)
      (org-tickets--ancestor-property property)))

(defun org-tickets--inherit-parent-property-at-point (property)
  "Set PROPERTY on the heading at point from its parent when it is empty.
A value the heading already carries is left alone."
  (unless (org-tickets--heading-property property)
    (let ((inherited (org-tickets--parent-property property)))
      (when inherited
        (org-entry-put (point) property inherited)))))

(defun org-tickets--inherit-parent-properties-in-buffer ()
  "Fill every ticket heading's empty `org-tickets--inherited-properties'.
Runs before the sync parses the document, so an inherited value is part
of the same create/update payload Jira receives -- inheriting only after
the requests were sent left Jira with an empty due date until the next
sync, and fix version was never inherited at all.  Walking top-down
cascades: a heading that just inherited is the source for its own
children.  A heading that already carries the property is left alone;
its value wins over the parent's."
  (let ((org-tickets--remote-parent-cache (make-hash-table :test #'equal)))
    (org-map-entries
     (lambda ()
       (when (org-entry-get (point) "JIRA_TYPE")
         (mapc #'org-tickets--inherit-parent-property-at-point
               org-tickets--inherited-properties))))))

(defun org-tickets--inherit-due-date (story-key feature-key)
  "Inherit due date from parent Feature/Improvement to Story if not already set.
STORY-KEY is the Story ticket key.
FEATURE-KEY is the parent Feature/Improvement key.
Only sets the due date if the Story doesn't already have one.  A
FEATURE-KEY absent from the buffer is looked up in Jira."
  (org-tickets--with-ticket-at-key story-key
    (unless (org-tickets--heading-property "DUE_DATE")
      (let ((parent-due-date (org-tickets--parent-key-property
                              feature-key "DUE_DATE")))
        (when parent-due-date
          (org-entry-put (point) "DUE_DATE" parent-due-date))))))

;;;###autoload
(defun org-tickets-update-story-sizing (story-key story-points)
  "Update story sizing for STORY-KEY.
STORY-POINTS of 0 or nil removes the estimate in Jira and org, and
restores `org-tickets-needs-sizing-label'."
  (interactive "sStory key: \nNStory points (0 to remove): ")
  (let ((points (and (numberp story-points) (> story-points 0) story-points)))
    (if points
        (org-tickets--update-ticket story-key :story-points points)
      (org-tickets--api-request
       "PUT" (concat "/rest/api/3/issue/" story-key)
       (list (cons 'fields
                   (list (cons (intern org-tickets-story-points-field)
                               :json-null))))))
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

(defun org-tickets--sync-save-point ()
  "Record point and window scroll of the current buffer for later restore.
Uses markers so the saved location rides along as sync inserts text."
  (setq org-tickets--sync-saved-point (point-marker))
  (let ((win (get-buffer-window (current-buffer))))
    (setq org-tickets--sync-saved-window-start
          (and win (copy-marker (window-start win))))))

(defun org-tickets--sync-restore-point ()
  "Restore point and window scroll saved by `org-tickets--sync-save-point'.
Runs in the saved point's buffer.  Restores point, and if that buffer is
displayed in a window, restores its scroll without stealing focus.
Degrades gracefully if nothing was saved or the buffer was killed.
Always releases the saved markers."
  (let ((point-marker org-tickets--sync-saved-point)
        (start-marker org-tickets--sync-saved-window-start))
    (when (and (markerp point-marker) (buffer-live-p (marker-buffer point-marker)))
      (with-current-buffer (marker-buffer point-marker)
        (goto-char point-marker)
        (let ((win (get-buffer-window (current-buffer))))
          (when win
            (when (and (markerp start-marker) (marker-position start-marker))
              (set-window-start win start-marker))
            (set-window-point win (point))))))
    (when (markerp point-marker) (set-marker point-marker nil))
    (when (markerp start-marker) (set-marker start-marker nil))
    (setq org-tickets--sync-saved-point nil)
    (setq org-tickets--sync-saved-window-start nil)))

(defun org-tickets--sync-cleanup ()
  "Clear sync-in-progress flag, unlock buffer, and remove progress indicator.
Restores `buffer-read-only' to what it was before sync locked it, rather
than always unlocking a buffer the user had deliberately made read-only.
Also restores point and window scroll to where they were when sync began."
  (setq buffer-read-only org-tickets--sync-prior-read-only)
  (setq org-tickets--sync-prior-read-only nil)
  (setq org-tickets--sync-in-progress nil)
  (org-tickets--progress-clear)
  (org-tickets--sync-restore-point))

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

(defun org-tickets--set-org-sprint (ticket-key sprint)
  "Set SPRINT property in org for TICKET-KEY."
  (org-tickets--with-ticket-at-key ticket-key
    (org-entry-put (point) "SPRINT" sprint)))

(defun org-tickets--set-org-due-date (ticket-key due-date)
  "Set the DUE_DATE property in org for TICKET-KEY to DUE-DATE."
  (org-tickets--with-ticket-at-key ticket-key
    (org-entry-put (point) "DUE_DATE" due-date)))

(defun org-tickets--set-org-ticket-key (ticket key)
  "Write KEY as JIRA_KEY on TICKET's heading, located via its marker.
Markers survive the buffer edits earlier sync steps make, unlike the
buffer positions captured at parse time."
  (org-tickets--at-ticket-marker ticket
    (org-entry-put (point) "JIRA_KEY" key)))

(defun org-tickets--ticket-buffer-key (ticket)
  "Read TICKET's current JIRA_KEY from the buffer via its marker.
Picks up keys assigned earlier in the same sync run for tickets that
were parsed without one.  Returns nil when unavailable."
  (org-tickets--at-ticket-marker ticket
    (org-tickets--heading-property "JIRA_KEY")))

(defun org-tickets--link-done-callback (from-key to-key done)
  "Return a callback for the FROM-KEY -> TO-KEY link that logs failures.
The callback then calls DONE."
  (lambda (_response err)
    (when err
      (message "org-tickets: failed to create link %s -> %s: %s"
               from-key to-key err))
    (funcall done nil nil)))

(defun org-tickets--link-thunk (from-key to-key)
  "Return a batch thunk that creates a \"Blocks\" link FROM-KEY -> TO-KEY.
Failures are logged; the thunk always completes."
  (lambda (done)
    (org-tickets--async-create-link
     from-key to-key "Blocks"
     (org-tickets--link-done-callback from-key to-key done))))

(defun org-tickets--ticket-link-thunks (ticket key)
  "Return the link thunks TICKET (whose key is KEY) needs.
Child tickets block their parent; BLOCKS entries are blocked by KEY and
BLOCKED-BY entries block KEY.  Links from a ticket to itself are dropped."
  (let* ((parent-key (and (org-tickets--child-type-p (org-tickets--ticket-type ticket))
                          (org-tickets--ticket-parent-key ticket)))
         (targets (seq-remove
                   (lambda (to) (string= key to))
                   (append (and (org-tickets--non-empty-string parent-key)
                                (list parent-key))
                           (org-tickets--ticket-blocks ticket))))
         (blockers (seq-remove (lambda (from) (string= key from))
                               (org-tickets--ticket-blocked-by ticket))))
    (append (mapcar (lambda (to) (org-tickets--link-thunk key to)) targets)
            (mapcar (lambda (from) (org-tickets--link-thunk from key)) blockers))))

(defun org-tickets--async-sync-ticket-links (ticket _org-buffer callback)
  "Asynchronously sync block relationships for TICKET.
Collects all needed links (parent, blocks, blocked-by) and fires them
concurrently via `org-tickets--async-batch'.  _ORG-BUFFER is unused;
TICKET's marker locates its heading.  CALLBACK is called when all complete."
  (let* ((key (or (org-tickets--ticket-key ticket)
                  (org-tickets--ticket-buffer-key ticket)))
         (thunks (and (org-tickets--non-empty-string key)
                      (org-tickets--ticket-link-thunks ticket key))))
    (if thunks
        (org-tickets--async-batch thunks (lambda (_results) (funcall callback)))
      (funcall callback))))

(provide 'org-tickets-sync)

;;; org-tickets-sync.el ends here
