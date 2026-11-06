;;; org-tickets-attachments.el --- Attachment management for org-tickets  -*- lexical-binding: t; -*-

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

;; Attachment management for org-tickets.
;; Contains upload/download/sync functions.

;;; Code:

(require 'org-tickets-api)
(require 'org-tickets-async)

(declare-function org-tickets--find-ticket-by-key "org-tickets-parse")

;;;; Async Download

(defconst org-tickets--max-download-redirects 5
  "Maximum number of redirects followed when downloading an attachment.")

(defun org-tickets--http-response-outcome (path)
  "Classify the url.el response in the current buffer, saving a 2xx body.
A successful body is written verbatim to PATH.  Returns (:saved PATH),
\(:redirect LOCATION) for a 3xx response, or (:error MESSAGE)."
  (goto-char (point-min))
  (if (not (re-search-forward "\r?\n\r?\n" nil t))
      (list :error "Could not find end of HTTP headers")
    (let ((headers (buffer-substring-no-properties (point-min) (point)))
          (case-fold-search t))
      (cond
       ((org-tickets--http-success-p headers)
        (let ((coding-system-for-write 'no-conversion))
          (write-region (point) (point-max) path nil 'silent))
        (list :saved path))
       ((and (string-match-p "\\`HTTP/[^ ]* 3[0-9][0-9]" headers)
             (string-match "^Location:[ \t]*\\([^\r\n]+\\)" headers))
        (list :redirect (match-string 1 headers)))
       (t (list :error (car (split-string headers "\r?\n"))))))))

(defun org-tickets--http-fetch-to-file (url headers path callback &optional hops)
  "Asynchronously GET URL with HEADERS and write the response body to PATH.
Redirects are followed by hand without HEADERS, so credentials are never
sent to the redirect target (Jira redirects attachment content to a
signed media URL).  HOPS counts redirects followed so far.  CALLBACK is
\(lambda (path err) ...)."
  (let ((url-request-method "GET")
        (url-request-extra-headers headers)
        (url-request-data nil)
        (url-max-redirections 0))
    (url-retrieve
     url
     (lambda (_status)
       (let ((outcome (org-tickets--http-response-outcome path)))
         (kill-buffer (current-buffer))
         (pcase outcome
           (`(:saved ,saved) (funcall callback saved nil))
           ((and `(:redirect ,location)
                 (guard (< (or hops 0) org-tickets--max-download-redirects)))
            (org-tickets--http-fetch-to-file
             (url-expand-file-name location url) nil path callback
             (1+ (or hops 0))))
           (`(:redirect ,_) (funcall callback nil "Too many redirects"))
           (`(:error ,msg) (funcall callback nil msg)))))
     nil t)))

(defun org-tickets--local-attachment-current-p (path size)
  "Return non-nil when file PATH exists with exactly SIZE bytes.
A nil SIZE never matches."
  (and size
       (file-exists-p path)
       (= (file-attribute-size (file-attributes path)) size)))

(defun org-tickets--async-download-attachment (url filename dir size callback)
  "Asynchronously download attachment from URL to FILENAME in DIR.
SIZE is the expected file size from Jira metadata.  If a local file
exists with matching name and size, the download is skipped.
CALLBACK is (lambda (path err) ...) called on completion."
  (let ((local-path (expand-file-name filename dir)))
    (if (org-tickets--local-attachment-current-p local-path size)
        (progn
          (when org-tickets-debug
            (message "org-tickets: Skipping download, local file matches: %s" filename))
          (funcall callback local-path nil))
      (when org-tickets-debug
        (message "org-tickets: Downloading attachment %s to %s" filename local-path))
      (make-directory dir t)
      (condition-case err
          (org-tickets--http-fetch-to-file
           url (org-tickets--async-build-headers) local-path
           (lambda (path fetch-err)
             (if (not fetch-err)
                 (funcall callback path nil)
               (when org-tickets-debug
                 (message "org-tickets: Failed to download %s: %s" filename fetch-err))
               (funcall callback nil (format "Download failed: %s" fetch-err)))))
        (error
         (message "org-tickets: Download error for %s: %S" filename err)
         (funcall callback nil (format "Download failed: %s" err)))))))

;;;; Async Upload

(defun org-tickets--multipart-boundary ()
  "Return a unique multipart/form-data boundary token as a unibyte string.
url.el rejects a request whose headers are multibyte when the body
holds raw bytes, and `format-time-string' returns a multibyte string."
  (encode-coding-string
   (format "org-tickets-boundary-%s-%x"
           (format-time-string "%s%N")
           (random (expt 16 8)))
   'us-ascii))

(defun org-tickets--multipart-file-body (boundary file-path)
  "Build the multipart/form-data body uploading FILE-PATH under field \"file\".

BOUNDARY delimits the single part.  Jira's attachment endpoint requires
the form field to be named `file'.  Returns a unibyte string carrying the
raw file bytes verbatim, safe to send as a binary request body."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((filename (file-name-nondirectory file-path)))
      (insert (encode-coding-string
               (concat "--" boundary "\r\n"
                       "Content-Disposition: form-data; name=\"file\"; filename=\""
                       filename "\"\r\n"
                       "Content-Type: application/octet-stream\r\n\r\n")
               'utf-8)))
    (insert-file-contents-literally file-path)
    (goto-char (point-max))
    (insert (encode-coding-string (concat "\r\n--" boundary "--\r\n") 'utf-8))
    (buffer-string)))

(defun org-tickets--async-upload-attachment (ticket-key file-path callback)
  "Asynchronously upload FILE-PATH as an attachment to TICKET-KEY.
Sends a genuine multipart/form-data POST with a `file' form field, as
Jira's /attachments endpoint requires (a raw-body upload is rejected).
CALLBACK is (lambda (response err) ...) called on completion."
  (let* ((filename (file-name-nondirectory file-path))
         (url (concat org-tickets--jira-base-url
                      "/rest/api/3/issue/" ticket-key "/attachments"))
         (boundary (org-tickets--multipart-boundary))
         (headers (append
                   (list (cons "Content-Type"
                               (concat "multipart/form-data; boundary=" boundary))
                         (cons "X-Atlassian-Token" "no-check"))
                   (assoc-delete-all "Content-Type"
                                     (org-tickets--async-build-headers)))))
    (when org-tickets-debug
      (message "org-tickets: Uploading attachment %s to %s" filename ticket-key))
    (org-tickets--async-enqueue
     "POST" url headers (org-tickets--multipart-file-body boundary file-path)
     (lambda (response err)
       (when (and err org-tickets-debug)
         (message "org-tickets: Failed to upload %s: %s" filename err))
       (funcall callback response
                (when err (format "Upload failed: %s" err)))))))

;;;; Async Batch Download

(defun org-tickets--dedup-attachments-by-filename (attachments)
  "Collapse ATTACHMENTS to one entry per filename, keeping the newest.
Jira's `created' timestamps are ISO-8601, so lexicographic comparison
orders them correctly."
  (let ((seen (make-hash-table :test #'equal)))
    (dolist (att attachments)
      (let* ((name (org-tickets--attachment-filename att))
             (created (or (org-tickets--alist-get "created" att) ""))
             (existing (gethash name seen)))
        (when (or (null existing)
                  (string> created
                           (or (org-tickets--alist-get "created" existing) "")))
          (puthash name att seen))))
    (hash-table-values seen)))

(defun org-tickets--download-thunks (attachments attach-dir)
  "Return async thunks downloading each of ATTACHMENTS into ATTACH-DIR.
Duplicate filenames are collapsed to the newest, and files already
current locally are skipped."
  (mapcar
   (lambda (att)
     (let ((filename (org-tickets--attachment-filename att))
           (url (org-tickets--attachment-content-url att))
           (size (or (org-tickets--alist-get "size" att) 0)))
       (lambda (done)
         (org-tickets--async-download-attachment
          url filename attach-dir size done))))
   (seq-remove
    (lambda (att)
      (org-tickets--local-attachment-current-p
       (expand-file-name (org-tickets--attachment-filename att) attach-dir)
       (org-tickets--alist-get "size" att)))
    (org-tickets--dedup-attachments-by-filename attachments))))

(defun org-tickets--async-download-attachments (ticket-key attachments callback)
  "Asynchronously download ATTACHMENTS from Jira for TICKET-KEY.
ATTACHMENTS is a list of attachment metadata alists from Jira.
Skips files that exist locally with matching filename and size.
CALLBACK is (lambda (results err) ...) called when all downloads finish."
  (let ((pos (and attachments (org-tickets--find-ticket-by-key ticket-key))))
    (if (not pos)
        (funcall callback nil nil)
      (save-excursion
        (goto-char pos)
        (org-id-get-create)
        (org-tickets--async-batch
         (org-tickets--download-thunks
          attachments (org-tickets--get-ticket-attach-dir t))
         (lambda (results) (funcall callback results nil)))))))

;;;; Async Batch Upload

(defun org-tickets--upload-thunks (ticket-key dir jira-attachments)
  "Return async thunks uploading files in DIR missing from JIRA-ATTACHMENTS.
Each thunk uploads one file to TICKET-KEY."
  (let ((jira-filenames (mapcar #'org-tickets--attachment-filename
                                jira-attachments)))
    (mapcar
     (lambda (file)
       (let ((file-path (expand-file-name file dir)))
         (lambda (done)
           (org-tickets--async-upload-attachment ticket-key file-path done))))
     (seq-remove (lambda (f) (member f jira-filenames))
                 (org-attach-file-list dir)))))

(defun org-tickets--async-upload-attachments (ticket-key jira-attachments callback)
  "Asynchronously upload local attachments for TICKET-KEY to Jira.
JIRA-ATTACHMENTS is the attachment list from Jira (used for dedup by filename).
Does NOT re-fetch attachment metadata from Jira.
CALLBACK is (lambda (results err) ...) called when all uploads finish."
  (let* ((pos (org-tickets--find-ticket-by-key ticket-key))
         (dir (and pos (save-excursion
                         (goto-char pos)
                         (org-tickets--get-ticket-attach-dir nil)))))
    (if (not dir)
        (funcall callback nil nil)
      (org-tickets--async-batch
       (org-tickets--upload-thunks ticket-key dir jira-attachments)
       (lambda (results) (funcall callback results nil))))))

;;;; Attachment Management

(defun org-tickets--get-attachments (ticket-key)
  "Fetch attachments for TICKET-KEY from Jira.
Returns a list of attachment metadata alists with keys:
- id: attachment ID
- filename: the filename
- mimeType: content type
- content: URL to download the file
- size: file size in bytes
- created: creation timestamp

Note: The Jira Cloud REST API v3 does not support GET on the
/rest/api/3/issue/{issueIdOrKey}/attachments endpoint (returns 405).
Instead, we fetch the issue with fields=attachment to get attachment metadata."
  (org-tickets--response-field
   (org-tickets--api-request
    "GET" (concat "/rest/api/3/issue/" ticket-key "?fields=attachment"))
   "attachment"))

(defun org-tickets--attachment-filename (attachment)
  "Get filename from ATTACHMENT metadata alist."
  (org-tickets--alist-get "filename" attachment))

(defun org-tickets--attachment-id (attachment)
  "Get attachment ID from ATTACHMENT metadata alist."
  (org-tickets--alist-get "id" attachment))

(defun org-tickets--attachment-content-url (attachment)
  "Get download URL from ATTACHMENT metadata alist."
  (org-tickets--alist-get "content" attachment))

(defun org-tickets--get-ticket-attach-dir (create-if-not-exists)
  "Get the attachment directory for the org heading at point.
If CREATE-IF-NOT-EXISTS is non-nil, creates the directory if it doesn't exist.
Uses org-attach to manage the attachment directory."
  (require 'org-attach)
  (let ((org-attach-use-inheritance nil))
    (org-attach-dir create-if-not-exists)))

(defun org-tickets--attachment-names (ticket-key)
  "Return (LOCAL . REMOTE) attachment filename lists for TICKET-KEY.
LOCAL comes from the org-attach directory of the heading at point and
REMOTE from Jira."
  (let ((dir (org-tickets--get-ticket-attach-dir nil)))
    (cons (and dir (org-attach-file-list dir))
          (mapcar #'org-tickets--attachment-filename
                  (org-tickets--get-attachments ticket-key)))))

(defun org-tickets--delete-attachment (ticket-key attachment-id)
  "Delete an attachment from Jira.
TICKET-KEY is the ticket key.
ATTACHMENT-ID is the Jira attachment ID to delete.
Returns nil on success; signals on failure."
  (org-tickets--api-request "DELETE"
                         (concat "/rest/api/3/issue/" ticket-key "/attachments/" attachment-id)))

(provide 'org-tickets-attachments)

;;; org-tickets-attachments.el ends here
