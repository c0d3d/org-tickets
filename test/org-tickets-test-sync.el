;;; org-tickets-test-sync.el --- Tests for org-tickets org property helpers and ticket payloads  -*- lexical-binding: t; -*-

(require 'ert)
(require 'org)
(require 'org-element)

(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; JSON responses

;;;; Tests for Org Property Helpers

(ert-deftest org-tickets-test--set-org-fix-version ()
  "Test setting FIX_VERSION property in org."
  (let ((content "* Test
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "\\*" nil t)
      (org-entry-put (point) "JIRA_KEY" "PROJ-999")
      (org-tickets--set-org-fix-version "PROJ-999" "Aug2026")
      (goto-char (point-min))
      (re-search-forward "PROJ-999" nil t)
      (should (string= (org-entry-get (point) "FIX_VERSION") "Aug2026")))))

(ert-deftest org-tickets-test--set-org-story-points ()
  "Test setting STORY_POINTS property in org."
  (let ((content "* Test
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "\\*" nil t)
      (org-entry-put (point) "JIRA_KEY" "PROJ-999")
      ;; Set story points
      (org-tickets--set-org-story-points "PROJ-999" 5)
      (goto-char (point-min))
      (re-search-forward "PROJ-999" nil t)
      (should (string= (org-entry-get (point) "STORY_POINTS") "5"))
      ;; Remove story points
      (org-tickets--set-org-story-points "PROJ-999" nil)
      (goto-char (point-min))
      (re-search-forward "PROJ-999" nil t)
      (should (null (org-entry-get (point) "STORY_POINTS"))))))

(ert-deftest org-tickets-test--update-sizing-label ()
  "Test updating NeedsSizing label."
  (let ((content "* Test
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "\\*" nil t)
      (org-entry-put (point) "JIRA_KEY" "PROJ-999")
      ;; Add NeedsSizing when no story points
      (org-tickets--update-sizing-label "PROJ-999" nil)
      (should (string-match-p "NeedsSizing" (or (org-entry-get (point) "LABELS") "")))
      ;; Remove NeedsSizing when story points set
      (org-entry-put (point) "LABELS" "NeedsSizing,SomeOther")
      (org-tickets--update-sizing-label "PROJ-999" 5)
      (should (not (string-match-p "NeedsSizing" (org-entry-get (point) "LABELS")))))))

(defun org-tickets-test--story-sizing-request (points)
  "Run `org-tickets-update-story-sizing' with POINTS on story P-1.
Return the (METHOD ENDPOINT BODY) of the single request sent, where BODY
is the JSON text that reaches Jira."
  (let ((sent nil))
    (org-tickets-test--with-stubs ((org-tickets--api-request
                                 (lambda (method endpoint &optional data)
                                   (push (list method endpoint
                                               (org-tickets--encode-request-data data))
                                         sent)
                                   nil)))
      (org-tickets-update-story-sizing "P-1" points))
    (should (= 1 (length sent)))
    (car sent)))

(ert-deftest org-tickets-test--update-story-sizing-zero-removes ()
  "0 story points clears the estimate instead of sending 0."
  (with-temp-buffer
    (org-mode)
    (insert "* S\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-1\n"
            ":STORY_POINTS: 5\n:LABELS:\n:END:\n")
    (should (equal (org-tickets-test--story-sizing-request 0)
                   '("PUT" "/rest/api/3/issue/P-1"
                     "{\"fields\":{\"customfield_10016\":null}}")))
    ;; Org property removed, NeedsSizing restored.
    (goto-char (point-min))
    (should (null (org-entry-get (point) "STORY_POINTS")))
    (should (string-match-p "NeedsSizing" (org-entry-get (point) "LABELS")))))

(ert-deftest org-tickets-test--update-story-sizing-sets-points ()
  "Positive story points are PUT as a number and recorded in org."
  (with-temp-buffer
    (org-mode)
    (insert "* S\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-1\n"
            ":LABELS: NeedsSizing\n:END:\n")
    (should (equal (org-tickets-test--story-sizing-request 5)
                   '("PUT" "/rest/api/3/issue/P-1"
                     "{\"fields\":{\"customfield_10016\":5}}")))
    (goto-char (point-min))
    (should (equal (org-entry-get (point) "STORY_POINTS") "5"))))

(ert-deftest org-tickets-test--sizing-label-list-operations ()
  "Removing NeedsSizing leaves no stray comma and never touches
labels that merely contain the substring."
  (with-temp-buffer
    (org-mode)
    (insert "* S\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-1\n"
            ":LABELS: NeedsSizing,Other,NeedsSizingReview\n:END:\n")
    (org-tickets--update-sizing-label "P-1" 5)
    (goto-char (point-min))
    (should (equal (org-entry-get (point) "LABELS")
                   "Other,NeedsSizingReview"))))

(ert-deftest org-tickets-test--insert-story-heading-nests-under-parent-level ()
  "Story headings are children of the parent's actual level, and LABELS
records exactly what create sent (not always NeedsSizing)."
  (with-temp-buffer
    (org-mode)
    (insert "* Container\n** Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n"
            ":JIRA_KEY: P-1\n:END:\n")
    (org-tickets--insert-story-heading "My story" "P-1" "P-2" nil '("lbl1" "lbl2"))
    (goto-char (point-min))
    (should (re-search-forward "^\\*\\*\\* My story$" nil t))
    (should (equal (org-entry-get (point) "LABELS") "lbl1,lbl2"))))

(ert-deftest org-tickets-test--sync-reset-recovers-stuck-buffer ()
  "Resetting a stuck sync unlocks the buffer and clears the guard."
  (with-temp-buffer
    (org-mode)
    (setq buffer-read-only t
          org-tickets--sync-in-progress t)
    (org-tickets-sync-reset)
    (should-not buffer-read-only)
    (should-not org-tickets--sync-in-progress)))

(ert-deftest org-tickets-test--cleanup-preserves-prior-read-only ()
  "A buffer that was read-only BEFORE sync stays read-only after."
  (with-temp-buffer
    (org-mode)
    (setq buffer-read-only t)
    (setq org-tickets--sync-prior-read-only buffer-read-only)
    (setq buffer-read-only t org-tickets--sync-in-progress t)
    (org-tickets--sync-cleanup)
    (should buffer-read-only)))

(ert-deftest org-tickets-test--create-ticket-payload ()
  "Creating a ticket record POSTs every field it carries."
  (let* ((org-tickets-project-id "12345")
         (org-tickets--issue-type-ids '(("Story" . "1") ("New Feature" . "2")))
         (org-tickets-default-sprint nil)
         (sent nil))
    (org-tickets-test--with-stubs ((org-tickets--ensure-issue-types #'ignore)
                                (org-tickets--api-request
                                 (lambda (m e &optional data)
                                   (setq sent (list m e data))
                                   '((key . "P-9")))))
      (should (equal (org-tickets--create-ticket
                      (org-tickets--ticket-create
                       :type "Story" :summary "S" :description "body"
                       :fix-version "Aug2026" :labels '("l")
                       :story-points 3 :due-date "2026-08-01"))
                     '((key . "P-9")))))
    (should (equal (butlast sent) '("POST" "/rest/api/3/issue")))
    (let ((fields (cdr (assq 'fields (nth 2 sent)))))
      (should (equal (alist-get 'project fields) '(("id" . "12345"))))
      (should (equal (alist-get 'issuetype fields) '(("id" . "1"))))
      (should (equal (alist-get 'summary fields) "S"))
      (should (alist-get 'description fields))
      (should (equal (alist-get 'fixVersions fields) '((("name" . "Aug2026")))))
      (should (equal (alist-get 'labels fields) '("l")))
      (should (equal (alist-get 'customfield_10016 fields) 3))
      (should (equal (alist-get 'duedate fields) "2026-08-01")))))

(ert-deftest org-tickets-test--json-null-clearing-round-trips-at-encode-site ()
  "Clearing a field produces literal JSON `null' through the same
dynamic `json-null' binding the real request path uses (see
`org-tickets--api-request' in org-tickets-api.el and the async request in
org-tickets-async.el) — not through a session-wide mutation of the
`json' library."
  (let* ((ticket (org-tickets--ticket-create
                  :key "P-1" :type "Story" :summary "S"
                  :story-points 0 :clear-story-points t))
         (fields (org-tickets--ticket-fields ticket))
         (field-key (intern org-tickets-story-points-field)))
    ;; The builder still hands back the `:json-null' sentinel, not a
    ;; literal JSON null — encoding happens only at the request site.
    (should (eq (cdr (assq field-key fields)) :json-null))
    (let ((json-null :json-null))
      (should (string-match-p
               (format "\"%s\":null" org-tickets-story-points-field)
               (json-encode (list (cons 'fields fields))))))))

(ert-deftest org-tickets-test--json-null-sentinel-does-not-leak-globally ()
  "Loading org-tickets must not mutate the default value of `json-null'
for the rest of the user's Emacs session; the `:json-null' clearing
sentinel is only meaningful inside the dynamic bindings at the two
request encode sites."
  (should (eq (default-value 'json-null) nil)))

(ert-deftest org-tickets-test--interactive-commands-have-public-names ()
  "The documented ticket commands are interactive."
  (dolist (cmd '(org-tickets-create-story org-tickets-add-block-link
                 org-tickets-set-fix-version org-tickets-update-story-sizing))
    (should (commandp cmd))))

(provide 'org-tickets-test-sync)

;;; org-tickets-test-sync.el ends here
