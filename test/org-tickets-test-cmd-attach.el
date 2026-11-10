;;; org-tickets-test-cmd-attach.el --- Tests for attachment commands  -*- lexical-binding: t; -*-

;;; Commentary:

;; The interactive attachment commands in org-tickets-cmd.el: add, list
;; and remove, with Jira and org-attach stubbed out.

;;; Code:

(require 'ert)
(require 'seq)
(require 'org)
(require 'org-tickets)
(require 'org-tickets-cmd)
(require 'org-tickets-test-fixtures)

(defmacro org-tickets-test--at-attach-heading (key &rest body)
  "Run BODY at a Story heading with JIRA_KEY KEY (none when nil).
Binds `messages' to what is echoed, newest first."
  (declare (indent 1))
  `(with-temp-buffer
     (org-mode)
     (insert "* T\n:PROPERTIES:\n:JIRA_TYPE: Story\n"
             (if ,key (concat ":JIRA_KEY: " ,key "\n") "")
             ":END:\n")
     (goto-char (point-min))
     (let ((messages nil))
       (org-tickets-test--with-stubs
           ((message (lambda (fmt &rest args)
                       (push (apply #'format fmt args) messages))))
         ,@body))))

(defmacro org-tickets-test--with-attach-dir (files &rest body)
  "Run BODY with `dir' bound to a temp attach dir holding empty FILES."
  (declare (indent 1))
  `(let ((dir (make-temp-file "org-tickets-attach" t)))
     (unwind-protect
         (progn
           (dolist (file ,files)
             (write-region "" nil (expand-file-name file dir)))
           ,@body)
       (delete-directory dir t))))

;;;; Remove

(defun org-tickets-test--remove-with (dir jira-attachments)
  "Remove \"a.png\" given DIR and JIRA-ATTACHMENTS; return deleted Jira ids."
  (let ((deleted nil))
    (org-tickets-test--with-stubs
        ((org-tickets--get-attachments (lambda (_key) jira-attachments))
         (org-tickets--delete-attachment
          (lambda (key id) (push (cons key id) deleted) nil))
         (org-tickets--get-ticket-attach-dir (lambda (_create) dir)))
      (org-tickets-attach-remove "a.png"))
    (nreverse deleted)))

(ert-deftest org-tickets-test--attach-remove-from-jira-and-local ()
  "A file in both places is deleted from both, and the message says so."
  (org-tickets-test--at-attach-heading "P-1"
    (org-tickets-test--with-attach-dir '("a.png")
      (should (equal (org-tickets-test--remove-with
                      dir (org-tickets-test--json
                           "[{\"id\": \"10001\", \"filename\": \"a.png\"}]"))
                     '(("P-1" . "10001"))))
      (should-not (file-exists-p (expand-file-name "a.png" dir)))
      (should (equal (car messages)
                     "org-tickets: removed a.png from Jira and local directory")))))

(ert-deftest org-tickets-test--attach-remove-jira-match-without-id ()
  "A Jira entry without an id is not deleted; the local file still is."
  (org-tickets-test--at-attach-heading "P-1"
    (org-tickets-test--with-attach-dir '("a.png")
      (should-not (org-tickets-test--remove-with
                   dir (org-tickets-test--json "[{\"filename\": \"a.png\"}]")))
      (should-not (file-exists-p (expand-file-name "a.png" dir)))
      (should (equal (car messages)
                     "org-tickets: removed a.png from local directory")))))

(ert-deftest org-tickets-test--attach-remove-deletes-every-jira-duplicate ()
  "Every Jira attachment with the name is deleted, not just the first."
  (org-tickets-test--at-attach-heading "P-1"
    (should (equal (org-tickets-test--remove-with
                    nil (org-tickets-test--json
                         (concat "[{\"id\": \"1\", \"filename\": \"a.png\"},"
                                 " {\"id\": \"2\", \"filename\": \"b.png\"},"
                                 " {\"id\": \"3\", \"filename\": \"a.png\"}]")))
                   '(("P-1" . "1") ("P-1" . "3"))))
    (should (equal (car messages) "org-tickets: removed a.png from Jira"))))

(ert-deftest org-tickets-test--attach-remove-interactive-no-attachments ()
  "Interactively, a ticket with no attachments anywhere is a user-error."
  (org-tickets-test--at-attach-heading "P-1"
    (org-tickets-test--with-stubs
        ((org-tickets--attachment-names (lambda (_key) '(nil . nil)))
         (completing-read (lambda (&rest _) (error "Should not prompt"))))
      (let ((err (should-error (call-interactively #'org-tickets-attach-remove)
                               :type 'user-error)))
        (should (equal (cadr err) "No attachments found for P-1"))))))

;;;; List

(ert-deftest org-tickets-test--attach-list-requires-key ()
  "Listing attachments of an unsynced ticket is a user-error."
  (org-tickets-test--at-attach-heading nil
    (let ((err (should-error (org-tickets-attach-list) :type 'user-error)))
      (should (string-match-p "No JIRA_KEY" (cadr err))))))

(ert-deftest org-tickets-test--attach-list-none-anywhere ()
  "With no attachments, both sides read \"none\"."
  (org-tickets-test--at-attach-heading "P-1"
    (org-tickets-test--with-stubs
        ((org-tickets--attachment-names (lambda (_key) '(nil . nil))))
      (org-tickets-attach-list))
    (should (equal (car messages) "org-tickets: local: none | jira: none"))))

(ert-deftest org-tickets-test--attach-list-names-both-sides ()
  "Local and Jira names are listed comma-separated."
  (org-tickets-test--at-attach-heading "P-1"
    (org-tickets-test--with-stubs
        ((org-tickets--attachment-names
          (lambda (_key) '(("a.png" "b.txt") . ("c.pdf")))))
      (org-tickets-attach-list))
    (should (equal (car messages)
                   "org-tickets: local: a.png, b.txt | jira: c.pdf"))))

;;;; Add

(defun org-tickets-test--attach-add-capturing ()
  "Run `org-tickets-attach-add' on /tmp/x/a.png; return the attached file."
  (let ((attached nil))
    (org-tickets-test--with-stubs
        ((org-id-get-create (lambda (&rest _) "fake-id"))
         (org-attach-attach (lambda (file &rest _) (setq attached file))))
      (org-tickets-attach-add "/tmp/x/a.png"))
    attached))

(ert-deftest org-tickets-test--attach-add-keyed-ticket-message ()
  "On a synced ticket the message names the key and the sync command."
  (org-tickets-test--at-attach-heading "P-1"
    (should (equal (org-tickets-test--attach-add-capturing) "/tmp/x/a.png"))
    (should (equal (car messages)
                   (concat "org-tickets: Attached a.png to P-1. "
                           "Run org-tickets-sync-to-jira to upload.")))))

(ert-deftest org-tickets-test--attach-add-unsynced-ticket-message ()
  "On an unsynced ticket the message says the upload waits for creation."
  (org-tickets-test--at-attach-heading nil
    (should (equal (org-tickets-test--attach-add-capturing) "/tmp/x/a.png"))
    (should (string-match-p
             "Attached a.png to current heading.*uploaded when ticket is created"
             (car messages)))))

(provide 'org-tickets-test-cmd-attach)

;;; org-tickets-test-cmd-attach.el ends here
