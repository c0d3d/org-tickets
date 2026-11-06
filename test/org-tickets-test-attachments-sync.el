;;; org-tickets-test-attachments-sync.el --- Download/sync tests for org-tickets attachments  -*- lexical-binding: t; -*-

;; Copyright (C) 2024

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
;; management, and download-side cross-reference regressions.  Shared
;; helpers (`org-tickets-test--uuid-attach-path',
;; `org-tickets-test--with-attach-env') live in
;; org-tickets-test-fixtures.el.

;;; Code:

(require 'ert)
(require 'org)
(require 'org-element)

(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; Tests for Pre-Creation Attachments

(ert-deftest org-tickets-test--attach-add-works-without-jira-key ()
  "A file can be attached to a heading before it has a JIRA_KEY.
The heading gets an ID and the file lands in its attachment directory."
  (let* ((root (make-temp-file "org-tickets-attach" t))
         (source (expand-file-name "notes.txt" root))
         (org-id-track-globally nil))
    (with-temp-file source (insert "notes"))
    (unwind-protect
        (with-temp-buffer
          (org-mode)
          (setq buffer-file-name (expand-file-name "pre.org" root))
          (setq-local org-attach-id-dir (expand-file-name "data" root))
          (insert "* Test Feature\n:PROPERTIES:\n:JIRA_TYPE: New Feature\n:END:\n")
          (goto-char (point-min))
          (org-tickets-test--with-stubs ((message #'ignore))
            (org-tickets-attach-add source))
          (should (org-entry-get (point) "ID"))
          (should-not (org-entry-get (point) "JIRA_KEY"))
          (should (equal (org-attach-file-list (org-attach-dir)) '("notes.txt"))))
      (set-buffer-modified-p nil)
      (delete-directory root t))))

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
         (jira-attachments (org-tickets-test--json "[{\"id\": \"10001\", \"filename\": \"from-jira.pdf\", \"content\": \"https://example.com/file\", \
    \"size\": 100}]")))
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
