;;; org-tickets-test-sync-flow.el --- Tests for consolidated async sync flow  -*- lexical-binding: t; -*-

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

;; Tests for the consolidated async sync flow.
;; Covers: request consolidation, all-features-exist-p batching,
;; buffer updates after sync (phase 3), end-to-end pipeline,
;; and buffer protection (read-only + re-entrancy guard).

;;; Code:

(require 'ert)
(require 'org-tickets-test-fixtures)

(require 'org-tickets)
(require 'org-tickets-sync-phases)

;; The sync harness (`org-tickets-test--with-sync-mocks', the heading builders
;; and `org-tickets-test--make-get-response') lives in org-tickets-test-fixtures.el
;; so the due-date-inheritance suite can drive the same pipeline.

;;;; Tests: Request Consolidation

(ert-deftest org-tickets-test--sync-existing-ticket-uses-1-get-1-put ()
  "An existing ticket should produce exactly 1 GET and 1 PUT, not more."
  (let ((get-calls nil)
        (put-calls nil))
    (org-tickets-test--with-sync-mocks
        (lambda (method endpoint callback &optional _data)
          (cond
           ((string= method "GET")
            (push endpoint get-calls)
            (funcall callback (org-tickets-test--make-get-response "Sprint-1" "2026-06-01") nil))
           ((string= method "PUT")
            (push endpoint put-calls)
            (funcall callback nil nil))))
      (with-temp-buffer
        (org-mode)
        (org-tickets-test--insert-feature "Test Feature" "PROJ-100")
        (setq org-tickets--sync-in-progress nil)
        (setq buffer-read-only nil)
        (make-local-variable 'mode-line-misc-info)
        (setq mode-line-misc-info nil)
        (org-tickets--sync-to-jira)))
    (should (= 1 (length get-calls)))
    (should (string= (car get-calls) "/rest/api/3/issue/PROJ-100"))
    (should (= 1 (length put-calls)))
    (should (string= (car put-calls) "/rest/api/3/issue/PROJ-100"))))

(ert-deftest org-tickets-test--sync-existing-ticket-uses-correct-endpoints ()
  "Verify GET and PUT use the correct /rest/api/3/issue/{key} endpoints."
  (let ((all-endpoints nil))
    (org-tickets-test--with-sync-mocks
        (lambda (method endpoint callback &optional _data)
          (push (cons method endpoint) all-endpoints)
          (cond
           ((string= method "GET")
            (funcall callback (org-tickets-test--make-get-response) nil))
           ((string= method "PUT")
            (funcall callback nil nil))))
      (with-temp-buffer
        (org-mode)
        (org-tickets-test--insert-feature "Feature A" "PROJ-10")
        (org-tickets-test--insert-story "Story B" "PROJ-20" "PROJ-10")
        (setq org-tickets--sync-in-progress nil)
        (setq buffer-read-only nil)
        (make-local-variable 'mode-line-misc-info)
        (setq mode-line-misc-info nil)
        (org-tickets--sync-to-jira)))
    ;; Should have exactly one GET and one PUT per ticket (2 tickets total)
    (let ((gets (seq-filter (lambda (e) (string= (car e) "GET")) all-endpoints))
          (puts (seq-filter (lambda (e) (string= (car e) "PUT")) all-endpoints)))
      (should (= 2 (length gets)))
      (should (= 2 (length puts)))
      (should (member (cons "GET" "/rest/api/3/issue/PROJ-10") all-endpoints))
      (should (member (cons "GET" "/rest/api/3/issue/PROJ-20") all-endpoints))
      (should (member (cons "PUT" "/rest/api/3/issue/PROJ-10") all-endpoints))
      (should (member (cons "PUT" "/rest/api/3/issue/PROJ-20") all-endpoints)))))

;;;; Tests: all-features-exist-p Batching

(ert-deftest org-tickets-test--all-features-exist-p-true-when-all-have-keys ()
  "all-features-exist-p returns t when every feature has a non-empty JIRA_KEY."
  (let ((doc (org-tickets--doc-create
              :features (list
                         (org-tickets--ticket-create :key "PROJ-1" :type "Feature")
                         (org-tickets--ticket-create :key "PROJ-2" :type "Feature"))
              :children nil
              :tickets nil)))
    (should (org-tickets--all-features-exist-p doc))))

(ert-deftest org-tickets-test--all-features-exist-p-false-when-any-lacks-key ()
  "all-features-exist-p returns nil when any feature has no JIRA_KEY."
  (let ((doc (org-tickets--doc-create
              :features (list
                         (org-tickets--ticket-create :key "PROJ-1" :type "Feature")
                         (org-tickets--ticket-create :key nil :type "Feature"))
              :children nil
              :tickets nil)))
    (should-not (org-tickets--all-features-exist-p doc))))

(ert-deftest org-tickets-test--all-features-exist-p-false-when-key-empty-string ()
  "all-features-exist-p returns nil when any feature has an empty string key."
  (let ((doc (org-tickets--doc-create
              :features (list
                         (org-tickets--ticket-create :key "" :type "Feature"))
              :children nil
              :tickets nil)))
    (should-not (org-tickets--all-features-exist-p doc))))

(ert-deftest org-tickets-test--batching-single-batch-when-all-features-have-keys ()
  "When all features have keys, all tickets fire in a single async-batch call."
  (let ((batch-calls 0)
        (orig-batch (symbol-function 'org-tickets--async-batch)))
    (org-tickets-test--with-stubs ((org-tickets--async-batch
                                 (lambda (thunks callback)
                                   (setq batch-calls (1+ batch-calls))
                                   (funcall orig-batch thunks callback))))
      (org-tickets-test--with-sync-mocks
          (lambda (method _endpoint callback &optional _data)
            (cond
             ((string= method "GET")
              (funcall callback (org-tickets-test--make-get-response) nil))
             ((string= method "PUT")
              (funcall callback nil nil))
             ((string= method "POST")
              (funcall callback (list (cons "key" "PROJ-NEW")) nil))))
        (with-temp-buffer
          (org-mode)
          (org-tickets-test--insert-feature "Feature A" "PROJ-1")
          (org-tickets-test--insert-story "Story B" "PROJ-2" "PROJ-1")
          (setq org-tickets--sync-in-progress nil)
          (setq buffer-read-only nil)
          (make-local-variable 'mode-line-misc-info)
          (setq mode-line-misc-info nil)
          (org-tickets--sync-to-jira))))
    ;; Phase 1 fires 1 batch (all tickets), phase 2 fires 1 batch (attachments+links)
    ;; So total should be 2 batches (not 3 which would be the sequential case)
    (should (= 2 batch-calls))))

(ert-deftest org-tickets-test--batching-sequential-when-feature-lacks-key ()
  "When a feature lacks a key, features batch fires first, then stories batch.
This produces 3 total batch calls instead of 2 (vs. the single-batch path)."
  (let ((batch-calls 0)
        (orig-batch (symbol-function 'org-tickets--async-batch)))
    (org-tickets-test--with-stubs ((org-tickets--async-batch
                                 (lambda (thunks callback)
                                   (setq batch-calls (1+ batch-calls))
                                   (funcall orig-batch thunks callback))))
      (org-tickets-test--with-sync-mocks
          (lambda (method _endpoint callback &optional _data)
            (cond
             ((string= method "GET")
              (funcall callback (org-tickets-test--make-get-response) nil))
             ((string= method "PUT")
              (funcall callback nil nil))
             ((string= method "POST")
              (funcall callback (list (cons "key" "PROJ-NEW")) nil))))
        (with-temp-buffer
          (org-mode)
          ;; Feature has no key — triggers sequential path
          (org-tickets-test--insert-feature "New Feature" nil)
          (org-tickets-test--insert-story "Story A" "PROJ-2" nil)
          (setq org-tickets--sync-in-progress nil)
          (setq buffer-read-only nil)
          (make-local-variable 'mode-line-misc-info)
          (setq mode-line-misc-info nil)
          (org-tickets--sync-to-jira))))
    ;; Phase 1 sequential: batch 1 = features, batch 2 = stories (nested inside batch 1
    ;; completion callback), phase 2 = batch 3.
    ;; This is 3 total vs 2 for the all-features-exist path.
    (should (= 3 batch-calls))))

;;;; Tests: Phase 3 Buffer Updates

(ert-deftest org-tickets-test--phase-3-updates-sprint-property ()
  "After sync, SPRINT property should reflect the sprint returned by Jira GET."
  (org-tickets-test--with-sync-mocks
      (lambda (method _endpoint callback &optional _data)
        (cond
         ((string= method "GET")
          (funcall callback (org-tickets-test--make-get-response "May26_S4-Totoro" nil) nil))
         ((string= method "PUT")
          (funcall callback nil nil))))
    (with-temp-buffer
      (org-mode)
      (org-tickets-test--insert-feature "My Feature" "PROJ-100")
      (setq org-tickets--sync-in-progress nil)
      (setq buffer-read-only nil)
      (make-local-variable 'mode-line-misc-info)
      (setq mode-line-misc-info nil)
      (org-tickets--sync-to-jira)
      (goto-char (point-min))
      (re-search-forward "PROJ-100" nil t)
      (should (string= (org-entry-get (point) "SPRINT") "May26_S4-Totoro")))))

(ert-deftest org-tickets-test--phase-3-updates-due-date-property ()
  "After sync, DUE_DATE property should reflect the due date returned by Jira GET."
  (org-tickets-test--with-sync-mocks
      (lambda (method _endpoint callback &optional _data)
        (cond
         ((string= method "GET")
          (funcall callback (org-tickets-test--make-get-response nil "2026-08-01") nil))
         ((string= method "PUT")
          (funcall callback nil nil))))
    (with-temp-buffer
      (org-mode)
      (org-tickets-test--insert-feature "My Feature" "PROJ-100")
      (setq org-tickets--sync-in-progress nil)
      (setq buffer-read-only nil)
      (make-local-variable 'mode-line-misc-info)
      (setq mode-line-misc-info nil)
      (org-tickets--sync-to-jira)
      (goto-char (point-min))
      (re-search-forward "PROJ-100" nil t)
      (should (string= (org-entry-get (point) "DUE_DATE") "2026-08-01")))))

(ert-deftest org-tickets-test--phase-3-writes-new-key-for-created-ticket ()
  "After sync, a newly created ticket should have its JIRA_KEY set in the buffer."
  (org-tickets-test--with-sync-mocks
      (lambda (method _endpoint callback &optional _data)
        (cond
         ((string= method "POST")
          (funcall callback (list (cons "key" "PROJ-999")) nil))
         ((string= method "PUT")
          (funcall callback nil nil))
         ((string= method "GET")
          (funcall callback (org-tickets-test--make-get-response) nil))))
    (with-temp-buffer
      (org-mode)
      ;; Feature with no key — will be POSTed (created)
      (org-tickets-test--insert-feature "Brand New Feature" nil)
      (setq org-tickets--sync-in-progress nil)
      (setq buffer-read-only nil)
      (make-local-variable 'mode-line-misc-info)
      (setq mode-line-misc-info nil)
      (org-tickets--sync-to-jira)
      (goto-char (point-min))
      (should (re-search-forward "Brand New Feature" nil t))
      (should (string= (org-entry-get (point) "JIRA_KEY") "PROJ-999")))))

;;;; Tests: End-to-End Pipeline

(ert-deftest org-tickets-test--end-to-end-mixed-new-and-existing ()
  "Full sync of a buffer with new and existing tickets produces correct final state."
  (let ((post-count 0)
        (get-count 0)
        (put-count 0))
    (org-tickets-test--with-sync-mocks
        (lambda (method endpoint callback &optional _data)
          (cond
           ((string= method "GET")
            (setq get-count (1+ get-count))
            (funcall callback (org-tickets-test--make-get-response "TestSprint" "2026-09-01") nil))
           ((string= method "PUT")
            (setq put-count (1+ put-count))
            (funcall callback nil nil))
           ((string= method "POST")
            (setq post-count (1+ post-count))
            ;; Return a unique key based on what endpoint was called
            (let ((new-key (if (string-match "PROJ-" (or endpoint ""))
                               "PROJ-NEW-2"
                             "PROJ-NEW-1")))
              (funcall callback (list (cons "key" new-key)) nil)))))
      (with-temp-buffer
        (org-mode)
        ;; Existing feature
        (org-tickets-test--insert-feature "Existing Feature" "PROJ-100")
        ;; New story (no key) under existing feature
        (org-tickets-test--insert-story "New Story" nil "PROJ-100")
        (setq org-tickets--sync-in-progress nil)
        (setq buffer-read-only nil)
        (make-local-variable 'mode-line-misc-info)
        (setq mode-line-misc-info nil)
        (org-tickets--sync-to-jira)
        ;; Verify: feature got GET+PUT, story got POST
        ;; Since feature has key, all features exist, so single batch
        (should (= 1 get-count))   ; existing feature: GET
        (should (= 1 put-count))   ; existing feature: PUT
        (should (= 1 post-count))  ; new story: POST
        ;; Verify sync state is cleaned up
        (should (null org-tickets--sync-in-progress))
        (should (null buffer-read-only))))))

(ert-deftest org-tickets-test--end-to-end-sprint-and-due-date-propagated ()
  "Sprint and due date from Jira are written to org after sync completes."
  (org-tickets-test--with-sync-mocks
      (lambda (method _endpoint callback &optional _data)
        (cond
         ((string= method "GET")
          (funcall callback (org-tickets-test--make-get-response "Sprint-42" "2026-12-31") nil))
         ((string= method "PUT")
          (funcall callback nil nil))))
    (with-temp-buffer
      (org-mode)
      (org-tickets-test--insert-feature "Feature" "PROJ-50")
      (org-tickets-test--insert-story "Story" "PROJ-51" "PROJ-50")
      (setq org-tickets--sync-in-progress nil)
      (setq buffer-read-only nil)
      (make-local-variable 'mode-line-misc-info)
      (setq mode-line-misc-info nil)
      (org-tickets--sync-to-jira)
      ;; Both tickets get sprint updated
      (goto-char (point-min))
      (re-search-forward "PROJ-50" nil t)
      (should (string= (org-entry-get (point) "SPRINT") "Sprint-42"))
      (should (string= (org-entry-get (point) "DUE_DATE") "2026-12-31"))
      (goto-char (point-min))
      (re-search-forward "PROJ-51" nil t)
      (should (string= (org-entry-get (point) "SPRINT") "Sprint-42"))
      (should (string= (org-entry-get (point) "DUE_DATE") "2026-12-31")))))

;;;; Tests: Buffer Protection

(ert-deftest org-tickets-test--buffer-is-read-only-during-sync ()
  "buffer-read-only is t during sync and nil after sync completes."
  (let (read-only-during-sync)
    ;; Capture buffer-read-only state from inside the async request handler,
    ;; which is called while sync is in progress.
    (org-tickets-test--with-sync-mocks
        (lambda (method _endpoint callback &optional _data)
          (setq read-only-during-sync buffer-read-only)
          (cond
           ((string= method "GET")
            (funcall callback (org-tickets-test--make-get-response) nil))
           ((string= method "PUT")
            (funcall callback nil nil))))
      (with-temp-buffer
        (org-mode)
        (org-tickets-test--insert-feature "Feature" "PROJ-1")
        (setq org-tickets--sync-in-progress nil)
        (setq buffer-read-only nil)
        (make-local-variable 'mode-line-misc-info)
        (setq mode-line-misc-info nil)
        (org-tickets--sync-to-jira)
        ;; After sync, buffer should not be read-only
        (should (null buffer-read-only))))
    ;; During sync (captured inside the mock), it should have been t
    (should read-only-during-sync)))

(ert-deftest org-tickets-test--buffer-unlocked-after-sync-error ()
  "buffer-read-only and sync-in-progress are cleared when sync signals an error."
  (org-tickets-test--with-sync-mocks
      (lambda (_method _endpoint _callback &optional _data)
        (error "Simulated network failure"))
    (with-temp-buffer
      (org-mode)
      (org-tickets-test--insert-feature "Feature" "PROJ-1")
      (setq org-tickets--sync-in-progress nil)
      (setq buffer-read-only nil)
      (make-local-variable 'mode-line-misc-info)
      (setq mode-line-misc-info nil)
      ;; Sync should not propagate the error to the caller
      (org-tickets--sync-to-jira)
      ;; Buffer must be unlocked after the error
      (should (null buffer-read-only))
      (should (null org-tickets--sync-in-progress)))))

(ert-deftest org-tickets-test--reentrant-call-is-rejected ()
  "A second call to org-tickets--sync-to-jira while sync is in progress is rejected."
  (let ((request-count 0)
        (message-text nil))
    (org-tickets-test--with-sync-mocks
        (lambda (method _endpoint callback &optional _data)
          (setq request-count (1+ request-count))
          (cond
           ((string= method "GET")
            (funcall callback (org-tickets-test--make-get-response) nil))
           ((string= method "PUT")
            (funcall callback nil nil))))
      (org-tickets-test--with-stubs ((message
                                   (lambda (fmt &rest args)
                                     (setq message-text (apply #'format fmt args)))))
        (with-temp-buffer
          (org-mode)
          (org-tickets-test--insert-feature "Feature" "PROJ-1")
          (setq org-tickets--sync-in-progress nil)
          (setq buffer-read-only nil)
          (make-local-variable 'mode-line-misc-info)
          (setq mode-line-misc-info nil)
          ;; Manually set in-progress and try to call again
          (setq org-tickets--sync-in-progress t)
          (org-tickets--sync-to-jira)
          ;; Request count should be 0 — the call was rejected before any requests
          (should (= 0 request-count))
          ;; A message should have been emitted
          (should message-text)
          (should (string-match-p "already in progress" message-text)))))))

(ert-deftest org-tickets-test--sync-in-progress-nil-after-sync ()
  "org-tickets--sync-in-progress is nil after sync completes normally."
  (org-tickets-test--with-sync-mocks
      (lambda (method _endpoint callback &optional _data)
        (cond
         ((string= method "GET")
          (funcall callback (org-tickets-test--make-get-response) nil))
         ((string= method "PUT")
          (funcall callback nil nil))))
    (with-temp-buffer
      (org-mode)
      (org-tickets-test--insert-feature "Feature" "PROJ-1")
      (setq org-tickets--sync-in-progress nil)
      (setq buffer-read-only nil)
      (make-local-variable 'mode-line-misc-info)
      (setq mode-line-misc-info nil)
      (org-tickets--sync-to-jira)
      (should (null org-tickets--sync-in-progress)))))

;;;; Tests: Cursor Preservation

(ert-deftest org-tickets-test--sync-restores-point-to-original-heading ()
  "After sync, point returns to where the user was, not the last ticket synced.
Phase 3 moves point to each ticket as it applies sprint/due-date updates; the
last ticket processed would otherwise leave point far from the user's location."
  (org-tickets-test--with-sync-mocks
      (lambda (method _endpoint callback &optional _data)
        (cond
         ((string= method "GET")
          (funcall callback (org-tickets-test--make-get-response "Sprint-9" "2026-10-01") nil))
         ((string= method "PUT")
          (funcall callback nil nil))))
    (with-temp-buffer
      (org-mode)
      (org-tickets-test--insert-feature "First Feature" "PROJ-1")
      (org-tickets-test--insert-feature "Second Feature" "PROJ-2")
      (org-tickets-test--insert-feature "Third Feature" "PROJ-3")
      (setq org-tickets--sync-in-progress nil)
      (setq buffer-read-only nil)
      (make-local-variable 'mode-line-misc-info)
      (setq mode-line-misc-info nil)
      ;; User is sitting on the first feature when they invoke sync.
      (goto-char (point-min))
      (re-search-forward "First Feature")
      (beginning-of-line)
      (org-tickets--sync-to-jira)
      ;; Point should be back on the first feature, not the last one synced.
      (should (string= (org-get-heading t t t t) "First Feature"))
      ;; The saved markers must be released so they don't burden future edits.
      (should (null org-tickets--sync-saved-point))
      (should (null org-tickets--sync-saved-window-start)))))

(ert-deftest org-tickets-test--sync-restores-point-after-error ()
  "Point is restored even when the sync pipeline errors out."
  (org-tickets-test--with-sync-mocks
      (lambda (_method _endpoint _callback &optional _data)
        (error "Simulated network failure"))
    (with-temp-buffer
      (org-mode)
      (org-tickets-test--insert-feature "First Feature" "PROJ-1")
      (org-tickets-test--insert-feature "Second Feature" "PROJ-2")
      (setq org-tickets--sync-in-progress nil)
      (setq buffer-read-only nil)
      (make-local-variable 'mode-line-misc-info)
      (setq mode-line-misc-info nil)
      (goto-char (point-min))
      (re-search-forward "First Feature")
      (beginning-of-line)
      (let ((start-pos (point)))
        (org-tickets--sync-to-jira)
        (should (= (point) start-pos))
        (should (null org-tickets--sync-saved-point))))))

(ert-deftest org-tickets-test--sync-restore-point-noop-when-nothing-saved ()
  "Restore is a graceful no-op when no location was ever saved."
  (with-temp-buffer
    (org-mode)
    (insert "* Heading\n")
    (goto-char (point-min))
    (setq org-tickets--sync-saved-point nil)
    (setq org-tickets--sync-saved-window-start nil)
    (let ((pos (point)))
      (org-tickets--sync-restore-point)
      (should (= (point) pos)))))

;;;; Tests: Phase 2 Async Thunks

(ert-deftest org-tickets-test--phase2-thunks-use-async ()
  "Phase 2 attachment thunk should call async download then upload."
  (let ((download-calls nil)
        (upload-calls nil)
        (link-calls nil))
    (org-tickets-test--with-stubs ((org-tickets--async-download-attachments
                                 (lambda (key attachments callback)
                                   (push key download-calls)
                                   (funcall callback nil nil)))
                                (org-tickets--async-upload-attachments
                                 (lambda (key jira-attachments callback)
                                   (push key upload-calls)
                                   (funcall callback nil nil)))
                                (org-tickets--async-sync-ticket-links
                                 (lambda (ticket callback)
                                   (push (org-tickets--ticket-key ticket) link-calls)
                                   (funcall callback)))
                                (org-tickets--safe-with-buffer
                                 (lambda (buffer body-fn) (funcall body-fn))))
      ;; Build a fake attachment thunk
      (let* ((result-plist (list :key "PROJ-1" :attachments '(("a")) :is-new nil))
             (thunk (org-tickets--make-attachment-thunk
                     "PROJ-1" '(("a")) (current-buffer)))
             (done-result nil))
        (funcall thunk (lambda (r e) (setq done-result t)))
        (should done-result)
        (should (equal download-calls '("PROJ-1")))
        (should (equal upload-calls '("PROJ-1")))))))

(ert-deftest org-tickets-test--attachment-thunk-calls-done-exactly-once ()
  "Attachment thunk must call DONE exactly once (async-batch contract).
Uses the real `org-tickets--safe-with-buffer' so control flow is not hidden.
Calling DONE more than once corrupts the shared batch counter and can
leave the pipeline hung with the buffer stuck read-only."
  (org-tickets-test--with-stubs ((org-tickets--async-download-attachments
                               (lambda (_key _atts callback) (funcall callback nil nil)))
                              (org-tickets--async-upload-attachments
                               (lambda (_key _atts callback) (funcall callback nil nil))))
    (with-temp-buffer
      (org-mode)
      (let ((done-count 0)
            (thunk (org-tickets--make-attachment-thunk "PROJ-1" nil (current-buffer))))
        (funcall thunk (lambda (_r _e) (setq done-count (1+ done-count))))
        (should (= done-count 1))))))

(ert-deftest org-tickets-test--attachment-thunk-done-once-when-buffer-dead ()
  "Attachment thunk must still call DONE exactly once if ORG-BUFFER is dead."
  (let* ((dead-buffer (generate-new-buffer " *org-tickets-dead*"))
         (thunk (org-tickets--make-attachment-thunk "PROJ-1" nil dead-buffer))
         (done-count 0))
    (kill-buffer dead-buffer)
    (funcall thunk (lambda (_r _e) (setq done-count (1+ done-count))))
    (should (= done-count 1))))

;;;; Async Link Creation Tests

(ert-deftest org-tickets-test--async-create-link-fires-post ()
  "Async create link should POST to issueLink endpoint."
  (let ((request-calls nil))
    (org-tickets-test--with-stubs ((org-tickets--async-request
                                 (lambda (method endpoint callback &optional data)
                                   (push (list method endpoint data) request-calls)
                                   (funcall callback nil nil))))
      (let ((result nil))
        (org-tickets--async-create-link "PROJ-1" "PROJ-2" "Blocks"
                                     (lambda (response err)
                                       (setq result (list response err))))
        (should (= (length request-calls) 1))
        (let ((call (car request-calls)))
          (should (string= (nth 0 call) "POST"))
          (should (string= (nth 1 call) "/rest/api/3/issueLink"))
          (let ((data (nth 2 call)))
            (should (equal (cdr (assoc "inwardIssue" data))
                           (list (cons "key" "PROJ-1"))))
            (should (equal (cdr (assoc "outwardIssue" data))
                           (list (cons "key" "PROJ-2"))))))))))

(ert-deftest org-tickets-test--async-sync-ticket-links-story ()
  "Async sync ticket links should create parent + blocks + blocked-by links."
  (let ((link-calls nil))
    (org-tickets-test--with-stubs ((org-tickets--async-create-link
                                 (lambda (from to type callback)
                                   (push (list from to type) link-calls)
                                   (funcall callback nil nil))))
      (with-temp-buffer
        (org-mode)
        (insert "* Feature\n")
        (org-entry-put (point) "JIRA_KEY" "PROJ-100")
        (org-entry-put (point) "JIRA_TYPE" "Feature")
        (insert "** Story\n")
        (org-entry-put (point) "JIRA_KEY" "PROJ-200")
        (org-entry-put (point) "JIRA_TYPE" "Story")
        (org-entry-put (point) "PARENT" "PROJ-100")
        (org-entry-put (point) "BLOCKS" "PROJ-300")
        (let* ((doc (org-tickets--parse-document))
               (story (car (org-tickets--doc-children doc)))
               (result nil))
          (org-tickets--async-sync-ticket-links
           story (lambda () (setq result t)))
          (should result)
          ;; Should have: parent link + blocks link = 2 calls
          (should (= (length link-calls) 2))
          ;; Parent link: story blocks parent
          (should (member (list "PROJ-200" "PROJ-100" "Blocks") link-calls))
          ;; Explicit blocks link
          (should (member (list "PROJ-200" "PROJ-300" "Blocks") link-calls)))))))

;;;; Tests: Full Pipeline Phase 2 Async

(ert-deftest org-tickets-test--full-pipeline-phase2-async ()
  "Full pipeline: Phase 1 -> Phase 2 (async) -> Phase 3 completes without sync calls."
  (let ((sync-api-calls nil)
        (async-calls nil))
    (org-tickets-test--with-sync-mocks
        (lambda (method endpoint callback &optional data)
          (push (list method endpoint) async-calls)
          (cond
           ((string= method "GET")
            (funcall callback (org-tickets-test--make-get-response "Sprint-1" "2026-06-01") nil))
           ((string= method "PUT")
            (funcall callback nil nil))
           ((string= method "POST")
            (if (string-match "issueLink" endpoint)
                (funcall callback nil nil)
              (funcall callback (list (cons "key" "PROJ-NEW")) nil)))))
      ;; Ensure no sync API calls happen
      (org-tickets-test--with-stubs ((org-tickets--api-request
                                   (lambda (method endpoint &optional data)
                                     (push (list method endpoint) sync-api-calls)
                                     nil))
                                  (org-tickets--async-download-attachments
                                   (lambda (_key _atts callback) (funcall callback nil nil)))
                                  (org-tickets--async-upload-attachments
                                   (lambda (_key _atts callback) (funcall callback nil nil)))
                                  (org-tickets--async-sync-ticket-links
                                   (lambda (_ticket callback) (funcall callback))))
        (with-temp-buffer
          (org-mode)
          (org-tickets-test--insert-feature "Feature" "PROJ-100")
          (org-tickets-test--insert-story "Story" "PROJ-200" "PROJ-100")
          (setq org-tickets--sync-in-progress nil)
          (setq buffer-read-only nil)
          (make-local-variable 'mode-line-misc-info)
          (setq mode-line-misc-info nil)
          (org-tickets--sync-to-jira)
          ;; No synchronous API calls should have been made during Phase 2
          (should (null sync-api-calls)))))))

;;;; Tests: New Stories NEVER carry a Jira parent field (blocks-link model)

(ert-deftest org-tickets-test--new-story-create-payload-omits-parent ()
  "A new Story under an existing Feature is created WITHOUT a Jira parent
field; the Story->Feature relationship is a \"Blocks\" link made in
phase 2, not a create-payload parent."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n:END:\n"
            "** New story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:END:\n")
    (let* ((org-tickets-project-id "12345")
           (org-tickets--issue-type-ids '(("Story" . "1") ("New Feature" . "2")))
           (doc (org-tickets--parse-document))
           (story (car (org-tickets--doc-children doc)))
           (sent nil))
      (org-tickets-test--with-stubs ((org-tickets--async-request
                                   (lambda (_m _e callback &optional data)
                                     (setq sent data)
                                     (funcall callback '((key . "P-2")) nil))))
        (let ((thunk (org-tickets--make-ticket-thunk story (current-buffer))))
          (funcall thunk (lambda (_r _e)))))
      (let ((fields (cdr (assq 'fields sent))))
        (should-not (assq 'parent fields))))))

(ert-deftest org-tickets-test--sequential-mode-story-payload-omits-parent ()
  "Fresh doc (new feature + new story): even in sequential mode the
story's create payload carries no Jira parent field."
  (with-temp-buffer
    (org-mode)
    (insert "* New feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:END:\n"
            "** New story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:END:\n")
    (let* ((org-tickets-project-id "12345")
           (org-tickets--issue-type-ids '(("Story" . "1") ("New Feature" . "2")))
           (doc (org-tickets--parse-document))
           (created-keys '("P-10" "P-11"))
           (story-has-parent 'unset))
      (org-tickets-test--with-stubs ((org-tickets--async-request
                                   (lambda (_m _e callback &optional data)
                                     (let ((fields (cdr (assq 'fields data))))
                                       (when (equal (cdr (assq 'issuetype fields)) '(("id" . "1")))
                                         (setq story-has-parent (and (assq 'parent fields) t))))
                                     (funcall callback (list (cons 'key (pop created-keys))) nil)))
                                  ;; Stop the pipeline after phase 1.
                                  (org-tickets--sync-phase-2
                                   (lambda (&rest _))))
        (org-tickets--sync-phase-1-sequential doc (current-buffer)))
      (should (eq story-has-parent nil)))))

(provide 'org-tickets-test-sync-flow)
;;; org-tickets-test-sync-flow.el ends here
