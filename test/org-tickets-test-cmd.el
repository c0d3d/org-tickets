;;; org-tickets-test-cmd.el --- Tests for org-tickets commands  -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-tickets-cmd)
(require 'org-tickets-test-fixtures)

(ert-deftest org-tickets-test--copy-ticket-link-to-clipboard ()
  "Test copying Jira ticket link to clipboard."
  (let ((org-tickets-base-url "https://test.atlassian.net")
        (org-tickets-project-key "TEST")
        (captured-url nil))
    ;; Mock the selection functions and kill-new
    (org-tickets-test--with-stubs ((x-get-selection (lambda (_) nil))
                                (x-set-selection (lambda (_ val)
                                                   (should (string-match-p "TEST-123" val))
                                                   (should (string-match-p "test.atlassian.net" val))))
                                (kill-new (lambda (val)
                                            (setq captured-url val)
                                            (should (string-match-p "TEST-123" val))
                                            (should (string-match-p "test.atlassian.net" val)))))
      (org-tickets--copy-ticket-link-to-clipboard "TEST-123")
      (should captured-url)
      (should (string= captured-url "https://test.atlassian.net/browse/TEST-123")))))

(ert-deftest org-tickets-test--insert-ticket-hyperlink ()
  "Test inserting hyperlink to another ticket."
  (let ((org-tickets-base-url "https://test.atlassian.net"))
    (with-temp-buffer
      (insert "* Test heading\n")
      (org-mode)
      (goto-char (point-min))
      (org-tickets--insert-ticket-hyperlink "TEST-456")
      (should (string-match-p "\\[TEST-456\\|https://test.atlassian.net.*TEST-456\\]" (buffer-string))))))

(ert-deftest org-tickets-test--attach-remove-deletes-remote-and-reports-truthfully ()
  (with-temp-buffer
    (org-mode)
    (insert "* T\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-1\n:END:\n")
    (goto-char (point-min))
    (let ((deleted nil) (messages nil))
      (org-tickets-test--with-stubs ((org-tickets--get-attachments
                                   (lambda (_key) '(((id . "10001") (filename . "a.png")))))
                                  (org-tickets--delete-attachment
                                   (lambda (_key id) (setq deleted id) t))
                                  (org-tickets--get-ticket-attach-dir
                                   (lambda (_create) nil))
                                  (message
                                   (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (org-tickets-attach-remove "a.png")
        (should (equal deleted "10001"))
        (should (seq-some (lambda (m) (string-match-p "Jira" m)) messages))))))

(ert-deftest org-tickets-test--attach-remove-local-only-does-not-claim-jira ()
  "When the file exists only locally, the message must not claim a Jira
deletion happened."
  (with-temp-buffer
    (org-mode)
    (insert "* T\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-1\n:END:\n")
    (goto-char (point-min))
    (let* ((dir (make-temp-file "attach" t))
           (messages nil))
      (unwind-protect
          (progn
            (write-region "" nil (expand-file-name "b.txt" dir))
            (org-tickets-test--with-stubs ((org-tickets--get-attachments
                                         (lambda (_key) nil))
                                        (org-tickets--get-ticket-attach-dir
                                         (lambda (_create) dir))
                                        (message
                                         (lambda (fmt &rest args)
                                           (push (apply #'format fmt args) messages))))
              (org-tickets-attach-remove "b.txt")
              (should-not (file-exists-p (expand-file-name "b.txt" dir)))
              (should-not (seq-some (lambda (m)
                                      (string-match-p "from Jira" m))
                                    messages))))
        (delete-directory dir t)))))

(ert-deftest org-tickets-test--copy-link-requires-key ()
  "No JIRA_KEY must error, not copy .../browse/ with a nil key."
  (with-temp-buffer
    (org-mode)
    (insert "* No key here\n")
    (goto-char (point-min))
    (let ((org-tickets-base-url "https://x.test"))
      (should-error (org-tickets-copy-link)))))

(ert-deftest org-tickets-test--story-template-does-not-overwrite-parent-fix-version ()
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n"
            ":FIX_VERSION: May2026\n:END:\n")
    (goto-char (point-max))
    (org-tickets-insert-story-template "Story S" "P-1" "Aug2026")
    ;; The story got its fix version...
    (should (equal (org-entry-get (point) "FIX_VERSION") "Aug2026"))
    ;; ...and the parent's is untouched.
    (goto-char (point-min))
    (should (equal (org-entry-get (point) "FIX_VERSION") "May2026"))))

(ert-deftest org-tickets-test--attach-open-works-without-jira-key ()
  "attach-add works pre-sync; attach-open must too (ID is what matters)."
  (with-temp-buffer
    (org-mode)
    (insert "* Unsync'd\n")
    (goto-char (point-min))
    (let ((revealed nil))
      (org-tickets-test--with-stubs ((org-attach-reveal
                                   (lambda (&rest _) (setq revealed t)))
                                  (org-id-get-create
                                   (lambda (&rest _)
                                     (org-entry-put (point) "ID" "fake-id") "fake-id")))
        (org-tickets-attach-open)
        (should revealed)))))

(provide 'org-tickets-test-cmd)
;;; org-tickets-test-cmd.el ends here
