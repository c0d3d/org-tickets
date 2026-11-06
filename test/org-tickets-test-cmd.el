;;; org-tickets-test-cmd.el --- Tests for org-tickets commands  -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-tickets)
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

(defun org-tickets-test--props-at-new-heading (call expected-type)
  "Run CALL in a buffer with an existing heading, check props land on \"New\".
EXPECTED-TYPE is the JIRA_TYPE the new heading must have.  Return the
buffer's \"New\" heading properties via `org-entry-get' on the new heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Other\n")
    (goto-char (point-min))
    (funcall call)
    (goto-char (point-min))
    (re-search-forward "^\\* New$")
    (should (equal (org-entry-get (point) "JIRA_TYPE") expected-type))
    (should (equal (org-entry-get (point) "LABELS") ""))
    (should (equal (org-entry-get (point) "BLOCKS") ""))
    (goto-char (point-min))
    (re-search-forward "^\\* Other$")
    (should-not (org-entry-get (point) "JIRA_TYPE"))
    (should-not (org-entry-get (point) "LABELS"))))

(ert-deftest org-tickets-test--feature-template-at-existing-heading ()
  (org-tickets-test--props-at-new-heading
   (lambda () (org-tickets-insert-feature-template "New" "" ""))
   "New Feature"))

(ert-deftest org-tickets-test--improvement-template-at-existing-heading ()
  (org-tickets-test--props-at-new-heading
   (lambda () (org-tickets-insert-improvement-template "New" "" ""))
   "Improvement"))

(ert-deftest org-tickets-test--story-template-at-existing-heading ()
  (with-temp-buffer
    (org-mode)
    (insert "* Other\n")
    (goto-char (point-min))
    (org-tickets-insert-story-template "New" "P-1")
    (goto-char (point-min))
    (re-search-forward "^\\*\\* New$")
    (should (equal (org-entry-get (point) "JIRA_TYPE") "Story"))
    (should (equal (org-entry-get (point) "PARENT") "P-1"))
    (should (equal (org-entry-get (point) "BLOCKS") ""))
    (goto-char (point-min))
    (re-search-forward "^\\* Other$")
    (should-not (org-entry-get (point) "JIRA_TYPE"))
    (should-not (org-entry-get (point) "PARENT"))))

(ert-deftest org-tickets-test--story-template-prompts-fix-version ()
  (should (string-match-p "Fix Version"
                          (cadr (interactive-form 'org-tickets-insert-story-template)))))


;;;; Point preservation

(defconst org-tickets-test--two-tickets
  (concat "* First\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: PROJ-1\n:END:\n"
          "* Second\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: PROJ-2\n:END:\nbody text\n")
  "Two ticket headings; the second has a body line.")

(defmacro org-tickets-test--keeps-point (&rest body)
  "Run BODY in a two-ticket org buffer with point in the second body.
Network functions are stubbed.  Fail when BODY moves point."
  (declare (indent 0))
  `(with-temp-buffer
     (org-mode)
     (insert org-tickets-test--two-tickets)
     (goto-char (point-max))
     (forward-line -1)
     (forward-char 3)
     (let ((before (copy-marker (point))))
       (org-tickets-test--with-stubs
           ((org-tickets--api-request (lambda (&rest _) nil))
            (org-tickets--resolve-config (lambda (&rest _) nil))
            (org-tickets--async-request (lambda (&rest _) nil))
            (org-tickets--async-create-link
             (lambda (_from _to _type cb) (funcall cb nil nil))))
         ,@body)
       (should (= (marker-position before) (point))))))

(ert-deftest org-tickets-test--block-link-keeps-point ()
  (org-tickets-test--keeps-point
    (org-tickets-add-block-link "PROJ-1" "PROJ-2")
    (should (equal "PROJ-2" (org-entry-get (org-tickets--find-ticket-by-key "PROJ-1")
                                           "BLOCKS")))))

(ert-deftest org-tickets-test--set-fix-version-keeps-point ()
  (org-tickets-test--keeps-point
    (org-tickets-set-fix-version "PROJ-1" "Aug2026")
    (should (equal "Aug2026" (org-entry-get (org-tickets--find-ticket-by-key "PROJ-1")
                                            "FIX_VERSION")))))

(ert-deftest org-tickets-test--update-story-sizing-keeps-point ()
  (org-tickets-test--keeps-point
    (org-tickets-update-story-sizing "PROJ-1" 3)
    (should (equal "3" (org-entry-get (org-tickets--find-ticket-by-key "PROJ-1")
                                      "STORY_POINTS")))))

(ert-deftest org-tickets-test--with-ticket-at-key-narrowed ()
  (with-temp-buffer
    (org-mode)
    (insert org-tickets-test--two-tickets)
    (goto-char (point-min))
    (re-search-forward "^\\* Second")
    (beginning-of-line)
    (narrow-to-region (point) (point-max))
    (goto-char (+ (point) 3))
    (let ((pt (point)) (beg (point-min)) (end (point-max)))
      (should-not (org-tickets--with-ticket-at-key "PROJ-1" t))
      (should (org-tickets--with-ticket-at-key "PROJ-2" t))
      (should (= pt (point)))
      (should (= beg (point-min)))
      (should (= end (point-max))))))

(ert-deftest org-tickets-test--load-issue-types-keeps-point-and-skips-src ()
  (let ((org-tickets--issue-type-ids nil))
    (with-temp-buffer
      (org-mode)
      (insert "#+BEGIN_SRC org\n#+JIRA_ISSUE_TYPES: Story=1\n#+END_SRC\n* H\ntext\n")
      (goto-char (point-max))
      (let ((pt (point)))
        (should-not (org-tickets--load-issue-types-from-document))
        (should (= pt (point)))))
    (with-temp-buffer
      (org-mode)
      (insert "#+JIRA_ISSUE_TYPES: Story=1, Bug=2\n* H\ntext\n")
      (goto-char (point-max))
      (let ((pt (point)))
        (should (equal '(("Story" . "1") ("Bug" . "2"))
                       (org-tickets--load-issue-types-from-document)))
        (should (= pt (point)))))))

(ert-deftest org-tickets-test--refresh-issue-types-requires-org-buffer ()
  (with-temp-buffer
    (fundamental-mode)
    (org-tickets-test--with-stubs
        ((org-tickets--resolve-config (lambda (&rest _) nil))
         (org-tickets--fetch-issue-types (lambda (&rest _) nil)))
      (should-error (org-tickets-refresh-issue-types) :type 'user-error))
    (should (equal "" (buffer-string)))))

;;;; Attachment removal

(defmacro org-tickets-test--with-remove-attachment-stubs (&rest body)
  "Run BODY at a ticket heading with Jira attachment calls stubbed out.
No Jira attachments exist and the attachment directory is absent."
  (declare (indent 0))
  `(with-temp-buffer
     (org-mode)
     (insert "* Test\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: PROJ-100\n:END:\n")
     (goto-char (point-min))
     (org-tickets-test--with-stubs
         ((org-tickets--get-attachments (lambda (_key) nil))
          (org-tickets--delete-attachment (lambda (&rest _) nil))
          (org-tickets--get-ticket-attach-dir (lambda (_create) nil)))
       ,@body)))

(ert-deftest org-tickets-test--attach-remove-no-attach-dir ()
  "Removal errors clearly when there is no attachment directory or Jira file."
  (org-tickets-test--with-remove-attachment-stubs
    (let ((err (should-error (org-tickets-attach-remove "test.pdf"))))
      (should (string-match-p "not found in attachment directory or Jira"
                              (error-message-string err))))))

(ert-deftest org-tickets-test--attach-remove-file-not-found ()
  "Removal errors clearly when the named file exists nowhere."
  (org-tickets-test--with-remove-attachment-stubs
    (let ((err (should-error (org-tickets-attach-remove "nonexistent.pdf"))))
      (should (string-match-p "nonexistent.pdf not found"
                              (error-message-string err))))))

(provide 'org-tickets-test-cmd)
;;; org-tickets-test-cmd.el ends here
