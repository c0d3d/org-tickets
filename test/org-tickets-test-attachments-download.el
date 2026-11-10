;;; org-tickets-test-attachments-download.el --- Download and naming edge cases for attachments  -*- lexical-binding: t; -*-

;;; Commentary:

;; Edge cases of attachment download in org-tickets-attachments.el
;; (response classification, redirects, skip-if-current, dedup, unknown
;; ticket keys), plus multipart filename encoding and
;; `org-tickets--attachment-names'.

;;; Code:

(require 'ert)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; Helpers

(defmacro org-tickets-test--with-temp-dir (var &rest body)
  "Bind VAR to a fresh temporary directory for BODY, deleting it afterwards."
  (declare (indent 1))
  `(let ((,var (make-temp-file "org-tickets-test-" t)))
     (unwind-protect (progn ,@body)
       (delete-directory ,var t))))

(defun org-tickets-test--write-bytes (path contents)
  "Write the string CONTENTS to PATH."
  (with-temp-file path (insert contents)))

(defun org-tickets-test--read-bytes (path)
  "Return the contents of PATH as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path)
    (buffer-string)))

(defun org-tickets-test--download (responses dir)
  "Download \"file.txt\" into DIR with url.el answering RESPONSES.
Returns ((PATH ERR) . CALLS): the callback's arguments and the logged
requests, newest first."
  (let ((calls nil) (result nil))
    (org-tickets-test--with-url-responses responses calls
      (org-tickets--async-download-attachment
       "https://test.atlassian.net/rest/api/3/attachment/content/1"
       "file.txt" dir 4
       (lambda (path err) (setq result (list path err)))))
    (cons result calls)))

(defun org-tickets-test--outcome (response path)
  "Return `org-tickets--http-response-outcome' of RESPONSE saving to PATH."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert response)
    (org-tickets--http-response-outcome path)))

(defun org-tickets-test--attachment (json)
  "Return the attachment alist parsed from JSON."
  (org-tickets-test--json json))

;;;; Response classification and redirects

(ert-deftest org-tickets-test--response-outcome-without-header-end ()
  "A response with no header terminator is an error and writes nothing."
  (org-tickets-test--with-temp-dir dir
    (let ((path (expand-file-name "f" dir)))
      (should (equal (org-tickets-test--outcome "HTTP/1.1 200 OK\r\nX: y" path)
                     '(:error "Could not find end of HTTP headers")))
      (should-not (file-exists-p path)))))

(ert-deftest org-tickets-test--response-outcome-header-mentioning-200 ()
  "A 404 whose headers mention \"HTTP/1.1 200\" is an error, not a save."
  (org-tickets-test--with-temp-dir dir
    (let ((path (expand-file-name "f" dir)))
      (should (eq (car (org-tickets-test--outcome
                        "HTTP/1.1 404 Not Found\r\nVia: HTTP/1.1 200\r\n\r\nnope" path))
                  :error))
      (should-not (file-exists-p path)))))

(ert-deftest org-tickets-test--redirect-without-location-is-error ()
  "A 3xx with no Location header fails the download."
  (org-tickets-test--with-temp-dir dir
    (let* ((outcome (org-tickets-test--download
                     (list "HTTP/1.1 302 Found\r\n\r\n") dir))
           (result (car outcome))
           (calls (cdr outcome)))
      (should-not (car result))
      (should (string-match-p "302" (cadr result)))
      (should (= (length calls) 1))
      (should-not (file-exists-p (expand-file-name "file.txt" dir))))))

(ert-deftest org-tickets-test--relative-redirect-resolves-on-same-host ()
  "A relative Location is fetched from the same host, without credentials."
  (org-tickets-test--with-temp-dir dir
    (let* ((outcome (org-tickets-test--download
                     (list "HTTP/1.1 302 Found\r\nLocation: /media/file.txt?t=1\r\n\r\n"
                           "HTTP/1.1 200 OK\r\n\r\nbody")
                     dir))
           (result (car outcome))
           (calls (cdr outcome)))
      (should (equal (plist-get (car calls) :url)
                     "https://test.atlassian.net/media/file.txt?t=1"))
      (should-not (assoc "Authorization" (plist-get (car calls) :headers)))
      (should (assoc "Authorization" (plist-get (cadr calls) :headers)))
      (should (equal result (list (expand-file-name "file.txt" dir) nil))))))

(ert-deftest org-tickets-test--redirect-limit-stops-download ()
  "Redirecting past the limit fails with \"Too many redirects\" and no file."
  (org-tickets-test--with-temp-dir dir
    (let* ((redirect "HTTP/1.1 302 Found\r\nLocation: https://media.test/next\r\n\r\n")
           (outcome (org-tickets-test--download
                     (make-list (1+ org-tickets--max-download-redirects) redirect)
                     dir))
           (result (car outcome))
           (calls (cdr outcome)))
      (should (equal result '(nil "Download failed: Too many redirects")))
      (should (= (length calls) (1+ org-tickets--max-download-redirects)))
      (should-not (file-exists-p (expand-file-name "file.txt" dir))))))

(ert-deftest org-tickets-test--download-signal-reported-to-callback ()
  "An error signalled while starting a download is passed to the callback."
  (org-tickets-test--with-temp-dir dir
    (let ((result nil))
      (org-tickets-test--with-fake-config
        (org-tickets-test--with-stubs
            ((url-retrieve (lambda (&rest _) (error "Network down")))
             (message #'ignore))
          (org-tickets--async-download-attachment
           "https://test.atlassian.net/a" "file.txt" dir 4
           (lambda (path err) (setq result (list path err))))))
      (should-not (car result))
      (should (string-match-p "\\`Download failed: .*Network down" (cadr result))))))

;;;; Skipping current files

(ert-deftest org-tickets-test--local-attachment-current-p-needs-matching-size ()
  "A local file is current only when its size is known and matches."
  (org-tickets-test--with-temp-dir dir
    (let ((path (expand-file-name "f.txt" dir)))
      (org-tickets-test--write-bytes path "hello")
      (should (org-tickets--local-attachment-current-p path 5))
      (should-not (org-tickets--local-attachment-current-p path nil))
      (should-not (org-tickets--local-attachment-current-p path 6))
      (should-not (org-tickets--local-attachment-current-p
                   (expand-file-name "missing" dir) 5)))))

(ert-deftest org-tickets-test--unknown-size-downloads-over-empty-file ()
  "An attachment with no size is downloaded even over an empty local file."
  (org-tickets-test--with-temp-dir dir
    (let ((path (expand-file-name "empty.txt" dir))
          (calls nil)
          (results nil))
      (org-tickets-test--write-bytes path "")
      (org-tickets-test--with-url-responses
          (list "HTTP/1.1 200 OK\r\n\r\nfresh") calls
        (org-tickets--async-batch
         (org-tickets--download-thunks
          (list (org-tickets-test--attachment
                 "{\"filename\": \"empty.txt\", \"content\": \"https://test.atlassian.net/c/1\"}"))
          dir)
         (lambda (r) (setq results r))))
      (should (= (length calls) 1))
      (should (equal results (list (cons path nil))))
      (should (equal (org-tickets-test--read-bytes path) "fresh")))))

;;;; Dedup

(ert-deftest org-tickets-test--dedup-tolerates-nameless-attachment ()
  "A nameless attachment is dropped rather than crashing the download step."
  (org-tickets-test--with-temp-dir dir
    (let ((atts (list (org-tickets-test--attachment "{\"id\": \"1\", \"size\": 3}")
                      (org-tickets-test--attachment
                       "{\"id\": \"2\", \"filename\": \"a.txt\", \"size\": 3}"))))
      (should (equal (mapcar #'org-tickets--attachment-id
                             (org-tickets--dedup-attachments-by-filename atts))
                     '("2")))
      (should (= (length (org-tickets--download-thunks atts dir)) 1)))))

(ert-deftest org-tickets-test--dedup-prefers-dated-over-undated ()
  "An attachment with a created timestamp beats a same-named undated one."
  (let ((undated (org-tickets-test--attachment "{\"id\": \"1\", \"filename\": \"a\"}"))
        (dated (org-tickets-test--attachment
                "{\"id\": \"2\", \"filename\": \"a\", \"created\": \"2024-01-01T00:00:00.000Z\"}")))
    (dolist (order (list (list undated dated) (list dated undated)))
      (should (equal (mapcar #'org-tickets--attachment-id
                             (org-tickets--dedup-attachments-by-filename order))
                     '("2"))))))

(ert-deftest org-tickets-test--download-keeps-jira-filename-inside-dir ()
  "A Jira filename with directory parts is saved inside the attach dir."
  (org-tickets-test--with-temp-dir dir
    (let* ((sub (expand-file-name "attach" dir))
           (calls nil)
           (result nil))
      (org-tickets-test--with-url-responses
          (list "HTTP/1.1 200 OK\r\n\r\nx") calls
        (org-tickets--async-download-attachment
         "https://test.atlassian.net/c/1" "../escaped.txt" sub 1
         (lambda (path err) (setq result (list path err)))))
      (should (equal result (list (expand-file-name "escaped.txt" sub) nil)))
      (should-not (file-exists-p (expand-file-name "escaped.txt" dir))))))

;;;; Batch download

(ert-deftest org-tickets-test--download-attachments-unknown-key-makes-no-requests ()
  "A ticket key absent from the buffer calls back empty without any request."
  (let ((calls nil) (result 'unset))
    (with-temp-buffer
      (org-mode)
      (org-tickets-test--insert-ticket 1 "Other" "JIRA_KEY" "PROJ-2")
      (org-tickets-test--with-url-responses nil calls
        (org-tickets--async-download-attachments
         "PROJ-1"
         (list (org-tickets-test--attachment
                "{\"filename\": \"a.txt\", \"size\": 1, \"content\": \"https://test.atlassian.net/c/1\"}"))
         (lambda (results err) (setq result (list results err)))))
      (should-not (org-entry-get (point-min) "ID")))
    (should (equal result '(nil nil)))
    (should-not calls)))

;;;; Multipart filenames

(defun org-tickets-test--multipart-disposition (filename)
  "Return the Content-Disposition line uploading a file named FILENAME.
The line is decoded from UTF-8."
  (org-tickets-test--with-temp-dir dir
    (let ((path (expand-file-name filename dir)))
      (org-tickets-test--write-bytes path "data")
      (let ((body (org-tickets--multipart-file-body "B" path)))
        (should-not (multibyte-string-p body))
        (seq-find (lambda (line) (string-prefix-p "Content-Disposition" line))
                  (split-string (decode-coding-string body 'utf-8-unix) "\r\n"))))))

(ert-deftest org-tickets-test--multipart-filename-escapes-quote ()
  "A double quote in the filename cannot end the quoted header value early."
  (should (equal (org-tickets-test--multipart-disposition "a\"b.txt")
                 "Content-Disposition: form-data; name=\"file\"; filename=\"a%22b.txt\"")))

(ert-deftest org-tickets-test--multipart-filename-keeps-utf-8 ()
  "A non-ASCII filename is sent as UTF-8 inside the quoted value."
  (should (equal (org-tickets-test--multipart-disposition "café — résumé.png")
                 "Content-Disposition: form-data; name=\"file\"; filename=\"café — résumé.png\"")))

;;;; Attachment names

(ert-deftest org-tickets-test--attachment-names-local-and-remote ()
  "Local names come from the attach dir and remote names from Jira."
  (org-tickets-test--with-temp-dir dir
    (dolist (f '("b.txt" "a.txt"))
      (org-tickets-test--write-bytes (expand-file-name f dir) "x"))
    (let ((endpoint nil))
      (org-tickets-test--with-stubs
          ((org-tickets--get-ticket-attach-dir (lambda (_create) dir))
           (org-tickets--api-request
            (lambda (_method ep &rest _)
              (setq endpoint ep)
              (org-tickets-test--json
               "{\"fields\": {\"attachment\": [{\"filename\": \"c.png\"}, {\"filename\": \"a.txt\"}]}}"))))
        (let ((names (org-tickets--attachment-names "PROJ-1")))
          (should (equal (sort (copy-sequence (car names)) #'string<) '("a.txt" "b.txt")))
          (should (equal (cdr names) '("c.png" "a.txt")))))
      (should (equal endpoint "/rest/api/3/issue/PROJ-1?fields=attachment")))))

(ert-deftest org-tickets-test--attachment-names-without-attach-dir ()
  "A heading with no attach dir has no local names."
  (org-tickets-test--with-stubs
      ((org-tickets--get-ticket-attach-dir #'ignore)
       (org-tickets--api-request (lambda (&rest _) nil)))
    (should (equal (org-tickets--attachment-names "PROJ-1") '(nil)))))

(provide 'org-tickets-test-attachments-download)
;;; org-tickets-test-attachments-download.el ends here
