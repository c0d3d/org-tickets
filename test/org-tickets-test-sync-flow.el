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
;; Covers: request consolidation, phase 1 ordering,
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

(ert-deftest org-tickets-test--sync-existing-ticket-uses-correct-endpoints ()
  "Each existing ticket gets exactly one GET and one PUT on its own issue URL."
  (let ((requests nil))
    (org-tickets-test--with-sync-mocks
        (org-tickets-test--fake-jira-handler :log requests)
      (with-temp-buffer
        (org-mode)
        (org-tickets-test--insert-feature "Feature A" "PROJ-10")
        (org-tickets-test--insert-story "Story B" "PROJ-20" "PROJ-10")
        (org-tickets-test--run-sync)))
    (let ((expected '("/rest/api/3/issue/PROJ-10" "/rest/api/3/issue/PROJ-20")))
      (should (equal (sort (mapcar #'cadr (org-tickets-test--requests requests "GET"))
                           #'string<)
                     expected))
      (should (equal (sort (mapcar #'cadr (org-tickets-test--requests requests "PUT"))
                           #'string<)
                     expected)))))

;;;; Tests: all-features-exist-p Batching

(ert-deftest org-tickets-test--all-features-exist-p-true-when-all-have-keys ()
  "all-features-exist-p returns t when every feature has a non-empty JIRA_KEY."
  (let ((doc (org-tickets--doc-create
              :tickets (list
                         (org-tickets--ticket-create :key "PROJ-1" :type "Feature")
                         (org-tickets--ticket-create :key "PROJ-2" :type "Feature")))))
    (should (org-tickets--all-features-exist-p doc))))

(ert-deftest org-tickets-test--all-features-exist-p-false-when-any-lacks-key ()
  "all-features-exist-p returns nil when any feature has no JIRA_KEY."
  (let ((doc (org-tickets--doc-create
              :tickets (list
                         (org-tickets--ticket-create :key "PROJ-1" :type "Feature")
                         (org-tickets--ticket-create :key nil :type "Feature")))))
    (should-not (org-tickets--all-features-exist-p doc))))

(ert-deftest org-tickets-test--all-features-exist-p-false-when-key-empty-string ()
  "all-features-exist-p returns nil when any feature has an empty string key."
  (let ((doc (org-tickets--doc-create
              :tickets (list
                         (org-tickets--ticket-create :key "" :type "Feature")))))
    (should-not (org-tickets--all-features-exist-p doc))))

;;;; Tests: Phase 1 ordering

(defun org-tickets-test--sync-holding-responses (features-lack-keys answer-first)
  "Sync a feature and a new story against a Jira that never answers.
FEATURES-LACK-KEYS non-nil gives the feature no JIRA_KEY.  ANSWER-FIRST
non-nil answers the first request once the sync has stalled.  Return the
requests sent as (METHOD ENDPOINT) pairs, oldest first."
  (let ((log nil)
        (held nil))
    (org-tickets-test--with-sync-mocks
        (lambda (method endpoint callback &optional _data)
          (push (list method endpoint) log)
          (push callback held))
      (with-temp-buffer
        (org-mode)
        (org-tickets-test--insert-feature
         "Feature" (unless features-lack-keys "PROJ-1"))
        (org-tickets-test--insert-story "Story" nil nil)
        (org-tickets-test--run-sync)
        (when answer-first
          (funcall (car (last held)) '((key . "PROJ-7")) nil))))
    (reverse log)))

(ert-deftest org-tickets-test--stories-start-with-existing-features ()
  "When every feature already has a key, the story create goes out alongside
the feature update without waiting for any response."
  (should (equal (org-tickets-test--sync-holding-responses nil nil)
                 '(("GET" "/rest/api/3/issue/PROJ-1")
                   ("POST" "/rest/api/3/issue")))))

(ert-deftest org-tickets-test--stories-wait-for-features-lacking-keys ()
  "A feature without a key is created first; the story is created only
after that create is answered."
  (should (equal (org-tickets-test--sync-holding-responses t nil)
                 '(("POST" "/rest/api/3/issue"))))
  (should (equal (org-tickets-test--sync-holding-responses t t)
                 '(("POST" "/rest/api/3/issue")
                   ("POST" "/rest/api/3/issue")))))

;;;; Tests: Phase 3 Buffer Updates

(ert-deftest org-tickets-test--phase-3-writes-new-key-for-created-ticket ()
  "After sync, a newly created ticket should have its JIRA_KEY set in the buffer."
  (org-tickets-test--with-sync-mocks
      (org-tickets-test--fake-jira-handler :post-keys '("PROJ-999"))
    (with-temp-buffer
      (org-mode)
      ;; Feature with no key — will be POSTed (created)
      (org-tickets-test--insert-feature "Brand New Feature" nil)
      (org-tickets-test--run-sync)
      (goto-char (point-min))
      (should (re-search-forward "Brand New Feature" nil t))
      (should (string= (org-entry-get (point) "JIRA_KEY") "PROJ-999")))))

;;;; Tests: End-to-End Pipeline

(ert-deftest org-tickets-test--end-to-end-mixed-new-and-existing ()
  "Full sync of a buffer with new and existing tickets produces correct final state."
  (let ((requests nil))
    (org-tickets-test--with-sync-mocks
        (org-tickets-test--fake-jira-handler
         :get (org-tickets-test--make-get-response "TestSprint" "2026-09-01")
         :post-keys '("PROJ-NEW-1")
         :log requests)
      (with-temp-buffer
        (org-mode)
        ;; Existing feature
        (org-tickets-test--insert-feature "Existing Feature" "PROJ-100")
        ;; New story (no key) under existing feature
        (org-tickets-test--insert-story "New Story" nil "PROJ-100")
        (org-tickets-test--run-sync)
        ;; Verify: feature got GET+PUT, story got POST
        ;; Since feature has key, all features exist, so single batch
        (should (= 1 (length (org-tickets-test--requests requests "GET"))))
        (should (= 1 (length (org-tickets-test--requests requests "PUT"))))
        (should (= 1 (length (org-tickets-test--requests requests "POST"))))
        ;; Verify sync state is cleaned up
        (should (null org-tickets--sync-in-progress))
        (should (null buffer-read-only))))))

(ert-deftest org-tickets-test--end-to-end-sprint-and-due-date-propagated ()
  "Sprint and due date from Jira are written to org after sync completes."
  (org-tickets-test--with-sync-mocks
      (org-tickets-test--fake-jira-handler
       :get (org-tickets-test--make-get-response "Sprint-42" "2026-12-31"))
    (with-temp-buffer
      (org-mode)
      (org-tickets-test--insert-feature "Feature" "PROJ-50")
      (org-tickets-test--insert-story "Story" "PROJ-51" "PROJ-50")
      (org-tickets-test--run-sync)
      ;; Both tickets get sprint updated
      (dolist (key '("PROJ-50" "PROJ-51"))
        (should (string= (org-tickets-test--prop-of key "SPRINT") "Sprint-42"))
        (should (string= (org-tickets-test--prop-of key "DUE_DATE") "2026-12-31"))))))

;;;; Tests: Buffer Protection

(ert-deftest org-tickets-test--buffer-is-read-only-during-sync ()
  "buffer-read-only is t during sync and nil after sync completes."
  (let ((jira (org-tickets-test--fake-jira-handler))
        (read-only-during-sync nil))
    ;; Capture buffer-read-only state from inside the async request handler,
    ;; which is called while sync is in progress.
    (org-tickets-test--with-sync-mocks
        (lambda (&rest request)
          (setq read-only-during-sync buffer-read-only)
          (apply jira request))
      (with-temp-buffer
        (org-mode)
        (org-tickets-test--insert-feature "Feature" "PROJ-1")
        (org-tickets-test--run-sync)
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
      ;; Sync should not propagate the error to the caller
      (org-tickets-test--run-sync)
      ;; Buffer must be unlocked after the error
      (should (null buffer-read-only))
      (should (null org-tickets--sync-in-progress)))))

(ert-deftest org-tickets-test--reentrant-call-is-rejected ()
  "A second call to org-tickets--sync-to-jira while sync is in progress is rejected."
  (let ((requests nil)
        (message-text nil))
    (org-tickets-test--with-sync-mocks
        (org-tickets-test--fake-jira-handler :log requests)
      (org-tickets-test--with-stubs ((message
                                   (lambda (fmt &rest args)
                                     (setq message-text (apply #'format fmt args)))))
        (with-temp-buffer
          (org-mode)
          (org-tickets-test--insert-feature "Feature" "PROJ-1")
          ;; Manually set in-progress and try to call again
          (setq org-tickets--sync-in-progress t)
          (org-tickets--sync-to-jira)
          ;; No requests — the call was rejected before any were made
          (should (null requests))
          ;; A message should have been emitted
          (should message-text)
          (should (string-match-p "already in progress" message-text)))))))

;;;; Tests: Cursor Preservation

(ert-deftest org-tickets-test--sync-restores-point-to-original-heading ()
  "After sync, point returns to where the user was, not the last ticket synced.
Phase 3 moves point to each ticket as it applies sprint/due-date updates; the
last ticket processed would otherwise leave point far from the user's location."
  (org-tickets-test--with-sync-mocks
      (org-tickets-test--fake-jira-handler
       :get (org-tickets-test--make-get-response "Sprint-9" "2026-10-01"))
    (with-temp-buffer
      (org-mode)
      (org-tickets-test--insert-feature "First Feature" "PROJ-1")
      (org-tickets-test--insert-feature "Second Feature" "PROJ-2")
      (org-tickets-test--insert-feature "Third Feature" "PROJ-3")
      ;; User is sitting on the first feature when they invoke sync.
      (goto-char (point-min))
      (re-search-forward "First Feature")
      (beginning-of-line)
      (org-tickets-test--run-sync)
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
      (goto-char (point-min))
      (re-search-forward "First Feature")
      (beginning-of-line)
      (let ((start-pos (point)))
        (org-tickets-test--run-sync)
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

(ert-deftest org-tickets-test--attachment-thunk-downloads-uploads-then-done-once ()
  "The attachment thunk downloads, then uploads, and calls DONE exactly once.
Calling DONE more than once corrupts the shared batch counter and can
leave the pipeline hung with the buffer stuck read-only."
  (let ((steps nil))
    (org-tickets-test--with-stubs
        ((org-tickets--async-download-attachments
          (lambda (key _atts callback)
            (push (list 'download key) steps)
            (funcall callback nil nil)))
         (org-tickets--async-upload-attachments
          (lambda (key _atts callback)
            (push (list 'upload key) steps)
            (funcall callback nil nil))))
      (with-temp-buffer
        (org-mode)
        (let ((done-count 0)
              (thunk (org-tickets--make-attachment-thunk "PROJ-1" nil (current-buffer))))
          (funcall thunk (lambda (_r _e) (setq done-count (1+ done-count))))
          (should (= done-count 1))
          (should (equal (reverse steps)
                         '((download "PROJ-1") (upload "PROJ-1")))))))))

(ert-deftest org-tickets-test--attachment-thunk-done-once-when-buffer-dead ()
  "Attachment thunk must still call DONE exactly once if ORG-BUFFER is dead."
  (let* ((dead-buffer (generate-new-buffer " *org-tickets-dead*"))
         (thunk (org-tickets--make-attachment-thunk "PROJ-1" nil dead-buffer))
         (done-count 0))
    (kill-buffer dead-buffer)
    (funcall thunk (lambda (_r _e) (setq done-count (1+ done-count))))
    (should (= done-count 1))))

;;;; Async Link Creation Tests

;;;; Tests: Full Pipeline Phase 2 Async

(ert-deftest org-tickets-test--full-pipeline-phase2-async ()
  "Full pipeline: Phase 1 -> Phase 2 (async) -> Phase 3 completes without sync calls."
  (let ((sync-api-calls nil)
        (requests nil))
    (org-tickets-test--with-sync-mocks
        (org-tickets-test--fake-jira-handler
         :get (org-tickets-test--make-get-response "Sprint-1" "2026-06-01")
         :log requests)
        :real (org-tickets--async-sync-ticket-links)
      ;; Ensure no sync API calls happen
      (org-tickets-test--with-stubs ((org-tickets--api-request
                                   (lambda (method endpoint &optional _data)
                                     (push (list method endpoint) sync-api-calls)
                                     nil)))
        (with-temp-buffer
          (org-mode)
          (org-tickets-test--insert-feature "Feature" "PROJ-100")
          (org-tickets-test--insert-story "Story" "PROJ-200" "PROJ-100")
          (org-tickets-test--run-sync))))
    ;; Phase 2 ran: the story's parent link went out asynchronously...
    (should (equal (org-tickets-test--logged-links requests)
                   '(("PROJ-200" "PROJ-100" "Blocks"))))
    ;; ...and no synchronous API calls were made.
    (should (null sync-api-calls))))

;;;; Tests: New Stories NEVER carry a Jira parent field (blocks-link model)

(ert-deftest org-tickets-test--new-story-create-payload-omits-parent ()
  "A new Story under an existing Feature is created WITHOUT a Jira parent
field; the Story->Feature relationship is a \"Blocks\" link made in
phase 2, not a create-payload parent."
  (let ((requests nil))
    (org-tickets-test--with-fake-config
      (with-temp-buffer
        (org-mode)
        (org-tickets-test--insert-feature "Feature" "P-1")
        (org-tickets-test--insert-story "New story" nil nil)
        (let* ((org-tickets--issue-type-ids '(("Story" . "1") ("New Feature" . "2")))
               (doc (org-tickets--parse-document))
               (story (car (org-tickets--doc-children doc))))
          (org-tickets-test--with-stubs ((org-tickets--async-request
                                       (org-tickets-test--fake-jira-handler
                                        :post-keys '("P-2") :log requests)))
            (funcall (org-tickets--make-ticket-thunk story (current-buffer))
                     #'ignore)))))
    (let ((posts (org-tickets-test--requests requests "POST" "/rest/api/3/issue")))
      (should (= 1 (length posts)))
      (should-not (assq 'parent (cdr (assq 'fields (nth 2 (car posts)))))))))

(ert-deftest org-tickets-test--sequential-mode-story-payload-omits-parent ()
  "Fresh doc (new feature + new story): even in sequential mode the
story's create payload carries no Jira parent field."
  (let ((requests nil))
    (org-tickets-test--with-fake-config
      (with-temp-buffer
        (org-mode)
        (org-tickets-test--insert-feature "New feature" nil)
        (org-tickets-test--insert-story "New story" nil nil)
        (let ((org-tickets--issue-type-ids '(("Story" . "1") ("New Feature" . "2"))))
          (org-tickets-test--with-stubs ((org-tickets--async-request
                                       (org-tickets-test--fake-jira-handler
                                        :post-keys '("P-10" "P-11") :log requests))
                                      ;; Stop the pipeline after phase 1.
                                      (org-tickets--sync-phase-2
                                       (lambda (&rest _))))
            (org-tickets--sync-phase-1-sequential (org-tickets--parse-document)
                                                  (current-buffer))))))
    (let ((story-post (seq-find
                       (lambda (request)
                         (equal (org-tickets-test--payload-field (nth 2 request) 'summary)
                                "New story"))
                       (org-tickets-test--requests requests "POST" "/rest/api/3/issue"))))
      (should story-post)
      (should-not (assq 'parent (cdr (assq 'fields (nth 2 story-post))))))))

;;;; Phase 3 BLOCKED-BY write-back

(ert-deftest org-tickets-test--blocked-by-populates-blocks-idempotent ()
  "Test that resolving BLOCKED-BY twice doesn't create duplicate BLOCKS entries."
  (with-temp-buffer
    (insert "* Parent Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:BLOCKS:
:END:
** Child Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:BLOCKED-BY: PROJ-100
:END:
")
    (org-mode)
    (let ((doc (org-tickets--parse-document)))
      ;; Resolve twice
      (org-tickets--resolve-blocked-by-in-org doc)
      ;; Re-parse to get updated state
      (let ((doc2 (org-tickets--parse-document)))
        (org-tickets--resolve-blocked-by-in-org doc2))
      ;; PROJ-100 BLOCKS should contain PROJ-200 exactly once
      (goto-char (point-min))
      (re-search-forward "PROJ-100" nil t)
      (let ((blocks (org-entry-get (point) "BLOCKS")))
        (should blocks)
        ;; Count occurrences of PROJ-200
        (let ((count 0)
              (start 0))
          (while (string-match "PROJ-200" blocks start)
            (setq count (1+ count))
            (setq start (match-end 0)))
          (should (= count 1)))))))

(ert-deftest org-tickets-test--blocked-by-populates-blocks-in-org ()
  "Test that BLOCKED-BY on a story auto-populates BLOCKS on the target ticket.
When Story PROJ-200 has BLOCKED-BY: PROJ-100, then PROJ-100 should get
BLOCKS: PROJ-200 in its org properties."
  (with-temp-buffer
    (insert "* Parent Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:BLOCKS:
:END:
** Child Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:BLOCKED-BY: PROJ-100
:END:
")
    (org-mode)
    (let ((doc (org-tickets--parse-document)))
      ;; Resolve blocked-by → blocks in org buffer
      (org-tickets--resolve-blocked-by-in-org doc)
      ;; Verify PROJ-100 now has BLOCKS containing PROJ-200
      (goto-char (point-min))
      (re-search-forward "PROJ-100" nil t)
      (let ((blocks (org-entry-get (point) "BLOCKS")))
        (should blocks)
        (should (string-match-p "PROJ-200" blocks))))))

(provide 'org-tickets-test-sync-flow)
;;; org-tickets-test-sync-flow.el ends here
