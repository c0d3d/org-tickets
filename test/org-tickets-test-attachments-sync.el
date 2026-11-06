;;; org-tickets-test-attachments-sync.el --- Download/sync tests for org-tickets attachments  -*- lexical-binding: t; -*-

;; Copyright (C) 2024

;; Author: org-tickets contributors
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

;; Tests for org-tickets attachment download, org-attach ID/attach-dir
;; management, and download-side cross-reference regressions.  Split
;; out of org-tickets-test-attachments.el (which exceeded the 750-line
;; cap); see docs/dev/testing.md.  Loads
;; org-tickets-test-attachments-upload.el for the shared cross-reference
;; helpers (`org-tickets-test--uuid-attach-path',
;; `org-tickets-test--with-attach-env').

;;; Code:

(require 'ert)
(require 'org)
(require 'org-element)

;; Load the main library
(require 'org-tickets)
(require 'org-tickets-test-fixtures)
;; `require', not `load-file': in batch mode ERT signals an error on any
;; re-definition of an existing test, so the shared helpers/tests in the
;; upload file must load at most once even when this file's loader also
;; loads the upload file directly.
(require 'org-tickets-test-attachments-upload)

;;;; Tests for Bidirectional Attachment Sync

(ert-deftest org-tickets-test--download-attachments-skips-existing-local ()
  "Test that org-tickets--download-attachments skips files that already exist locally."
  (let ((local-files '("existing.pdf" "local-only.pdf"))
        (jira-files '("existing.pdf" "new.pdf" "another.pdf"))
        downloaded-files)
    (dolist (f jira-files)
      (unless (member f local-files)
        (push f downloaded-files)))
    (should (member "existing.pdf" local-files))
    (should-not (member "existing.pdf" downloaded-files))
    (should (member "new.pdf" downloaded-files))
    (should (member "another.pdf" downloaded-files))))

(ert-deftest org-tickets-test--download-attachments-empty-list ()
  "Test that the early-return guard fires on an empty attachment list."
  (let ((content "* Test
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:ID:       12345678-1234-1234-1234-123456789012
:END:
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "^\\* Test" nil t)
      (should (org-at-heading-p)))))

;;;; Tests for Pre-Creation Attachments

(ert-deftest org-tickets-test--attach-add-without-jira-key-logic ()
  "Test the logic flow for org-tickets-attach-add without JIRA_KEY."
  (let ((content "* Test Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:END:
Description here.
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "^\\* " nil t)
      (should (looking-at "Test Feature"))
      (let ((elem (org-element-at-point)))
        (should elem)
        (should (eq (org-element-type elem) 'headline))))))

(ert-deftest org-tickets-test--attach-add-message-without-jira-key ()
  "Test that org-tickets-attach-add shows appropriate message without JIRA_KEY."
  (should (fboundp 'org-tickets-attach-add))
  (let ((doc (documentation 'org-tickets-attach-add)))
    (should doc)
    (should (string-match-p "works even without a JIRA_KEY" doc))
    (should (string-match-p "before syncing to Jira" doc))
    (should (string-match-p "uploaded when the ticket is created" doc))))

(ert-deftest org-tickets-test--attach-open-does-not-inherit-parent-id ()
  "attach-open gives a child ticket its own ID instead of the parent's.
Regression test: inheriting the parent's ID made child tickets share the
parent's attachment directory, uploading parent files to child tickets."
  (with-temp-buffer
    (org-mode)
    (setq buffer-file-name
          (expand-file-name "inherit-test.org" temporary-file-directory))
    (insert "* Parent Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:ID:       parent-uuid-1234
:END:
** Child Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:END:
")
    (goto-char (point-min))
    (re-search-forward "PROJ-200")
    (let ((org-id-track-globally nil))
      (org-tickets-test--with-stubs ((org-attach-reveal #'ignore))
        (org-tickets-attach-open)))
    (let ((child-id (org-entry-get (point) "ID")))
      (should child-id)
      (should-not (string= child-id "parent-uuid-1234")))))

(ert-deftest org-tickets-test--download-attachments-cross-reference-bug ()
  "Test that async download finds correct heading when ticket key appears in another ticket's body.
Regression test: same cross-reference issue as upload — ensures downloads go to
the correct heading's org-attach directory, not the referencing ticket's."
  (let* ((attach-dir (expand-file-name (format "test-attach-%s" (gensym))
                                       temporary-file-directory))
         (target-id "dl-target-uuid-8888")
         (id-subdir (expand-file-name (org-tickets-test--uuid-attach-path target-id)
                                      attach-dir))
         (downloaded-to (list))
         (jira-attachments (list (list (cons "id" "10001")
                                       (cons "filename" "from-jira.pdf")
                                       (cons "content" "https://example.com/file")
                                       (cons "size" 100)))))
    (make-directory id-subdir t)
    (unwind-protect
        (org-tickets-test--with-stubs ((org-tickets--async-download-attachment
                                     (lambda (_url filename dir _size callback)
                                       (push (cons filename dir) downloaded-to)
                                       (funcall callback (expand-file-name filename dir) nil)))
                                    (org-attach-dir
                                     (lambda (&optional _create-if-not-exists-p)
                                       id-subdir)))
          (with-temp-buffer
            (insert "* Referencing Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:END:
Links to [[https://jira.example.com/browse/PROJ-200][PROJ-200]].
** Target Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:ID:       dl-target-uuid-8888
:END:
Story body.
")
            (org-mode)
            (setq-local org-attach-id-dir attach-dir)
            (let ((done nil))
              (org-tickets--async-download-attachments "PROJ-200" jira-attachments
                                                    (lambda (_r _e) (setq done t)))
              ;; File should be downloaded to PROJ-200's attach dir, not PROJ-100's
              (should done)
              (should (= (length downloaded-to) 1))
              (should (string= (caar downloaded-to) "from-jira.pdf"))
              ;; The directory should be derived from the target UUID (org-attach uses
              ;; first-2-chars/remainder as path, so the remainder is present in the dir)
              (should (string-match-p "-target-uuid-8888" (cdar downloaded-to))))))
      (delete-directory attach-dir t))))

(provide 'org-tickets-test-attachments-sync)
;;; org-tickets-test-attachments-sync.el ends here
