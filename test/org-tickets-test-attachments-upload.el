;;; org-tickets-test-attachments-upload.el --- Upload/removal tests for org-tickets attachments  -*- lexical-binding: t; -*-

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

;; Tests for org-tickets attachment metadata parsing, upload, dedup, and
;; removal.  Split out of org-tickets-test-attachments.el (which exceeded
;; the 750-line cap); see docs/dev/testing.md.  Also defines the shared
;; cross-reference-regression helpers used by both this file and
;; org-tickets-test-attachments-sync.el.

;;; Code:

(require 'ert)
(require 'org)
(require 'org-element)

;; Load the main library
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; Tests for Attachment Parsing

(ert-deftest org-tickets-test--attachment-filename ()
  "Test extracting filename from attachment metadata."
  (let ((attachment (org-tickets-test--json "{\"id\": \"12345\", \"filename\": \"test.pdf\", \"mimeType\": \"application/pdf\", \
    \"content\": \"https://example.com/test.pdf\", \"size\": 1024}")))
    (should (string= (org-tickets--attachment-filename attachment) "test.pdf"))))

(ert-deftest org-tickets-test--attachment-filename-missing ()
  "Test extracting filename when not present in attachment metadata."
  (let ((attachment (org-tickets-test--json "{\"id\": \"12345\", \"mimeType\": \"application/pdf\"}")))
    (should (null (org-tickets--attachment-filename attachment)))))

(ert-deftest org-tickets-test--attachment-id ()
  "Test extracting ID from attachment metadata."
  (let ((attachment (org-tickets-test--json "{\"id\": \"12345\", \"filename\": \"test.pdf\"}")))
    (should (string= (org-tickets--attachment-id attachment) "12345"))))

(ert-deftest org-tickets-test--attachment-id-missing ()
  "Test extracting ID when not present in attachment metadata."
  (let ((attachment (org-tickets-test--json "{\"filename\": \"test.pdf\"}")))
    (should (null (org-tickets--attachment-id attachment)))))

(ert-deftest org-tickets-test--attachment-content-url ()
  "Test extracting content URL from attachment metadata."
  (let ((attachment (org-tickets-test--json "{\"id\": \"12345\", \"filename\": \"test.pdf\", \"content\": \"https://example.com/rest/api/3/attachment/12345\"}")))
    (should (string= (org-tickets--attachment-content-url attachment)
                     "https://example.com/rest/api/3/attachment/12345"))))

(ert-deftest org-tickets-test--attachment-content-url-missing ()
  "Test extracting content URL when not present in attachment metadata."
  (let ((attachment (org-tickets-test--json "{\"id\": \"12345\", \"filename\": \"test.pdf\"}")))
    (should (null (org-tickets--attachment-content-url attachment)))))

(ert-deftest org-tickets-test--async-upload-attachments-no-ticket-in-buffer ()
  "Test that org-tickets--async-upload-attachments calls callback with nil when ticket not found."
  (let ((content "* Test
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:END:
")
        (callback-result 'not-called))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (org-tickets--async-upload-attachments "PROJ-NONEXISTENT" nil
                                          (lambda (results err)
                                            (setq callback-result (list results err))))
      (should (equal callback-result (list nil nil))))))

(ert-deftest org-tickets-test--async-upload-attachments-no-attach-dir ()
  "Test that org-tickets--async-upload-attachments calls callback with nil when no attach dir."
  (let ((content "* Test
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:END:
")
        (callback-result 'not-called))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "^\\* Test" nil t)
      (org-tickets--async-upload-attachments "PROJ-100" nil
                                          (lambda (results err)
                                            (setq callback-result (list results err))))
      (should (equal callback-result (list nil nil))))))

(ert-deftest org-tickets-test--get-attachments-parses-real-response-shape ()
  "json.el produces SYMBOL keys; (assoc \"fields\" ...) matched nothing,
so this function returned nil for every real response."
  (org-tickets-test--with-stubs ((org-tickets--api-request
                               (lambda (_method _endpoint &rest _)
                                 (org-tickets-test--json
                                  "{\"fields\": {\"attachment\": [
                   {\"id\": \"10001\", \"filename\": \"a.png\",
                    \"size\": 4, \"content\": \"https://x.test/a\"}]}}"))))
    (let ((atts (org-tickets--get-attachments "P-1")))
      (should (= (length atts) 1))
      (should (equal (org-tickets--attachment-filename (car atts)) "a.png"))
      (should (equal (org-tickets--attachment-id (car atts)) "10001")))))

(ert-deftest org-tickets-test--download-dedup-prefers-newest ()
  "Jira allows several attachments with one filename; we must download
the most recent, not the oldest (the reverse+puthash kept the oldest)."
  (let ((atts (list '((id . "1") (filename . "x.png") (size . 1)
                      (created . "2026-01-01T00:00:00.000+0000")
                      (content . "https://x.test/old"))
                    '((id . "2") (filename . "x.png") (size . 2)
                      (created . "2026-06-01T00:00:00.000+0000")
                      (content . "https://x.test/new")))))
    (should (equal (mapcar (lambda (a) (org-tickets--alist-get "id" a))
                           (org-tickets--dedup-attachments-by-filename atts))
                   '("2")))))

(ert-deftest org-tickets-test--async-upload-attachments-deduplicates-against-jira ()
  "Test that org-tickets--async-upload-attachments does not upload files already in Jira.
The caller passes in the Jira attachments list; dedup is done without an extra API call."
  (let* ((attach-dir (expand-file-name (format "test-attach-%s" (gensym)) temporary-file-directory))
         (uploaded-files nil)
         (jira-attachments
          (org-tickets-test--json "[{\"id\": \"10001\", \"filename\": \"existing.pdf\"}]")))
    (make-directory attach-dir t)
    ;; Create one file that exists in Jira and one that doesn't
    (with-temp-file (expand-file-name "existing.pdf" attach-dir) (insert "existing"))
    (with-temp-file (expand-file-name "new-file.txt" attach-dir) (insert "new"))
    (org-tickets-test--with-stubs ((org-tickets--async-upload-attachment
                                 (lambda (ticket-key file-path callback)
                                   (push (file-name-nondirectory file-path) uploaded-files)
                                   (funcall callback nil nil)))
                                (org-attach-dir
                                 (lambda (&optional _create-if-not-exists-p)
                                   attach-dir)))
      (unwind-protect
          (with-temp-buffer
            (insert "* Test Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:ID:       12345678-1234-1234-1234-123456789012
:END:
")
            (org-mode)
            (goto-char (point-min))
            (re-search-forward "^\\* Test Feature" nil t)
            (let ((done nil))
              (org-tickets--async-upload-attachments "PROJ-100" jira-attachments
                                                  (lambda (_r _e) (setq done t)))
              ;; Only new-file.txt should be uploaded, not existing.pdf
              (should done)
              (should (= 1 (length uploaded-files)))
              (should (member "new-file.txt" uploaded-files))
              (should-not (member "existing.pdf" uploaded-files))))
        (delete-directory attach-dir t)))))

;;;; Cross-Reference Regression Tests

(ert-deftest org-tickets-test--upload-attachments-cross-reference-bug ()
  "Test that async upload finds correct heading when ticket key appears in another ticket's body.
Regression test: when ticket B's body contains a link to ticket A (e.g.,
[[https://jira.example.com/browse/PROJ-200][PROJ-200]]), and ticket B appears
before ticket A in the buffer, re-search-forward for PROJ-200 matched inside
ticket B's body instead of ticket A's heading."
  (org-tickets-test--with-attach-env "target-uuid-7777" '("my-diagram.png")
                                  "* Referencing Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:END:
See the diagram on [[https://jira.example.com/browse/PROJ-200][PROJ-200]] for details.
** Target Story With Attachments
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:ID:       target-uuid-7777
:END:
Story description.
"
    (let ((done nil))
      (org-tickets--async-upload-attachments "PROJ-200" nil
                                          (lambda (_r _e) (setq done t)))
      (should done))
    ;; The file belongs to PROJ-200's heading — it must be uploaded
    (should (= (length uploaded-to) 1))
    (should (string= (caar uploaded-to) "PROJ-200"))
    (should (string= (cdar uploaded-to) "my-diagram.png"))))

(ert-deftest org-tickets-test--upload-thunks-match-quote-escaped-names ()
  "A local file whose name has a double quote is not re-uploaded once Jira
holds it under the percent-encoded name the upload sent."
  (let ((dir (make-temp-file "org-tickets-upload" t)))
    (unwind-protect
        (progn
          (dolist (name '("a\"b.txt" "new.txt"))
            (write-region "x" nil (expand-file-name name dir)))
          (let ((thunks (org-tickets--upload-thunks
                         "P-1" dir '(((filename . "a%22b.txt"))))))
            (should (= (length thunks) 1))))
      (delete-directory dir t))))

(provide 'org-tickets-test-attachments-upload)
;;; org-tickets-test-attachments-upload.el ends here
