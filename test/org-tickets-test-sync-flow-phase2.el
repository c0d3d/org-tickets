;;; org-tickets-test-sync-flow-phase2.el --- Phase-2 thunk tests (overflow)  -*- lexical-binding: t; -*-

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

;; Overflow of org-tickets-test-sync-flow.el's "Phase 2 Async Thunks"
;; section, split out to keep that file under the 750-line limit (see
;; docs/dev/testing.md: split by module tested / by test category).

;;; Code:

(require 'ert)
(require 'org-tickets-test-fixtures)

(require 'org-tickets)
(require 'org-tickets-sync-phases)

;;;; Tests: Phase 2 Async Thunks (continued)

(ert-deftest org-tickets-test--attachment-thunk-can-create-id-under-read-only ()
  "Phase 2 runs with the sync's read-only lock held; creating the
org-attach ID property must not signal buffer-read-only."
  (with-temp-buffer
    (org-mode)
    (insert "* T\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-1\n:END:\n")
    (setq buffer-read-only t)
    (let ((downloaded nil) (done-args nil))
      (org-tickets-test--with-stubs ((org-tickets--async-download-attachments
                                   (lambda (_key _atts callback)
                                     ;; Real code path mutates the buffer before this point;
                                     ;; simulate the mutation the thunk must permit:
                                     (org-entry-put (point-min) "ID" "test-id")
                                     (setq downloaded t)
                                     (funcall callback nil nil)))
                                  (org-tickets--async-upload-attachments
                                   (lambda (_key _atts callback) (funcall callback nil nil))))
        (funcall (org-tickets--make-attachment-thunk
                  "P-1" '(((id . "1"))) (current-buffer))
                 (lambda (r e) (setq done-args (list r e)))))
      (should downloaded)
      (should (equal done-args '(nil nil))))))

;;;; Tests: Phase 2 Description Embed Refresh

(defun org-tickets-test--run-attachment-thunk (description phase-1-attachments &optional get-response get-err)
  "Run an attachment thunk with mocked download/upload/HTTP for embed tests.
DESCRIPTION and PHASE-1-ATTACHMENTS parameterize the thunk.  GET requests
are answered with GET-RESPONSE / GET-ERR; PUTs succeed.  Returns a plist
with :requests, a list of (METHOD ENDPOINT DATA) in call order, and
:done-count, the number of times the batch callback fired."
  (let ((requests nil)
        (done-count 0))
    (with-temp-buffer
      (org-mode)
      (org-tickets-test--with-stubs ((org-tickets--async-download-attachments
                                   (lambda (_key _atts cb) (funcall cb nil nil)))
                                  (org-tickets--async-upload-attachments
                                   (lambda (_key _atts cb) (funcall cb (list "uploaded") nil)))
                                  (org-tickets--async-request
                                   (lambda (method endpoint callback &optional data)
                                     (push (list method endpoint data) requests)
                                     (if (equal method "GET")
                                         (funcall callback get-response get-err)
                                       (funcall callback nil nil)))))
        (funcall (org-tickets--make-attachment-thunk
                  "P-1" phase-1-attachments (current-buffer) description)
                 (lambda (_r _e) (setq done-count (1+ done-count))))))
    (list :requests (nreverse requests) :done-count done-count)))

(ert-deftest org-tickets-test--attachment-thunk-refreshes-description-after-upload ()
  "After uploads, the thunk re-PUTs the description so new files embed.
Phase 1 built the description before the file existed in Jira, so the
attachment: link degraded to text.  The refresh re-fetches attachment
metadata (now carrying the upload's mediaApiFileId) and PUTs a
description whose media node uses that UUID."
  (let* ((get-response
          '(("fields"
             . (("attachment"
                 . ((("id" . "10001")
                     ("filename" . "new.png")
                     ("mediaApiFileId" . "uuid-new"))))))))
         (result (org-tickets-test--run-attachment-thunk
                  "[[attachment:new.png]]" nil get-response nil))
         (requests (plist-get result :requests))
         (get (seq-find (lambda (r) (equal (car r) "GET")) requests))
         (put (seq-find (lambda (r) (equal (car r) "PUT")) requests)))
    (should (= (plist-get result :done-count) 1))
    (should get)
    (should put)
    (should (equal (nth 1 put) "/rest/api/3/issue/P-1"))
    ;; The re-PUT description embeds the image as a block media node
    ;; carrying the freshly fetched media UUID.
    (let ((payload (format "%S" (nth 2 put))))
      (should (string-match-p "mediaSingle" payload))
      (should (string-match-p "uuid-new" payload)))))

(ert-deftest org-tickets-test--attachment-thunk-skips-refresh-when-links-resolved ()
  "No re-PUT when phase 1 already embedded every attachment link.
The phase-1 PUT resolved all links against the fetched metadata, so a
refresh would be a wasted GET+PUT round trip."
  (let ((result (org-tickets-test--run-attachment-thunk
                 "[[attachment:old.png]]"
                 '((("id" . "9001")
                    ("filename" . "old.png")
                    ("mediaApiFileId" . "uuid-old"))))))
    (should (= (plist-get result :done-count) 1))
    (should (null (plist-get result :requests)))))

(ert-deftest org-tickets-test--attachment-thunk-skips-refresh-without-attachment-links ()
  "No re-PUT when the description has no attachment: links at all."
  (let ((result (org-tickets-test--run-attachment-thunk
                 "Plain description, no links" nil)))
    (should (= (plist-get result :done-count) 1))
    (should (null (plist-get result :requests)))))

(ert-deftest org-tickets-test--attachment-thunk-refresh-get-error-still-calls-done ()
  "A failed refresh GET must not break the async batch contract.
DONE fires exactly once and no PUT is attempted."
  (let ((result (org-tickets-test--run-attachment-thunk
                 "[[attachment:new.png]]" nil nil "boom")))
    (should (= (plist-get result :done-count) 1))
    (should-not (seq-find (lambda (r) (equal (car r) "PUT"))
                          (plist-get result :requests)))))

(provide 'org-tickets-test-sync-flow-phase2)
;;; org-tickets-test-sync-flow-phase2.el ends here
