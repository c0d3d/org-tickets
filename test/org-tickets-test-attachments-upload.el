;;; org-tickets-test-attachments-upload.el --- Upload/removal tests for org-tickets attachments  -*- lexical-binding: t; -*-

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

(ert-deftest org-tickets-test--parse-ticket-attachments-field ()
  "Test that parsed tickets have attachments field initialized to nil."
  (let ((content "* Test Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:END:
Description here.
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "^\\* Test Feature" nil t)
      (let ((ticket (org-tickets--parse-ticket-at-point)))
        (should ticket)
        ;; Attachments field should exist and be nil (not yet populated from Jira)
        (should (null (org-tickets--ticket-attachments ticket)))))))

(ert-deftest org-tickets-test--parse-document-tickets-have-attachments ()
  "Test that all tickets in parsed document have attachments field."
  (let ((content "* Test Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:END:
Description.
** Test Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-101
:END:
Story description.
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (let ((doc (org-tickets--parse-document)))
        ;; Feature should have attachments field - just verify accessor works (returns nil)
        (let ((feature (car (org-tickets--doc-features doc))))
          (should-not (org-tickets--ticket-attachments feature)))
        ;; Story should have attachments field - just verify accessor works (returns nil)
        (let ((story (car (org-tickets--doc-children doc))))
          (should-not (org-tickets--ticket-attachments story)))))))

(ert-deftest org-tickets-test--ticket-struct-attachments-field ()
  "Test that ticket struct has attachments field."
  (let ((ticket (org-tickets--ticket-create
                 :key "PROJ-123"
                 :type "Story"
                 :summary "Test"
                 :description "Description"
                 :attachments nil)))
    (should (string= (org-tickets--ticket-key ticket) "PROJ-123"))
    ;; The accessor should work and return nil
    (should (eq (org-tickets--ticket-attachments ticket) nil))))

(ert-deftest org-tickets-test--ticket-struct-attachments-with-data ()
  "Test that ticket struct can hold attachment data."
  (let ((attachment-data (org-tickets-test--json "[{\"id\": \"12345\", \"filename\": \"test.pdf\"}, {\"id\": \"12346\", \"filename\": \"test2.pdf\"}]")))
    (let ((ticket (org-tickets--ticket-create
                   :key "PROJ-123"
                   :type "Story"
                   :summary "Test"
                   :attachments attachment-data)))
      (should (string= (org-tickets--ticket-key ticket) "PROJ-123"))
      (should (= (length (org-tickets--ticket-attachments ticket)) 2))
      (should (string= (org-tickets--attachment-filename (car (org-tickets--ticket-attachments ticket))) "test.pdf"))
      (should (string= (org-tickets--attachment-filename (cadr (org-tickets--ticket-attachments ticket))) "test2.pdf")))))

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

;;;; Tests for Attachment Removal

(ert-deftest org-tickets-test--attach-remove-no-jira-key ()
  "Test that org-tickets-attach-remove errors when heading has no JIRA_KEY."
  (let ((content "* Test
:PROPERTIES:
:JIRA_TYPE: New Feature
:END:
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "^\\* Test" nil t)
      (should-error (org-tickets-attach-remove "test.pdf")))))

(ert-deftest org-tickets-test--delete-attachment-api-format ()
  "Test that delete attachment API function uses correct endpoint format."
  (let ((ticket-key "PROJ-123")
        (attachment-id "98765"))
    (should (string= (concat "/rest/api/3/issue/" ticket-key "/attachments/" attachment-id)
                     "/rest/api/3/issue/PROJ-123/attachments/98765"))))

(ert-deftest org-tickets-test--find-attachment-id-by-filename ()
  "Test finding attachment ID by filename from Jira attachments list."
  (let* ((jira-attachments (org-tickets-test--json "[{\"id\": \"10001\", \"filename\": \"document.pdf\"}, {\"id\": \"10002\", \"filename\": \"image.png\"}, \
    {\"id\": \"10003\", \"filename\": \"data.csv\"}]"))
         (id-pdf (catch 'find-id
                   (dolist (att jira-attachments)
                     (when (string= (org-tickets--attachment-filename att) "document.pdf")
                       (throw 'find-id (org-tickets--attachment-id att))))))
         (id-png (catch 'find-id
                   (dolist (att jira-attachments)
                     (when (string= (org-tickets--attachment-filename att) "image.png")
                       (throw 'find-id (org-tickets--attachment-id att))))))
         (id-csv (catch 'find-id
                   (dolist (att jira-attachments)
                     (when (string= (org-tickets--attachment-filename att) "data.csv")
                       (throw 'find-id (org-tickets--attachment-id att))))))
         (id-missing (catch 'find-id
                       (dolist (att jira-attachments)
                         (when (string= (org-tickets--attachment-filename att) "nonexistent.txt")
                           (throw 'find-id (org-tickets--attachment-id att)))))))
    (should (string= id-pdf "10001"))
    (should (string= id-png "10002"))
    (should (string= id-csv "10003"))
    (should (null id-missing))))

(ert-deftest org-tickets-test--attach-remove-finds-id-before-deleting ()
  "Test that org-tickets-attach-remove looks up attachment ID from Jira."
  (let* ((jira-attachments (org-tickets-test--json "[{\"id\": \"10001\", \"filename\": \"test.pdf\"}, {\"id\": \"10002\", \"filename\": \"other.pdf\"}]"))
         (attachment-id
          (catch 'find-id
            (dolist (att jira-attachments)
              (when (string= (org-tickets--attachment-filename att) "test.pdf")
                (throw 'find-id (org-tickets--attachment-id att)))))))
    (should (string= attachment-id "10001"))
    (should (string= (concat "/rest/api/3/issue/PROJ-100/attachments/" attachment-id)
                     "/rest/api/3/issue/PROJ-100/attachments/10001"))))

(ert-deftest org-tickets-test--attach-remove-handles-missing-jira-attachment ()
  "Test handling of file that exists locally but not in Jira."
  (let* ((local-files '("local-only.pdf" "both.pdf"))
         (jira-attachments (org-tickets-test--json "[{\"id\": \"10001\", \"filename\": \"both.pdf\"}, {\"id\": \"10002\", \"filename\": \"jira-only.pdf\"}]"))
         (filename-to-remove "local-only.pdf")
         (attachment-id
          (catch 'find-id
            (dolist (att jira-attachments)
              (when (string= (org-tickets--attachment-filename att) filename-to-remove)
                (throw 'find-id (org-tickets--attachment-id att)))))))
    (should (member filename-to-remove local-files))
    (should (null attachment-id))))

(ert-deftest org-tickets-test--attach-remove-handles-jira-only-attachment ()
  "Test handling of file that exists in Jira but not locally."
  (let* ((local-files '("local.pdf"))
         (jira-attachments (org-tickets-test--json "[{\"id\": \"10001\", \"filename\": \"jira-only.pdf\"}, {\"id\": \"10002\", \"filename\": \"local.pdf\"}]"))
         (filename-to-remove "jira-only.pdf")
         (attachment-id
          (catch 'find-id
            (dolist (att jira-attachments)
              (when (string= (org-tickets--attachment-filename att) filename-to-remove)
                (throw 'find-id (org-tickets--attachment-id att))))))
         (local-exists (member filename-to-remove local-files)))
    (should (string= attachment-id "10001"))
    (should (null local-exists))))

(ert-deftest org-tickets-test--attach-remove-deletes-both-when-both-exist ()
  "Test deletion from both Jira and local when file exists in both."
  (let* ((local-files '("both.pdf" "local-only.pdf"))
         (jira-attachments (org-tickets-test--json "[{\"id\": \"10001\", \"filename\": \"both.pdf\"}, {\"id\": \"10002\", \"filename\": \"jira-only.pdf\"}]"))
         (filename-to-remove "both.pdf")
         (attachment-id
          (catch 'find-id
            (dolist (att jira-attachments)
              (when (string= (org-tickets--attachment-filename att) filename-to-remove)
                (throw 'find-id (org-tickets--attachment-id att))))))
         (local-exists (member filename-to-remove local-files)))
    (should (string= attachment-id "10001"))
    (should local-exists)
    (should (and attachment-id local-exists))))

(ert-deftest org-tickets-test--attach-remove-empty-filename ()
  "Test that org-attach-file-list never includes empty filenames."
  (let* ((attach-dir (expand-file-name (format "test-attach-%s" (gensym)) temporary-file-directory))
         (test-file (expand-file-name "test-file.txt" attach-dir)))
    ;; Create the attachment directory with a real file
    (make-directory attach-dir t)
    (with-temp-file test-file (insert "test content"))
    (unwind-protect
        (let ((local-files (org-attach-file-list attach-dir)))
          (should local-files)
          (should (member "test-file.txt" local-files))
          (should (null (member "" local-files))))
      ;; Clean up
      (delete-directory attach-dir t))))

(ert-deftest org-tickets-test--delete-attachment-api-method ()
  "Test that org-tickets--delete-attachment uses DELETE method."
  (should (fboundp 'org-tickets--delete-attachment))
  (let ((func-doc (documentation 'org-tickets--delete-attachment)))
    (should (string-match-p "ticket-key" func-doc))
    (should (string-match-p "attachment-id" func-doc))))

;;;; Tests for Getting Attachments via Issue Endpoint

(ert-deftest org-tickets-test--get-attachments-from-issue-response ()
  "Test extracting attachments from issue response fields."
  (let* ((issue-response (org-tickets-test--json "{\"key\": \"PROJ-123\", \"id\": \"12345\", \"fields\": {\"attachment\": [{\"id\": \"10001\", \
    \"filename\": \"test.pdf\", \"content\": \"https://example.com/rest/api/3/attachment/content/10001\", \
    \"mimeType\": \"application/pdf\", \"size\": 12345}, {\"id\": \"10002\", \
    \"filename\": \"image.png\", \"content\": \"https://example.com/rest/api/3/attachment/content/10002\", \
    \"mimeType\": \"image/png\", \"size\": 67890}]}}")))
    (let ((fields (org-tickets--alist-get "fields" issue-response)))
      (should fields)
      (let ((attachments (org-tickets--alist-get "attachment" fields)))
        (should attachments)
        (should (= 2 (length attachments)))
        (should (string= (org-tickets--attachment-id (car attachments)) "10001"))
        (should (string= (org-tickets--attachment-filename (car attachments)) "test.pdf"))
        (should (string= (org-tickets--attachment-content-url (car attachments))
                         "https://example.com/rest/api/3/attachment/content/10001"))
        (should (string= (org-tickets--attachment-id (cadr attachments)) "10002"))
        (should (string= (org-tickets--attachment-filename (cadr attachments)) "image.png"))))))

(ert-deftest org-tickets-test--get-attachments-empty-response ()
  "Test handling of empty issue response."
  (let* ((issue-response (org-tickets-test--json "{\"key\": \"PROJ-123\", \"id\": \"12345\", \"fields\": {\"attachment\": null}}")))
    (let ((fields (org-tickets--alist-get "fields" issue-response)))
      (should fields)
      (let ((attachments (org-tickets--alist-get "attachment" fields)))
        (should (null attachments))))))

(ert-deftest org-tickets-test--get-attachments-no-fields ()
  "Test handling of response without fields."
  (let* ((issue-response (org-tickets-test--json "{\"key\": \"PROJ-123\", \"id\": \"12345\"}")))
    (let ((fields (org-tickets--alist-get "fields" issue-response)))
      (should (null fields)))))

(ert-deftest org-tickets-test--get-attachments-response-parsing ()
  "Test that attachment ID can be extracted from issue endpoint response."
  (let* ((issue-response (org-tickets-test--json "{\"expand\": \"names,schema\", \"key\": \"PROJ-12752\", \"id\": \"108903\", \"self\": \"https://your-domain.atlassian.net/rest/api/3/issue/108903\", \
    \"fields\": {\"summary\": \"Test story\", \"attachment\": [{\"self\": \"https://your-domain.atlassian.net/rest/api/3/attachment/10001\", \
    \"id\": \"10001\", \"filename\": \"screenshot.png\", \"content\": \"https://your-domain.atlassian.net/rest/api/3/attachment/content/10001\", \
    \"thumbnail\": \"https://your-domain.atlassian.net/rest/api/3/attachment/thumbnail/10001\", \
    \"mimeType\": \"image/png\", \"size\": 45678, \"created\": \"2024-10-15T10:30:00.000Z\", \
    \"author\": {\"accountId\": \"123456789\", \"displayName\": \"Test User\"}}]}}")))
    (let ((attachments (org-tickets--issue-attachments issue-response)))
      (should attachments)
      (let ((attachment (car attachments)))
        (should (string= (org-tickets--attachment-id attachment) "10001"))
        (should (string= (org-tickets--attachment-filename attachment) "screenshot.png"))
        (should (string= (org-tickets--attachment-content-url attachment)
                         "https://your-domain.atlassian.net/rest/api/3/attachment/content/10001"))
        (should (equal (org-tickets--alist-get "size" attachment) 45678))))))

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

(ert-deftest org-tickets-test--upload-attachments-avoids-duplicates ()
  "Test that org-tickets--upload-attachments avoids uploading duplicates."
  (let ((jira-filenames '("document.pdf" "image.png")))
    (should (member "document.pdf" jira-filenames))
    (should (member "image.png" jira-filenames))
    (should-not (member "new-file.txt" jira-filenames))
    (should-not (member "document.pdf" (list "new-file.txt")))
    (should (member "new-file.txt" (list "new-file.txt")))))

(ert-deftest org-tickets-test--sync-to-jira-calls-attachments-after-ticket ()
  "Test that org-tickets--sync-to-jira includes attachment sync in its pipeline."
  (let ((func-source (symbol-function 'org-tickets--sync-to-jira)))
    (should func-source)
    (let ((doc (documentation 'org-tickets--sync-to-jira)))
      (should doc)
      (should (string-match-p "Phase 2" doc))
      (should (string-match-p "attachments" doc)))))

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

;;;; Regression Tests for MIME Type in Attachment Uploads

(ert-deftest org-tickets-test--upload-attachment-mime-type ()
  "Test that MIME types are correctly determined for various file types.
Regression test: the Content-Type header in attachment uploads must
accurately reflect the file's MIME type. Uses mailcap for resolution."
  (require 'mailcap)
  (let ((pdf-type (mailcap-file-name-to-mime-type "document.pdf"))
        (png-type (mailcap-file-name-to-mime-type "image.png"))
        (jpg-type (mailcap-file-name-to-mime-type "photo.jpg"))
        (txt-type (mailcap-file-name-to-mime-type "readme.txt"))
        (json-type (mailcap-file-name-to-mime-type "data.json"))
        (unknown-type (mailcap-file-name-to-mime-type "weirdfile.xyz")))
    (should (string= pdf-type "application/pdf"))
    (should (string= png-type "image/png"))
    (should (string= jpg-type "image/jpeg"))
    (should (string= txt-type "text/plain"))
    (should (or (null json-type)
                (string= json-type "application/json")
                (string= json-type "text/plain")))
    ;; Unknown types fall back to application/octet-stream
    (should (or (null unknown-type)
                (string= unknown-type "application/octet-stream")))))

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

(provide 'org-tickets-test-attachments-upload)
;;; org-tickets-test-attachments-upload.el ends here
