;;; org-tickets-test-sync-links.el --- Tests for blocked-by/blocks link sync  -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-tickets-test-fixtures)
(require 'org)
(require 'org-element)

(require 'org-tickets)

(ert-deftest org-tickets-test--sync-ticket-links-handles-blocked-by ()
  "Test that async-sync-ticket-links creates links from BLOCKED-BY relationships.
If Story PROJ-200 has BLOCKED-BY: PROJ-100 (but PROJ-100 does NOT have
BLOCKS: PROJ-200), sync should still create a Blocks link from PROJ-100 to PROJ-200."
  (let ((created-links nil)
        (callback-called nil))
    (org-tickets-test--with-stubs ((org-tickets--async-create-link
                                 (lambda (from-key to-key link-type callback)
                                   (push (list from-key to-key link-type) created-links)
                                   (funcall callback nil nil))))
      (with-temp-buffer
        (insert "* Parent Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:END:
** Child Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:BLOCKED-BY: PROJ-100
:END:
")
        (org-mode)
        (let* ((doc (org-tickets--parse-document))
               (story (car (org-tickets--doc-children doc))))
          (org-tickets--async-sync-ticket-links story
                                             (lambda () (setq callback-called t)))
          ;; Should create a "Blocks" link from PROJ-100 (blocker) to PROJ-200 (blocked)
          (should callback-called)
          (should (member (list "PROJ-100" "PROJ-200" "Blocks") created-links)))))))

(defun org-tickets-test--synced-links (&rest tickets)
  "Sync TICKETS through the real link code; return the links POSTed.
Each of TICKETS is an argument list for `org-tickets-test--insert-ticket'.
Only the HTTP layer is faked, and phase 3's BLOCKED-BY write-back is
disabled so the links come from the parsed tickets alone."
  (let ((requests nil))
    (org-tickets-test--with-sync-mocks
        (org-tickets-test--fake-jira-handler :log requests)
        :real (org-tickets--async-sync-ticket-links)
      (org-tickets-test--with-stubs ((org-tickets--resolve-blocked-by-in-org #'ignore))
        (with-temp-buffer
          (org-mode)
          (dolist (ticket tickets)
            (apply #'org-tickets-test--insert-ticket ticket))
          (org-tickets-test--run-sync))))
    (org-tickets-test--logged-links requests)))

(ert-deftest org-tickets-test--sync-links-for-features ()
  "Test that link sync runs for features, not just stories.
If Feature PROJ-100 has BLOCKED-BY: PROJ-300, that link should be synced."
  (let ((links (org-tickets-test--synced-links
                '(1 "Feature A" "JIRA_TYPE" "New Feature" "JIRA_KEY" "PROJ-100"
                    "BLOCKED-BY" "PROJ-300")
                '(1 "Feature B" "JIRA_TYPE" "New Feature" "JIRA_KEY" "PROJ-300"))))
    ;; Should create a "Blocks" link from PROJ-300 (blocker) to PROJ-100 (blocked)
    (should (member (list "PROJ-300" "PROJ-100" "Blocks") links))))

(ert-deftest org-tickets-test--sync-creates-links-without-buffer-resolution ()
  "Test that full sync creates correct links even when BLOCKS is empty in buffer.
This verifies the sync path works from struct data alone, not buffer mutations."
  (let ((links (org-tickets-test--synced-links
                '(1 "Parent Feature" "JIRA_TYPE" "New Feature" "JIRA_KEY" "PROJ-100")
                '(2 "Story A" "JIRA_TYPE" "Story" "JIRA_KEY" "PROJ-200"
                    "BLOCKED-BY" "PROJ-100")
                '(2 "Story B" "JIRA_TYPE" "Story" "JIRA_KEY" "PROJ-300"
                    "BLOCKS" "PROJ-200"))))
    ;; BLOCKED-BY: PROJ-200 blocked by PROJ-100 → link PROJ-100 blocks PROJ-200
    (should (member (list "PROJ-100" "PROJ-200" "Blocks") links))
    ;; BLOCKS: PROJ-300 blocks PROJ-200
    (should (member (list "PROJ-300" "PROJ-200" "Blocks") links))))

(ert-deftest org-tickets-test--create-link-inward-is-blocker ()
  "Creating a Blocks link POSTs issueLink with inwardIssue the blocker.
This matches GET semantics: viewing ticket X with outwardIssue=Y means X
blocks Y.  So if A blocks B: inwardIssue=A, outwardIssue=B."
  (let ((requests nil))
    (org-tickets-test--with-stubs ((org-tickets--async-request
                                 (org-tickets-test--fake-jira-handler :log requests)))
      (org-tickets--async-create-link "BLOCKER-1" "BLOCKED-2" "Blocks" #'ignore))
    (should (equal (butlast (car requests)) '("POST" "/rest/api/3/issueLink")))
    (should (= (length requests) 1))
    (let ((data (nth 2 (car requests))))
      (should (string= (cdr (assoc "key" (cdr (assoc "inwardIssue" data)))) "BLOCKER-1"))
      (should (string= (cdr (assoc "key" (cdr (assoc "outwardIssue" data)))) "BLOCKED-2"))
      (should (equal (cdr (assoc "name" (cdr (assoc 'type data)))) "Blocks")))))

(ert-deftest org-tickets-test--external-parent-creates-blocks-link ()
  "Test that a Story with PARENT referencing an external ticket creates a Blocks link.
PROJ-500 is not in the buffer, but the Story should still fire a link to it."
  (let ((created-links nil)
        (callback-called nil))
    (org-tickets-test--with-stubs ((org-tickets--async-create-link
                                 (lambda (from-key to-key link-type callback)
                                   (push (list from-key to-key link-type) created-links)
                                   (funcall callback nil nil))))
      (with-temp-buffer
        (insert "* My Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:PARENT: PROJ-500
:END:
")
        (org-mode)
        (let* ((doc (org-tickets--parse-document))
               (story (car (org-tickets--doc-children doc))))
          (org-tickets--async-sync-ticket-links story
                                             (lambda () (setq callback-called t)))
          (should callback-called)
          ;; Should create a "Blocks" link from PROJ-200 to PROJ-500
          (should (member (list "PROJ-200" "PROJ-500" "Blocks") created-links)))))))

(ert-deftest org-tickets-test--links-fire-for-newly-created-ticket ()
  "Phase-2 link sync re-reads the key the buffer just received, so new
tickets get their links on the FIRST sync (they were silently skipped)."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n:END:\n"
            "** Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:END:\n")
    (let* ((doc (org-tickets--parse-document))
           (story (car (org-tickets--doc-children doc)))
           (links nil))
      ;; Simulate phase 2 having applied the new key to the buffer.
      (org-tickets--set-org-ticket-key story "P-2")
      (org-tickets-test--with-stubs ((org-tickets--async-create-link
                                   (lambda (from to type callback)
                                     (push (list from to type) links)
                                     (funcall callback nil nil))))
        (let ((done nil))
          (org-tickets--async-sync-ticket-links story
                                             (lambda () (setq done t)))
          (should done)))
      (should (member '("P-2" "P-1" "Blocks") links)))))

(ert-deftest org-tickets-test--link-failures-are-logged ()
  "A failed link creation is reported through `message'."
  (with-temp-buffer
    (org-mode)
    (insert "* S\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-2\n"
            ":PARENT: P-1\n:END:\n")
    (let* ((doc (org-tickets--parse-document))
           (story (car (org-tickets--doc-children doc)))
           (logged nil))
      (org-tickets-test--with-stubs ((org-tickets--async-create-link
                                   (lambda (_f _t _type callback) (funcall callback nil "403 Forbidden")))
                                  (message
                                   (lambda (fmt &rest args) (push (apply #'format fmt args) logged))))
        (org-tickets--async-sync-ticket-links story #'ignore))
      (should (seq-some (lambda (m) (string-match-p "403 Forbidden" m)) logged)))))

(provide 'org-tickets-test-sync-links)

;;; org-tickets-test-sync-links.el ends here
