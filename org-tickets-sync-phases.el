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

(declare-function org-tickets--set-org-ticket-key "org-tickets-sync")
(declare-function org-tickets--set-org-sprint "org-tickets-sync")
(declare-function org-tickets--set-org-due-date "org-tickets-sync")
(declare-function org-tickets--inherit-due-date "org-tickets-sync")
(defvar org-tickets--remote-parent-cache)
(declare-function org-tickets--ticket-buffer-key "org-tickets-sync")
(declare-function org-tickets--async-sync-ticket-links "org-tickets-sync")
(declare-function org-tickets--sync-cleanup "org-tickets-sync")

;;;; Async Sync Helpers

(defmacro org-tickets--at-ticket-marker (ticket &rest body)
  "Run BODY at TICKET's heading marker, inside `save-excursion'.
BODY runs in the marker's buffer.  Returns nil without running BODY when
the ticket has no marker, or the marker is unset or its buffer killed."
  (declare (indent 1) (debug (form body)))
  (let ((m (make-symbol "marker")))
    `(let ((,m (org-tickets--ticket-marker ,ticket)))
       (when (and (markerp ,m) (marker-position ,m)
                  (buffer-live-p (marker-buffer ,m)))
         (with-current-buffer (marker-buffer ,m)
           (save-excursion
             (goto-char ,m)
             ,@body))))))

(defun org-tickets--ticket-parent-key (ticket)
  "Return the key of TICKET's parent, or nil.
That is TICKET's explicit PARENT property, else the key of the nearest
outline ancestor ticket found from its heading marker."
  (or (org-tickets--ticket-parent ticket)
      (org-tickets--at-ticket-marker ticket
        (org-tickets--find-parent-ticket-key))))

(defun org-tickets--all-features-exist-p (doc)
  "Return non-nil if every feature in DOC has a non-empty JIRA_KEY."
  (seq-every-p (lambda (f)
                 (let ((key (org-tickets--ticket-key f)))
                   (and key (> (length key) 0))))
               (org-tickets--doc-features doc)))

(defun org-tickets--ticket-has-key-p (ticket)
  "Return non-nil if TICKET has a non-empty JIRA_KEY."
  (let ((key (org-tickets--ticket-key ticket)))
    (and key (> (length key) 0))))

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

(defun org-tickets--extract-attachments-from-response (response)
  "Extract attachment list from a GET issue RESPONSE."
  (org-tickets--response-field response "attachment"))

(defun org-tickets--extract-sprint-from-response (response)
  "Extract sprint name from a GET issue RESPONSE."
  (org-tickets--parse-sprint-from-jira-response
   (org-tickets--response-field response org-tickets-sprint-field)))

(defun org-tickets--extract-due-date-from-response (response)
  "Extract due date from a GET issue RESPONSE."
  (org-tickets--response-field response "duedate"))

;;;; Phase 1: Create/Update Tickets

(defun org-tickets--fire-ticket-put (ticket key attachments sprint due-date org-buffer done)
  "Fire async PUT for TICKET with KEY and call DONE when complete.
ATTACHMENTS, SPRINT, DUE-DATE are fetched data from the GET.
ORG-BUFFER is for progress tracking.  DONE is the batch callback."
  (let* ((fields (org-tickets--ticket-fields ticket :attachments attachments))
         (finish (lambda (err)
                   (org-tickets--safe-with-buffer
                    org-buffer #'org-tickets--progress-increment)
                   (funcall done (list :key key :attachments attachments
                                       :sprint sprint :due-date due-date
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
               (funcall done (list :key key :error get-err) nil))
           (let ((attachments (org-tickets--extract-attachments-from-response get-response))
                 (sprint (org-tickets--extract-sprint-from-response get-response))
                 (due-date (org-tickets--extract-due-date-from-response get-response)))
             (org-tickets--fire-ticket-put
              ticket key attachments sprint due-date org-buffer done))))))))

(defun org-tickets--make-new-ticket-thunk (ticket org-buffer)
  "Create a thunk that POSTs TICKET as a new issue from ORG-BUFFER.
The payload is built when the thunk RUNS, not when it is created.
Parent relationships are NOT part of the create payload -- they are
issued as \"Blocks\" links in phase 2 (`org-tickets--async-sync-ticket-links')."
  (lambda (done)
    (let ((fields (org-tickets--safe-with-buffer
                   org-buffer
                   (lambda ()
                     (org-tickets--ticket-fields ticket :create-p t)))))
      (org-tickets--async-request
       "POST" "/rest/api/3/issue"
       (lambda (response err)
         (org-tickets--safe-with-buffer org-buffer #'org-tickets--progress-increment)
         (let ((new-key (when response
                          (org-tickets--alist-get "key" response))))
           (funcall done (list :key new-key :is-new t :error err
                               :sprint (when org-tickets-default-sprint
                                         (format "%s" org-tickets-default-sprint))
                               :ticket ticket)
                    nil)))
       (list (cons 'fields fields))))))

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
       (let ((feature-plists (mapcar #'car feature-results)))
         (org-tickets--with-writable-buffer org-buffer
           (org-tickets--apply-new-keys feature-plists))
         (let ((rest-thunks (mapcar (lambda (tk)
                                      (org-tickets--make-ticket-thunk tk org-buffer))
                                    (org-tickets--doc-non-feature-tickets doc))))
           (org-tickets--async-batch
            rest-thunks
            (lambda (rest-results)
              (org-tickets--sync-phase-2
               doc
               (append feature-plists
                       (mapcar #'car rest-results))
               org-buffer)))))))))

;;;; Phase 2: Attachments + Links

(defun org-tickets--description-attachment-filenames (description)
  "Return filenames referenced by attachment: links in DESCRIPTION."
  (let ((filenames nil)
        (start 0))
    (while (string-match "\\[\\[attachment:\\([^]]+\\)\\]" description start)
      (push (match-string 1 description) filenames)
      (setq start (match-end 0)))
    (nreverse filenames)))

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
                      (org-tickets--extract-attachments-from-response response)))))
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

(defun org-tickets--make-link-thunk (ticket org-buffer)
  "Create a thunk that asynchronously syncs issue links for TICKET.
ORG-BUFFER is the source buffer."
  (lambda (done)
    (org-tickets--async-sync-ticket-links
     ticket org-buffer
     (lambda () (funcall done nil nil)))))

(defun org-tickets--sync-phase-2 (doc phase-1-results org-buffer)
  "Phase 2: sync attachments and issue links concurrently.
DOC is the parsed document.  PHASE-1-RESULTS is the list from phase 1.
ORG-BUFFER is the originating buffer."
  ;; First apply new keys from phase 1 so link/attachment functions can find tickets
  (org-tickets--with-writable-buffer org-buffer
    (org-tickets--apply-new-keys phase-1-results))
  (let ((thunks (org-tickets--build-phase-2-thunks doc phase-1-results org-buffer)))
    (org-tickets--async-batch
     thunks
     (lambda (_results)
       (org-tickets--sync-phase-3 doc phase-1-results org-buffer)))))

(defun org-tickets--phase-1-result-description (doc result)
  "Return the org description for a phase-1 RESULT's ticket, or nil.
New tickets carry their struct in the RESULT plist; existing tickets
are matched by key against DOC's tickets."
  (let ((ticket (or (plist-get result :ticket)
                    (let ((key (plist-get result :key)))
                      (seq-find (lambda (tk)
                                  (equal (org-tickets--ticket-key tk) key))
                                (org-tickets--doc-tickets doc))))))
    (when ticket (org-tickets--ticket-description ticket))))

(defun org-tickets--build-phase-2-thunks (doc phase-1-results org-buffer)
  "Build thunks for phase 2 from DOC, PHASE-1-RESULTS, and ORG-BUFFER."
  (let ((thunks nil))
    ;; Attachment thunks for tickets with keys
    (dolist (result phase-1-results)
      (let ((key (plist-get result :key))
            (attachments (plist-get result :attachments))
            (description (org-tickets--phase-1-result-description doc result)))
        (when (and key (> (length key) 0))
          (push (org-tickets--make-attachment-thunk key attachments org-buffer
                                                 description)
                thunks))))
    ;; Link thunks for all tickets
    (dolist (ticket (org-tickets--doc-tickets doc))
      (push (org-tickets--make-link-thunk ticket org-buffer) thunks))
    (nreverse thunks)))

;;;; Phase 3: Apply Results to Buffer

(defun org-tickets--apply-new-keys (phase-1-results)
  "Write new JIRA_KEYs onto the headings of newly created tickets.
PHASE-1-RESULTS is the list of result plists from phase 1."
  (dolist (result phase-1-results)
    (when (plist-get result :is-new)
      (let ((key (plist-get result :key))
            (ticket (plist-get result :ticket)))
        (when (and key ticket)
          (org-tickets--set-org-ticket-key ticket key))))))

(defun org-tickets--apply-plist-updates (phase-1-results prop setter)
  "Apply PROP from each PHASE-1-RESULTS plist via SETTER.
For every result carrying both a :key and a non-nil PROP value, calls
SETTER with that key and value."
  (dolist (result phase-1-results)
    (let ((key (plist-get result :key))
          (value (plist-get result prop)))
      (when (and key value)
        (funcall setter key value)))))

(defun org-tickets--apply-sprint-updates (phase-1-results)
  "Update SPRINT properties from fetched Jira data.
PHASE-1-RESULTS is the list of result plists from phase 1."
  (org-tickets--apply-plist-updates phase-1-results :sprint
                                 #'org-tickets--set-org-sprint))

(defun org-tickets--apply-due-date-updates (phase-1-results)
  "Update DUE_DATE properties from fetched Jira data.
PHASE-1-RESULTS is the list of result plists from phase 1."
  (org-tickets--apply-plist-updates phase-1-results :due-date
                                 #'org-tickets--set-org-due-date))

(defun org-tickets--apply-due-date-inheritance (doc)
  "Inherit due dates from parent features to child tickets in DOC.
Catches dates that only became known during this run -- a parent whose
DUE_DATE phase 1 fetched from Jira.  Children created during the run are
looked up by the key the buffer just received: their struct was parsed
before the key existed and still holds nil.  A parent absent from the
buffer is fetched from Jira at most once."
  (let ((org-tickets--remote-parent-cache (make-hash-table :test #'equal)))
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
      (let ((err (plist-get result :error)))
        (when err
          (setq error-count (1+ error-count))
          (message "org-tickets: Error syncing %s: %s"
                   (or (plist-get result :key) "unknown") err))))
    error-count))

(defun org-tickets--release-ticket-markers (doc)
  "Clear all heading markers in DOC so they stop pinning buffer text."
  (dolist (ticket (org-tickets--doc-tickets doc))
    (let ((m (org-tickets--ticket-marker ticket)))
      (when (markerp m) (set-marker m nil)))))

(defun org-tickets--sync-phase-3 (doc phase-1-results org-buffer)
  "Phase 3: apply all results to the org buffer synchronously.
DOC is the parsed document.  PHASE-1-RESULTS is the list from phase 1.
ORG-BUFFER is the originating buffer."
  (let ((ticket-count (length (org-tickets--doc-tickets doc)))
        (error-count (org-tickets--count-phase-1-errors phase-1-results)))
    (org-tickets--safe-with-buffer
     org-buffer
     (lambda ()
       (let ((inhibit-read-only t))
         (org-tickets--apply-sprint-updates phase-1-results)
         (org-tickets--apply-due-date-updates phase-1-results)
         (org-tickets--apply-due-date-inheritance doc)
         (org-tickets--resolve-blocked-by-in-org doc))
       (org-tickets--sync-cleanup)
       (org-tickets--release-ticket-markers doc)))
    (if (> error-count 0)
        (message "org-tickets: Sync complete (%d tickets, %d errors)"
                 ticket-count error-count)
      (message "org-tickets: Sync complete (%d tickets)" ticket-count))))

(provide 'org-tickets-sync-phases)

;;; org-tickets-sync-phases.el ends here
