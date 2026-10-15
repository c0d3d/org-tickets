;;; org-tickets-test-sync-links.el --- Tests for blocked-by/blocks link sync  -*- lexical-binding: t; -*-

(require 'ert)
(require 'org-tickets-test-fixtures)
(require 'org)
(require 'org-element)

;; Load the main library
(require 'org-tickets)

;;;; Tests for BLOCKED-BY → BLOCKS auto-population

(ert-deftest org-tickets-test--blocked-by-populates-blocks-in-org ()
  "Test that BLOCKED-BY on a story auto-populates BLOCKS on the target ticket.
When Story PROJ-200 has BLOCKED-BY: PROJ-100, then PROJ-100 should get
BLOCKS: PROJ-200 in its org properties."
  (with-temp-buffer
    (insert "* Parent Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:BLOCKS:
:END:
** Child Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:BLOCKED-BY: PROJ-100
:END:
")
    (org-mode)
    (let ((doc (org-tickets--parse-document)))
      ;; Resolve blocked-by → blocks in org buffer
      (org-tickets--resolve-blocked-by-in-org doc)
      ;; Verify PROJ-100 now has BLOCKS containing PROJ-200
      (goto-char (point-min))
      (re-search-forward "PROJ-100" nil t)
      (let ((blocks (org-entry-get (point) "BLOCKS")))
        (should blocks)
        (should (string-match-p "PROJ-200" blocks))))))

(ert-deftest org-tickets-test--blocked-by-populates-blocks-idempotent ()
  "Test that resolving BLOCKED-BY twice doesn't create duplicate BLOCKS entries."
  (with-temp-buffer
    (insert "* Parent Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:BLOCKS:
:END:
** Child Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:BLOCKED-BY: PROJ-100
:END:
")
    (org-mode)
    (let ((doc (org-tickets--parse-document)))
      ;; Resolve twice
      (org-tickets--resolve-blocked-by-in-org doc)
      ;; Re-parse to get updated state
      (let ((doc2 (org-tickets--parse-document)))
        (org-tickets--resolve-blocked-by-in-org doc2))
      ;; PROJ-100 BLOCKS should contain PROJ-200 exactly once
      (goto-char (point-min))
      (re-search-forward "PROJ-100" nil t)
      (let ((blocks (org-entry-get (point) "BLOCKS")))
        (should blocks)
        ;; Count occurrences of PROJ-200
        (let ((count 0)
              (start 0))
          (while (string-match "PROJ-200" blocks start)
            (setq count (1+ count))
            (setq start (match-end 0)))
          (should (= count 1)))))))

(ert-deftest org-tickets-test--create-link-sends-correct-direction ()
  "Test that org-tickets--async-create-link sends inwardIssue=blocker, outwardIssue=blocked.
In the Jira POST API, inwardIssue is the blocker and outwardIssue is the blocked.
This matches the GET response where outwardIssue on ticket X means X blocks it."
  (let ((captured-data nil))
    (org-tickets-test--with-stubs ((org-tickets--async-request
                                 (lambda (_method _endpoint callback &optional data)
                                   (setq captured-data data)
                                   (funcall callback nil nil))))
      (org-tickets--async-create-link "PROJ-100" "PROJ-200" "Blocks"
                                   (lambda (_r _e) nil))
      ;; PROJ-100 is the blocker (inwardIssue in POST)
      ;; PROJ-200 is the blocked (outwardIssue in POST)
      (let ((outward (cdr (assoc "outwardIssue" captured-data)))
            (inward (cdr (assoc "inwardIssue" captured-data))))
        (should (string= (cdr (assoc "key" inward)) "PROJ-100"))
        (should (string= (cdr (assoc "key" outward)) "PROJ-200"))))))

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
               (story (car (org-tickets--doc-children doc)))
               (org-buf (current-buffer)))
          (org-tickets--async-sync-ticket-links story org-buf
                                             (lambda () (setq callback-called t)))
          ;; Should create a "Blocks" link from PROJ-100 (blocker) to PROJ-200 (blocked)
          (should callback-called)
          (should (member (list "PROJ-100" "PROJ-200" "Blocks") created-links)))))))

(ert-deftest org-tickets-test--sync-links-for-features ()
  "Test that link sync runs for features, not just stories.
If Feature PROJ-100 has BLOCKED-BY: PROJ-300, that link should be synced."
  (let ((created-links nil))
    (org-tickets-test--with-stubs ((org-tickets--api-request
                                 (lambda (_method _endpoint _data) nil))
                                (org-tickets--async-create-link
                                 (lambda (from-key to-key link-type callback)
                                   (push (list from-key to-key link-type) created-links)
                                   (funcall callback nil nil)))
                                (org-tickets--resolve-config #'ignore)
                                (org-tickets--ensure-issue-types #'ignore)
                                (org-tickets--clear-sprint-cache #'ignore)
                                (org-tickets--async-request
                                 (lambda (method endpoint callback &optional data)
                                   (funcall callback
                                            (list (cons "fields"
                                                        (list (cons "attachment" nil)
                                                              (cons "customfield_10020" nil)
                                                              (cons "duedate" nil))))
                                            nil)))
                                (org-tickets--async-upload-attachments
                                 (lambda (_key _atts callback) (funcall callback nil nil)))
                                (org-tickets--async-download-attachments
                                 (lambda (_key _atts callback) (funcall callback nil nil)))
                                (org-tickets--resolve-blocked-by-in-org #'ignore))
      (with-temp-buffer
        (insert "* Feature A
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:BLOCKED-BY: PROJ-300
:END:
* Feature B
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-300
:END:
")
        (org-mode)
        (org-tickets--sync-to-jira)
        ;; Should create a "Blocks" link from PROJ-300 (blocker) to PROJ-100 (blocked)
        (should (member (list "PROJ-300" "PROJ-100" "Blocks") created-links))))))

(ert-deftest org-tickets-test--sync-creates-links-without-buffer-resolution ()
  "Test that full sync creates correct links even when BLOCKS is empty in buffer.
This verifies the sync path works from struct data alone, not buffer mutations."
  (let ((created-links nil))
    (org-tickets-test--with-stubs ((org-tickets--api-request
                                 (lambda (_method _endpoint _data) nil))
                                (org-tickets--async-create-link
                                 (lambda (from-key to-key link-type callback)
                                   (push (list from-key to-key link-type) created-links)
                                   (funcall callback nil nil)))
                                (org-tickets--resolve-config #'ignore)
                                (org-tickets--ensure-issue-types #'ignore)
                                (org-tickets--clear-sprint-cache #'ignore)
                                (org-tickets--async-request
                                 (lambda (method endpoint callback &optional data)
                                   (funcall callback
                                            (list (cons "fields"
                                                        (list (cons "attachment" nil)
                                                              (cons "customfield_10020" nil)
                                                              (cons "duedate" nil))))
                                            nil)))
                                (org-tickets--async-upload-attachments
                                 (lambda (_key _atts callback) (funcall callback nil nil)))
                                (org-tickets--async-download-attachments
                                 (lambda (_key _atts callback) (funcall callback nil nil)))
                                (org-tickets--resolve-blocked-by-in-org #'ignore))
      (with-temp-buffer
        (insert "* Parent Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:END:
** Story A
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:BLOCKED-BY: PROJ-100
:END:
** Story B
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-300
:BLOCKS: PROJ-200
:END:
")
        (org-mode)
        (org-tickets--sync-to-jira)
        ;; BLOCKED-BY: PROJ-200 blocked by PROJ-100 → link PROJ-100 blocks PROJ-200
        (should (member (list "PROJ-100" "PROJ-200" "Blocks") created-links))
        ;; BLOCKS: PROJ-300 blocks PROJ-200
        (should (member (list "PROJ-300" "PROJ-200" "Blocks") created-links))))))

(ert-deftest org-tickets-test--create-link-inward-is-blocker ()
  "Regression: inwardIssue must be the blocker, outwardIssue the blocked.
This matches GET semantics: viewing ticket X with outwardIssue=Y means X blocks Y.
So if A blocks B: inwardIssue=A, outwardIssue=B."
  (let ((captured-data nil))
    (org-tickets-test--with-stubs ((org-tickets--async-request
                                 (lambda (_method _endpoint callback &optional data)
                                   (setq captured-data data)
                                   (funcall callback nil nil))))
      (org-tickets--async-create-link "BLOCKER-1" "BLOCKED-2" "Blocks"
                                   (lambda (_r _e) nil))
      (let ((outward (cdr (assoc "outwardIssue" captured-data)))
            (inward (cdr (assoc "inwardIssue" captured-data))))
        ;; inwardIssue = the blocker
        (should (string= (cdr (assoc "key" inward)) "BLOCKER-1"))
        ;; outwardIssue = the blocked
        (should (string= (cdr (assoc "key" outward)) "BLOCKED-2"))))))

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
               (story (car (org-tickets--doc-children doc)))
               (org-buf (current-buffer)))
          (org-tickets--async-sync-ticket-links story org-buf
                                             (lambda () (setq callback-called t)))
          (should callback-called)
          ;; Should create a "Blocks" link from PROJ-200 to PROJ-500
          (should (member (list "PROJ-200" "PROJ-500" "Blocks") created-links)))))))

(ert-deftest org-tickets-test--due-date-inherited-from-external-parent ()
  "A parent absent from the buffer supplies its due date from Jira."
  (org-tickets-test--with-stubs
      ((org-tickets--get-ticket
        (lambda (_key) (org-tickets-test--make-get-response nil "2026-11-01"))))
    (with-temp-buffer
      (insert "* My Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:PARENT: PROJ-500
:END:
")
      (org-mode)
      (org-tickets--inherit-due-date "PROJ-200" "PROJ-500")
      (goto-char (point-min))
      (re-search-forward "PROJ-200" nil t)
      (should (equal (org-entry-get (point) "DUE_DATE") "2026-11-01")))))

(ert-deftest org-tickets-test--due-date-inheritance-external-parent-without-date ()
  "An external parent with no due date in Jira leaves the child unset."
  (org-tickets-test--with-stubs
      ((org-tickets--get-ticket (lambda (_key) (org-tickets-test--make-get-response))))
    (with-temp-buffer
      (insert "* My Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:PARENT: PROJ-500
:END:
")
      (org-mode)
      (org-tickets--inherit-due-date "PROJ-200" "PROJ-500")
      (goto-char (point-min))
      (re-search-forward "PROJ-200" nil t)
      (should-not (org-entry-get (point) "DUE_DATE")))))

(ert-deftest org-tickets-test--invalid-parent-key-rejected ()
  "Test that an invalid PARENT value is ignored during parsing."
  (with-temp-buffer
    (insert "* My Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:PARENT: not-a-key
:END:
")
    (org-mode)
    (let* ((doc (org-tickets--parse-document))
           (story (car (org-tickets--doc-children doc))))
      (should-not (org-tickets--ticket-parent story)))))

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
          (org-tickets--async-sync-ticket-links story (current-buffer)
                                             (lambda () (setq done t)))
          (should done)))
      (should (member '("P-2" "P-1" "Blocks") links)))))

(ert-deftest org-tickets-test--link-failures-are-logged ()
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
        (org-tickets--async-sync-ticket-links story (current-buffer) #'ignore))
      (should (seq-some (lambda (m) (string-match-p "403 Forbidden" m)) logged)))))

(provide 'org-tickets-test-sync-links)

;;; org-tickets-test-sync-links.el ends here
