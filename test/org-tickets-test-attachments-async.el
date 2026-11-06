;;; org-tickets-test-attachments-async.el --- Async download tests for org-tickets attachments  -*- lexical-binding: t; -*-

;; Copyright (C) 2025

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

;; Tests for async attachment download in org-tickets.
;; Covers org-tickets--async-download-attachment: success, skip-on-match, and error paths.

;;; Code:

(require 'ert)
(require 'org-tickets-test-fixtures)

(require 'org-tickets)

;;;; Helpers

(defun org-tickets-test--file-bytes (path)
  "Return the contents of PATH as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (buffer-string)))

;;;; Async Download Tests

(ert-deftest org-tickets-test--async-download-attachment-success ()
  "Async download writes the response body verbatim and reports the path."
  (let ((calls nil)
        (callback-result nil)
        (temp-dir (make-temp-file "org-tickets-test-" t)))
    (unwind-protect
        (progn
          (org-tickets-test--with-url-responses
              (list "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\nPNG\0\377data")
              calls
            (org-tickets--async-download-attachment
             "https://jira.test/attachment/123/file.png" "file.png" temp-dir 1024
             (lambda (path err) (setq callback-result (list path err)))))
          (should (= (length calls) 1))
          (should (equal (plist-get (car calls) :method) "GET"))
          (should (equal (car callback-result) (expand-file-name "file.png" temp-dir)))
          (should-not (cadr callback-result))
          (should (equal (org-tickets-test--file-bytes (car callback-result))
                         "PNG\0\377data")))
      (delete-directory temp-dir t))))

(ert-deftest org-tickets-test--async-download-attachment-redirect-drops-credentials ()
  "A redirected download is fetched from Location without the auth header."
  (let ((calls nil)
        (callback-result nil)
        (temp-dir (make-temp-file "org-tickets-test-" t)))
    (unwind-protect
        (progn
          (org-tickets-test--with-url-responses
              (list "HTTP/1.1 303 See Other\r\nlocation: https://media.test/file?token=x\r\n\r\n"
                    "HTTP/1.1 200 OK\r\n\r\nbody")
              calls
            (org-tickets--async-download-attachment
             "https://jira.test/attachment/123/file.txt" "file.txt" temp-dir 4
             (lambda (path err) (setq callback-result (list path err)))))
          (let ((redirected (car calls)))
            (should (equal (plist-get redirected :url) "https://media.test/file?token=x"))
            (should-not (assoc "Authorization" (plist-get redirected :headers))))
          (should-not (cadr callback-result))
          (should (equal (org-tickets-test--file-bytes (car callback-result)) "body")))
      (delete-directory temp-dir t))))

(ert-deftest org-tickets-test--async-download-attachment-skips-matching-size ()
  "Async download skips file when local copy matches size."
  (let ((callback-result nil)
        (calls nil)
        (temp-dir (make-temp-file "org-tickets-test-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "file.txt" temp-dir) (insert "hello"))
          (org-tickets-test--with-url-responses nil calls
            (org-tickets--async-download-attachment
             "https://jira.test/attachment/123/file.txt" "file.txt" temp-dir 5
             (lambda (path err) (setq callback-result (list path err)))))
          (should (null calls))
          (should (car callback-result))
          (should-not (cadr callback-result)))
      (delete-directory temp-dir t))))

(ert-deftest org-tickets-test--async-download-attachment-error ()
  "Async download reports an error and no path on a non-2xx response."
  (let ((calls nil)
        (callback-result nil)
        (temp-dir (make-temp-file "org-tickets-test-" t)))
    (unwind-protect
        (progn
          (org-tickets-test--with-url-responses
              (list "HTTP/1.1 404 Not Found\r\n\r\n")
              calls
            (org-tickets--async-download-attachment
             "https://jira.test/attachment/123/file.png" "file.png" temp-dir 1024
             (lambda (path err) (setq callback-result (list path err)))))
          (should-not (car callback-result))
          (should (string-match-p "404" (cadr callback-result)))
          (should-not (file-exists-p (expand-file-name "file.png" temp-dir))))
      (delete-directory temp-dir t))))

;;;; Async Upload Tests

(defmacro org-tickets-test--with-upload-file (var contents &rest body)
  "Bind VAR to a temp file holding CONTENTS, then run BODY."
  (declare (indent 2))
  `(let ((,var (make-temp-file "org-tickets-test-upload")))
     (unwind-protect
         (progn
           (with-temp-file ,var (insert ,contents))
           ,@body)
       (delete-file ,var))))

(ert-deftest org-tickets-test--async-upload-attachment-success ()
  "Async upload POSTs to the attachments URL and reports the parsed response.
The multipart request shape is asserted separately in
`org-tickets-test--async-upload-attachment-sends-multipart-form'."
  (let ((calls nil)
        (callback-result nil))
    (with-temp-buffer
      (org-tickets-test--with-upload-file temp-file "file content"
        (org-tickets-test--with-url-responses
            (list "HTTP/1.1 200 OK\r\n\r\n[{\"id\": \"10001\"}]")
            calls
          (org-tickets--async-upload-attachment
           "PROJ-123" temp-file
           (lambda (response err) (setq callback-result (list response err)))))))
    (should (= (length calls) 1))
    (should (equal (plist-get (car calls) :method) "POST"))
    (should (string-match-p "PROJ-123/attachments" (plist-get (car calls) :url)))
    (should (car callback-result))
    (should-not (cadr callback-result))))

(ert-deftest org-tickets-test--async-upload-attachment-sends-multipart-form ()
  "Upload sends a multipart/form-data POST with a `file' form field.

Jira's /attachments endpoint rejects anything that is not
multipart/form-data carrying a form field literally named `file'
\(plus X-Atlassian-Token: no-check).  The body must be unibyte so
url.el sends the file bytes unchanged."
  (let ((calls nil))
    (with-temp-buffer
      (org-tickets-test--with-upload-file temp-file "PNGDATA\0binary"
        (org-tickets-test--with-url-responses
            (list "HTTP/1.1 200 OK\r\n\r\n[]")
            calls
          (org-tickets--async-upload-attachment
           "PROJ-123" temp-file (lambda (_response _err) nil)))
        (let* ((headers (plist-get (car calls) :headers))
               (content-type (cdr (assoc "Content-Type" headers)))
               (body (plist-get (car calls) :data)))
          (should (string-match-p "multipart/form-data; *boundary=" content-type))
          ;; url.el errors on multibyte headers alongside a binary body
          (should-not (multibyte-string-p content-type))
          (should (= 1 (seq-count (lambda (h) (equal (car h) "Content-Type")) headers)))
          (should (equal "no-check" (cdr (assoc "X-Atlassian-Token" headers))))
          (should (assoc "Authorization" headers))
          (should (stringp body))
          (should-not (multibyte-string-p body))
          (should (string-match-p "name=\"file\"" body))
          (should (string-match-p (regexp-quote (file-name-nondirectory temp-file)) body))
          (should (string-match-p "PNGDATA\0binary" body)))))))

(ert-deftest org-tickets-test--async-upload-attachment-error ()
  "Async upload invokes callback with error on a non-2xx response."
  (let ((calls nil)
        (callback-result nil))
    (with-temp-buffer
      (org-tickets-test--with-upload-file temp-file "content"
        (org-tickets-test--with-url-responses
            (list "HTTP/1.1 500 Internal Server Error\r\n\r\noops")
            calls
          (org-tickets--async-upload-attachment
           "PROJ-123" temp-file
           (lambda (response err) (setq callback-result (list response err)))))))
    (should-not (car callback-result))
    (should (string-match-p "Upload failed" (cadr callback-result)))))

;;;; Async Batch Download Tests

(ert-deftest org-tickets-test--async-download-attachments-filters-by-size ()
  "Batch download skips files that exist locally with matching size."
  (let ((downloaded nil)
        (callback-result nil)
        (temp-dir (make-temp-file "org-tickets-test-" t)))
    (unwind-protect
        (progn
          ;; Create a local file matching one attachment
          (let ((existing (expand-file-name "exists.txt" temp-dir)))
            (with-temp-file existing (insert "12345")))  ; 5 bytes
          (org-tickets-test--with-stubs ((org-tickets--async-download-attachment
                                       (lambda (url filename dir size callback)
                                         (push filename downloaded)
                                         (funcall callback (expand-file-name filename dir) nil)))
                                      (org-tickets--find-ticket-by-key
                                       (lambda (_key) (point)))
                                      (org-id-get-create
                                       (lambda (&rest _) "fake-id"))
                                      (org-tickets--get-ticket-attach-dir
                                       (lambda (_create) temp-dir)))
            (with-temp-buffer
              (org-mode)
              (org-tickets-test--insert-ticket 1 "Ticket" "JIRA_KEY" "PROJ-1")
              (org-tickets--async-download-attachments
               "PROJ-1"
               (org-tickets-test--json "[{\"filename\": \"exists.txt\", \"size\": 5, \"content\": \"https://jira.test/exists.txt\"}, \
    {\"filename\": \"new.txt\", \"size\": 100, \"content\": \"https://jira.test/new.txt\"}]")
               (lambda (results err)
                 (setq callback-result (list results err))))))
          ;; Only "new.txt" should be downloaded
          (should (equal downloaded '("new.txt")))
          (should callback-result))
      (delete-directory temp-dir t))))

(ert-deftest org-tickets-test--async-download-attachments-empty-list ()
  "Batch download with empty attachment list calls callback immediately."
  (let ((callback-result nil))
    (org-tickets--async-download-attachments
     "PROJ-1" nil
     (lambda (results err)
       (setq callback-result (list results err))))
    (should (equal callback-result '(nil nil)))))

(provide 'org-tickets-test-attachments-async)
;;; org-tickets-test-attachments-async.el ends here
