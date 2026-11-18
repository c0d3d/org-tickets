;;; org-tickets-sync-phases.el --- Async sync phase functions for org-tickets  -*- lexical-binding: t; -*-

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

;; Async sync phase functions for org-tickets.
;; Contains helpers and the three-phase pipeline (Phase 1, 2, 3)
;; called from `org-tickets--sync-to-jira' in org-tickets-sync.el.

;;; Code:

(require 'org-tickets-core)
(require 'org-tickets-api)
(require 'org-tickets-async)
(require 'org-tickets-parse)
(require 'org-tickets-convert)
(require 'org-tickets-attachments)
(require 'org-tickets-fields)
(require 'org-tickets-links)
(require 'org-tickets-inherit)

;;;; Async Sync Helpers

(defun org-tickets--all-features-exist-p (doc)
  "Return non-nil if every feature in DOC has a non-empty JIRA_KEY."
  (seq-every-p #'org-tickets--ticket-has-key-p
               (org-tickets--doc-features doc)))

(defun org-tickets--ticket-has-key-p (ticket)
  "Return non-nil if TICKET has a non-empty JIRA_KEY."
  (and (org-tickets--non-empty-string (org-tickets--ticket-key ticket)) t))

(defun org-tickets--safe-with-buffer (buffer body-fn)
  "Call BODY-FN in BUFFER if it is alive, otherwise log a debug message.
Returns nil if the buffer is dead."
  (if (buffer-live-p buffer)
      (with-current-buffer buffer (funcall body-fn))
    (when org-tickets-debug
      (message "org-tickets: Buffer killed during async sync, skipping operation"))
    nil))

(defmacro org-tickets--with-writable-buffer (buffer &rest body)
  "Evaluate BODY in BUFFER with `inhibit-read-only' bound, if BUFFER is live.
Wraps `org-tickets--safe-with-buffer', so BODY is skipped (and the form
returns nil) when BUFFER has been killed."
  (declare (indent 1) (debug (form body)))
  `(org-tickets--safe-with-buffer ,buffer
                               (lambda ()
                                 (let ((inhibit-read-only t))
                                   ,@body))))

;;;; Sync Setup and Teardown

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

(defun org-tickets--sync-abort (doc org-buffer err)
  "End the sync of DOC in ORG-BUFFER after ERR, unless it already ended.
Unlocks the buffer and releases DOC's ticket markers.  A sync that
already ran its cleanup is left alone, so a buffer the user made
read-only is not unlocked by a second cleanup."
  (org-tickets--safe-with-buffer
   org-buffer
   (lambda ()
     (when org-tickets--sync-in-progress
       (org-tickets--sync-cleanup))))
  (org-tickets--release-ticket-markers doc)
  (message "org-tickets: Sync failed: %S" err))

(defmacro org-tickets--with-sync-abort (doc org-buffer &rest body)
  "Run BODY, ending the sync of DOC in ORG-BUFFER if BODY signals an error.
Response callbacks run long after the sync command returned, so an
error there would otherwise leave ORG-BUFFER locked."
  (declare (indent 2) (debug (form form body)))
  (let ((err (make-symbol "err")))
    `(condition-case ,err
         (progn ,@body)
       (error (org-tickets--sync-abort ,doc ,org-buffer ,err)))))

;;;; Phase 1: Create/Update Tickets

(org-tickets--define-record org-tickets--sync-result
    "Outcome of one phase-1 ticket create or update."
  key                               ; Jira key (nil when creation failed)
  ticket                            ; The org-tickets--ticket synced
  attachments                       ; Attachment metadata fetched from Jira
  sprint                            ; Sprint name to write back to org
  due-date                          ; Due date to write back to org
  synced                            ; Jira's updated time after the push
  is-new                            ; t when the ticket was just created
  error)                            ; Error from the request, or nil

(defun org-tickets--fire-ticket-put (ticket key attachments sprint due-date synced org-buffer done)
  "Fire async PUT for TICKET with KEY and call DONE when complete.
ATTACHMENTS, SPRINT, DUE-DATE, SYNCED are fetched data from the GET.
ORG-BUFFER is for progress tracking.  DONE is the batch callback."
  (let* ((fields (org-tickets--ticket-fields ticket :attachments attachments))
         (finish (lambda (err)
                   (org-tickets--safe-with-buffer
                    org-buffer #'org-tickets--progress-increment)
                   (funcall done (org-tickets--sync-result-create
                                   :key key :ticket ticket
                                   :attachments attachments
                                   :sprint sprint :due-date due-date :synced synced
                                   :is-new nil :error err)
                            nil))))
    (if (null fields)
        (funcall finish nil)
      (org-tickets--async-request
       "PUT" (concat "/rest/api/3/issue/" key)
       (lambda (_put-response put-err) (funcall finish put-err))
       (list (cons 'fields fields))))))

(defun org-tickets--make-existing-ticket-thunk (ticket org-buffer)
  "Create a thunk for syncing an existing TICKET via async GET then PUT.
ORG-BUFFER is the originating buffer for progress tracking."
  (let ((key (org-tickets--ticket-key ticket)))
    (lambda (done)
      (org-tickets--async-request
       "GET" (concat "/rest/api/3/issue/" key)
       (lambda (get-response get-err)
         (if get-err
             (progn
               (org-tickets--safe-with-buffer org-buffer #'org-tickets--progress-increment)
               (funcall done (org-tickets--sync-result-create
                              :key key :ticket ticket :error get-err)
                        nil))
           (let ((attachments (org-tickets--issue-attachments get-response))
                 (sprint (org-tickets--issue-sprint get-response))
                 (due-date (org-tickets--issue-due-date get-response))
                 (synced (org-tickets--issue-updated get-response)))
             (org-tickets--fire-ticket-put
              ticket key attachments sprint due-date synced org-buffer done))))))))

(defun org-tickets--make-new-ticket-thunk (ticket org-buffer)
  "Create a thunk that POSTs TICKET as a new issue from ORG-BUFFER.
The payload is built when the thunk RUNS, not when it is created.  When
ORG-BUFFER is dead by then nothing is sent and DONE gets an error result.
Parent relationships are NOT part of the create payload -- they are
issued as \"Blocks\" links in phase 2 (`org-tickets--async-sync-ticket-links')."
  (lambda (done)
    (if (not (buffer-live-p org-buffer))
        (funcall done (org-tickets--sync-result-create
                       :ticket ticket :is-new t
                       :error "buffer killed before the ticket was created")
                 nil)
      (org-tickets--async-request
       "POST" "/rest/api/3/issue"
       (lambda (response err)
         (org-tickets--safe-with-buffer org-buffer #'org-tickets--progress-increment)
         (let ((new-key (when response
                          (org-tickets--alist-get "key" response))))
           (funcall done (org-tickets--sync-result-create
                          :key new-key :ticket ticket :is-new t :error err
                          :sprint (when org-tickets-default-sprint
                                    (format "%s" org-tickets-default-sprint)))
                    nil)))
       (list (cons 'fields
                   (with-current-buffer org-buffer
                     (org-tickets--ticket-fields ticket :create-p t))))))))

(defun org-tickets--make-ticket-thunk (ticket org-buffer)
  "Create the appropriate thunk for TICKET (new or existing).
ORG-BUFFER is the originating buffer."
  (if (org-tickets--ticket-has-key-p ticket)
      (org-tickets--make-existing-ticket-thunk ticket org-buffer)
    (org-tickets--make-new-ticket-thunk ticket org-buffer)))

(defun org-tickets--sync-phase-1 (doc all-features-exist-p org-buffer)
  "Phase 1: create/update tickets and fetch remote data.
DOC is the parsed document.  ALL-FEATURES-EXIST-P controls batching.
ORG-BUFFER is the originating buffer."
  (if all-features-exist-p
      (org-tickets--sync-phase-1-all doc org-buffer)
    (org-tickets--sync-phase-1-sequential doc org-buffer)))

(defun org-tickets--sync-phase-1-all (doc org-buffer)
  "Fire all ticket thunks in a single batch.
DOC is the parsed document.  ORG-BUFFER is the originating buffer."
  (let ((thunks (mapcar (lambda (tk) (org-tickets--make-ticket-thunk tk org-buffer))
                        (org-tickets--doc-tickets doc))))
    (org-tickets--async-batch
     thunks
     (lambda (results)
       (org-tickets--sync-phase-2
        doc (mapcar #'car results) org-buffer)))))

(defun org-tickets--sync-phase-1-sequential (doc org-buffer)
  "Create DOC's features first, apply their new keys, then every other ticket.
ORG-BUFFER is the source buffer.
Applying keys between the batches lets a brand-new child's phase-2
processing -- the child->Feature \"Blocks\" link and due-date
inheritance -- resolve the freshly created feature key.

The second batch is every NON-feature ticket, not just the child types:
asking for child tickets here would silently drop a ticket of any other
type from both batches, so it would never be created in Jira even though
the sync reported success."
  (let ((feature-thunks (mapcar (lambda (tk) (org-tickets--make-ticket-thunk tk org-buffer))
                                (org-tickets--doc-features doc))))
    (org-tickets--async-batch
     feature-thunks
     (lambda (feature-results)
       (org-tickets--with-sync-abort doc org-buffer
         (org-tickets--sync-phase-1-rest doc (mapcar #'car feature-results)
                                         org-buffer))))))

(defun org-tickets--sync-phase-1-rest (doc feature-records org-buffer)
  "Apply FEATURE-RECORDS' new keys, then sync DOC's non-feature tickets.
ORG-BUFFER is the source buffer.  Phase 2 starts once all are done."
  (org-tickets--with-writable-buffer org-buffer
    (org-tickets--apply-new-keys feature-records))
  (org-tickets--async-batch
   (mapcar (lambda (tk) (org-tickets--make-ticket-thunk tk org-buffer))
           (org-tickets--doc-non-feature-tickets doc))
   (lambda (rest-results)
     (org-tickets--sync-phase-2
      doc (append feature-records (mapcar #'car rest-results)) org-buffer))))

;;;; Phase 2: Attachments + Links

(defun org-tickets--description-attachment-filenames (description)
  "Return filenames referenced by attachment: links in DESCRIPTION.
DESCRIPTION is parsed as org, so link syntax inside blocks is ignored."
  (with-temp-buffer
    (insert description)
    (org-mode)
    (org-element-map (org-element-parse-buffer) 'link
      (lambda (link)
        (when (equal (org-element-property :type link) "attachment")
          (org-element-property :path link))))))

(defun org-tickets--unresolved-attachment-links-p (description attachments)
  "Non-nil when DESCRIPTION links an attachment ATTACHMENTS cannot embed.
An attachment: link embeds only when the fetched metadata carries a
mediaApiFileId for its filename; links without one degraded to plain
text in the phase-1 description PUT."
  (and description
       (seq-some (lambda (filename)
                   (not (org-tickets--attachment-media-uuid filename attachments)))
                 (org-tickets--description-attachment-filenames description))))

(defun org-tickets--async-refresh-description-embeds (key description callback)
  "Re-PUT KEY's DESCRIPTION so freshly uploaded attachments embed.
Phase 1 builds the description before phase 2 uploads new files, so
their attachment: links degrade to plain text.  This re-fetches the
attachment metadata (new uploads now carry the mediaApiFileId that ADF
media nodes require), rebuilds the description ADF against it, and PUTs
just the description field.  CALLBACK is invoked with no arguments
exactly once, on every path."
  (org-tickets--async-request
   "GET" (concat "/rest/api/3/issue/" key "?fields=attachment")
   (lambda (response err)
     (let ((adf (and (not err)
                     (org-tickets--build-adf-description
                      description
                      (org-tickets--issue-attachments response)))))
       (if (null adf)
           (funcall callback)
         (org-tickets--async-request
          "PUT" (concat "/rest/api/3/issue/" key)
          (lambda (_put-response _put-err) (funcall callback))
          (list (cons 'fields (list (cons 'description adf))))))))))

(defun org-tickets--attachment-refresh-step (key attachments description done)
  "Re-PUT KEY's DESCRIPTION when ATTACHMENTS left embeds unresolved, then DONE.
DONE is called with (nil nil) exactly once."
  (if (org-tickets--unresolved-attachment-links-p description attachments)
      (org-tickets--async-refresh-description-embeds
       key description (lambda () (funcall done nil nil)))
    (funcall done nil nil)))

(defun org-tickets--attachment-upload-step (key attachments org-buffer description done)
  "Upload KEY's ATTACHMENTS from ORG-BUFFER, refresh embeds, then call DONE.
Calls DONE straight away when ORG-BUFFER is dead.  DESCRIPTION is the
ticket's org description."
  (if (not (buffer-live-p org-buffer))
      (funcall done nil nil)
    (with-current-buffer org-buffer
      (let ((inhibit-read-only t))
        (org-tickets--async-upload-attachments
         key attachments
         (lambda (_ul-results _ul-err)
           (org-tickets--attachment-refresh-step
            key attachments description done)))))))

(defun org-tickets--make-attachment-thunk (key attachments org-buffer &optional description)
  "Create a thunk that asynchronously syncs attachments for KEY.
ATTACHMENTS is from Phase 1.  ORG-BUFFER is the source buffer.
DESCRIPTION is the ticket's org description; when it links attachments
that phase 1 could not embed, the description is re-PUT after uploads
so the new files render inline (see
`org-tickets--async-refresh-description-embeds').

DONE is invoked exactly once on every path (buffer dead, download done,
upload done, embed refresh done), satisfying the `org-tickets--async-batch'
contract.  Relying on the return value of `org-tickets--safe-with-buffer'
to decide whether to call DONE is incorrect: that value is the async
helper's arbitrary result, not a signal that the buffer was dead, so it
could fire DONE more than once and corrupt the batch counter (leaving
the pipeline hung)."
  (lambda (done)
    (if (not (buffer-live-p org-buffer))
        (funcall done nil nil)
      (with-current-buffer org-buffer
        (let ((inhibit-read-only t))
          (org-tickets--async-download-attachments
           key attachments
           (lambda (_dl-results _dl-err)
             (org-tickets--attachment-upload-step
              key attachments org-buffer description done))))))))

(defun org-tickets--make-link-thunk (ticket requested)
  "Create a thunk that asynchronously syncs issue links for TICKET.
REQUESTED is the hash table of links already requested this sync,
shared by every link thunk so no link is POSTed twice."
  (lambda (done)
    (let ((org-tickets--links-requested requested))
      (org-tickets--async-sync-ticket-links
       ticket (lambda () (funcall done nil nil))))))

(defun org-tickets--sync-phase-2 (doc phase-1-results org-buffer)
  "Phase 2: sync attachments and issue links concurrently.
DOC is the parsed document.  PHASE-1-RESULTS is the list from phase 1.
ORG-BUFFER is the originating buffer.  An error ends the sync."
  (org-tickets--with-sync-abort doc org-buffer
    ;; First apply new keys from phase 1 so link/attachment functions can find tickets
    (org-tickets--with-writable-buffer org-buffer
      (org-tickets--apply-new-keys phase-1-results))
    (org-tickets--async-batch
     (org-tickets--build-phase-2-thunks doc phase-1-results org-buffer)
     (lambda (_results)
       (org-tickets--sync-phase-3 doc phase-1-results org-buffer)))))

(defun org-tickets--phase-1-result-description (result)
  "Return the org description for a phase-1 RESULT's ticket, or nil.
Every RESULT carries its ticket."
  (org-tickets--ticket-description (org-tickets--sync-result-ticket result)))

(defun org-tickets--build-phase-2-thunks (doc phase-1-results org-buffer)
  "Build thunks for phase 2 from DOC, PHASE-1-RESULTS, and ORG-BUFFER."
  (let ((thunks nil)
        (requested (make-hash-table :test #'equal)))
    ;; Attachment thunks for tickets with keys
    (dolist (result phase-1-results)
      (let ((key (org-tickets--sync-result-key result))
            (attachments (org-tickets--sync-result-attachments result))
            (description (org-tickets--phase-1-result-description result)))
        (when (org-tickets--non-empty-string key)
          (push (org-tickets--make-attachment-thunk key attachments org-buffer
                                                 description)
                thunks))))
    ;; Link thunks for all tickets
    (dolist (ticket (org-tickets--doc-tickets doc))
      (push (org-tickets--make-link-thunk ticket requested) thunks))
    (nreverse thunks)))

;;;; Phase 3: Apply Results to Buffer

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

(defun org-tickets--ensure-blocks-entry (blocker-key key)
  "Add KEY to the BLOCKS property of ticket BLOCKER-KEY unless already listed.
Keys are compared exactly, not as substrings.  Point is preserved."
  (org-tickets--with-ticket-at-key blocker-key
    (let ((current (org-tickets--csv-property "BLOCKS")))
      (unless (member key current)
        (org-tickets--append-csv-property "BLOCKS" key)))))

(defun org-tickets--ticket-blockers (ticket)
  "Return the BLOCKED-BY keys of TICKET whose BLOCKS need updating.
Nil when TICKET has no key; empty keys and TICKET's own key are dropped."
  (let ((key (org-tickets--ticket-key ticket)))
    (and (org-tickets--non-empty-string key)
         (seq-remove (lambda (b) (or (string-empty-p b) (string= b key)))
                     (org-tickets--ticket-blocked-by ticket)))))

(defun org-tickets--resolve-blocked-by-in-org (doc)
  "Update org buffer BLOCKS properties from BLOCKED-BY relationships in DOC.
For each ticket with a BLOCKED-BY property, ensure the referenced ticket's
BLOCKS property includes the current ticket's key."
  (dolist (ticket (org-tickets--doc-tickets doc))
    (dolist (blocker (org-tickets--ticket-blockers ticket))
      (org-tickets--ensure-blocks-entry
       blocker (org-tickets--ticket-key ticket)))))

(defun org-tickets--apply-new-keys (phase-1-results)
  "Write new JIRA_KEYs onto the headings of newly created tickets.
PHASE-1-RESULTS is the list of result records from phase 1."
  (dolist (result phase-1-results)
    (when (org-tickets--sync-result-is-new result)
      (let ((key (org-tickets--sync-result-key result)))
        (when key
          (org-tickets--set-org-ticket-key
           (org-tickets--sync-result-ticket result) key))))))

(defun org-tickets--apply-result-updates (phase-1-results accessor setter)
  "Apply ACCESSOR of each PHASE-1-RESULTS record via SETTER.
For every result with both a key and a non-nil ACCESSOR value, calls
SETTER with that key and value."
  (dolist (result phase-1-results)
    (let ((key (org-tickets--sync-result-key result))
          (value (funcall accessor result)))
      (when (and key value)
        (funcall setter key value)))))

(defun org-tickets--apply-sprint-updates (phase-1-results)
  "Update SPRINT properties from fetched Jira data.
PHASE-1-RESULTS is the list of result records from phase 1."
  (org-tickets--apply-result-updates phase-1-results
                                     #'org-tickets--sync-result-sprint
                                     #'org-tickets--set-org-sprint))

(defun org-tickets--apply-due-date-updates (phase-1-results)
  "Update DUE_DATE properties from fetched Jira data.
PHASE-1-RESULTS is the list of result records from phase 1."
  (org-tickets--apply-result-updates phase-1-results
                                     #'org-tickets--sync-result-due-date
                                     #'org-tickets--set-org-due-date))

(defun org-tickets--apply-synced-updates (phase-1-results)
  "Record JIRA_SYNCED for each successfully pushed result in PHASE-1-RESULTS."
  (dolist (result phase-1-results)
    (let ((key (org-tickets--sync-result-key result))
          (synced (org-tickets--sync-result-synced result)))
      (when (and key synced (not (org-tickets--sync-result-error result)))
        (org-tickets--with-ticket-at-key key
          (org-entry-put (point) "JIRA_SYNCED" synced))))))

(defun org-tickets--apply-due-date-inheritance (doc)
  "Inherit due dates from parent features to child tickets in DOC.
Catches dates that only became known during this run -- a parent whose
DUE_DATE phase 1 fetched from Jira.  Children created during the run are
looked up by the key the buffer just received: their struct was parsed
before the key existed and still holds nil.  A parent absent from the
buffer is fetched from Jira at most once."
  (org-tickets--with-parent-cache
    (dolist (child (org-tickets--doc-children doc))
      (let* ((child-key (or (org-tickets--ticket-key child)
                            (org-tickets--ticket-buffer-key child)))
             (parent-key (org-tickets--ticket-parent-key child)))
        (when (and child-key parent-key)
          (org-tickets--inherit-due-date child-key parent-key))))))

(defun org-tickets--count-phase-1-errors (phase-1-results)
  "Count and log errors from PHASE-1-RESULTS.  Returns the error count."
  (let ((error-count 0))
    (dolist (result phase-1-results)
      (let ((err (org-tickets--sync-result-error result)))
        (when err
          (setq error-count (1+ error-count))
          (message "org-tickets: Error syncing %s: %s"
                   (or (org-tickets--sync-result-key result) "unknown") err))))
    error-count))

(defun org-tickets--release-ticket-markers (doc)
  "Clear all heading markers in DOC so they stop pinning buffer text."
  (dolist (ticket (org-tickets--doc-tickets doc))
    (let ((m (org-tickets--ticket-marker ticket)))
      (when (markerp m) (set-marker m nil)))))

(defun org-tickets--sync-phase-3 (doc phase-1-results org-buffer)
  "Phase 3: apply all results to the org buffer synchronously.
DOC is the parsed document.  PHASE-1-RESULTS is the list from phase 1.
ORG-BUFFER is the originating buffer.  The buffer is unlocked and the
markers released even when applying a result signals an error."
  (let ((ticket-count (length (org-tickets--doc-tickets doc)))
        (error-count (org-tickets--count-phase-1-errors phase-1-results)))
    (org-tickets--safe-with-buffer
     org-buffer
     (lambda ()
       (unwind-protect
           (let ((inhibit-read-only t))
             (org-tickets--apply-sprint-updates phase-1-results)
             (org-tickets--apply-due-date-updates phase-1-results)
             (org-tickets--apply-synced-updates phase-1-results)
             (org-tickets--apply-due-date-inheritance doc)
             (org-tickets--resolve-blocked-by-in-org doc))
         (org-tickets--sync-cleanup)
         (org-tickets--release-ticket-markers doc))))
    (if (> error-count 0)
        (message "org-tickets: Sync complete (%d tickets, %d errors)"
                 ticket-count error-count)
      (message "org-tickets: Sync complete (%d tickets)" ticket-count))))

(provide 'org-tickets-sync-phases)

;;; org-tickets-sync-phases.el ends here
