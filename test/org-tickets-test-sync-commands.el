;;; org-tickets-test-sync-commands.el --- Tests for org-tickets-sync.el commands  -*- lexical-binding: t; -*-

;;; Commentary:

;; The synchronous commands of org-tickets-sync.el: story creation, block
;; links, fix versions, sizing labels and issue-type loading.

;;; Code:

(require 'ert)
(require 'org)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

(defmacro org-tickets-test--with-command-jira (log &rest body)
  "Run BODY in an org buffer holding Feature PROJ-1, against a fake Jira.
Both the synchronous and the async request layers answer through one
`org-tickets-test--fake-jira-handler' logging onto LOG; issue creates
return PROJ-NEW."
  (declare (indent 1))
  `(let ((handler (org-tickets-test--fake-jira-handler :log ,log)))
     (org-tickets-test--with-fake-api handler
       (org-tickets-test--with-stubs ((org-tickets--async-request handler))
         (with-temp-buffer
           (org-mode)
           (org-tickets-test--insert-feature "Feature" "PROJ-1")
           ,@body)))))

;;;; Fix version

(ert-deftest org-tickets-test--set-fix-version-rejects-invalid-version ()
  "An invalid Fix Version signals, sends nothing and leaves FIX_VERSION alone."
  (let ((requests nil))
    (org-tickets-test--with-command-jira requests
      (org-entry-put (org-tickets--find-ticket-by-key "PROJ-1")
                     "FIX_VERSION" "Aug2026")
      (should-error (org-tickets-set-fix-version "PROJ-1" "Smarch2026"))
      (should (equal (org-tickets-test--prop-of "PROJ-1" "FIX_VERSION")
                     "Aug2026")))
    (should-not requests)))

;;;; Story creation

(ert-deftest org-tickets-test--create-story-uses-default-sprint ()
  "Without an explicit sprint the configured default is written as SPRINT."
  (let ((requests nil))
    (org-tickets-test--with-command-jira requests
      (let ((org-tickets-default-sprint "42"))
        (org-tickets-create-story "PROJ-1" "New story"))
      (should (equal (org-tickets-test--prop-of "PROJ-NEW" "SPRINT") "42")))))

(ert-deftest org-tickets-test--create-story-links-blocks-list ()
  "Each key in BLOCKS-LIST gets a Blocks link and lands in BLOCKS."
  (let ((requests nil))
    (org-tickets-test--with-command-jira requests
      (org-tickets-create-story "PROJ-1" "New story" nil '("PROJ-5" "PROJ-6"))
      (should (equal (org-tickets-test--prop-of "PROJ-NEW" "BLOCKS")
                     "PROJ-5,PROJ-6")))
    (should (equal (org-tickets-test--logged-links requests)
                   '(("PROJ-NEW" "PROJ-5" "Blocks")
                     ("PROJ-NEW" "PROJ-6" "Blocks"))))))

(ert-deftest org-tickets-test--create-story-defaults-needs-sizing-label ()
  "A story under a feature without labels is created labelled NeedsSizing."
  (let ((requests nil))
    (org-tickets-test--with-command-jira requests
      (org-tickets-create-story "PROJ-1" "New story")
      (should (equal (org-tickets-test--prop-of "PROJ-NEW" "LABELS")
                     "NeedsSizing")))
    (let ((create (car (org-tickets-test--requests
                        requests "POST" "/rest/api/3/issue"))))
      (should (equal (append (org-tickets-test--payload-field (nth 2 create) 'labels)
                             nil)
                     '("NeedsSizing"))))))

(ert-deftest org-tickets-test--story-parent-values-signals-when-unfetchable ()
  "A feature Jira cannot return signals an error and no story is created."
  (let ((requests nil))
    (org-tickets-test--with-fake-api
        (org-tickets-test--fake-jira-handler :log requests :get #'ignore)
      (with-temp-buffer
        (org-mode)
        (should-error (org-tickets--story-parent-values "PROJ-9"))
        (should-error (org-tickets-create-story "PROJ-9" "New story"))))
    (should-not (org-tickets-test--requests requests "POST"))))

(ert-deftest org-tickets-test--story-parent-values-propagates-fetch-error ()
  "A failing feature fetch propagates its error."
  (org-tickets-test--with-fake-config
    (org-tickets-test--with-stubs
        ((org-tickets--api-request
          (lambda (&rest _) (error "Jira API error: 404"))))
      (with-temp-buffer
        (org-mode)
        (should-error (org-tickets--story-parent-values "PROJ-9"))))))

;;;; Block links

(ert-deftest org-tickets-test--add-block-link-reports-failure ()
  "A rejected link is reported as a failure, not as created."
  (let ((messages nil))
    (org-tickets-test--with-stubs
        ((org-tickets--async-request
          (lambda (_method _endpoint callback &optional _data)
            (funcall callback nil "403 Forbidden")))
         (message (lambda (fmt &rest args)
                    (push (apply #'format fmt args) messages))))
      (with-temp-buffer
        (org-mode)
        (org-tickets-add-block-link "P-1" "P-2")))
    (should (member "org-tickets: Failed to create link: 403 Forbidden" messages))
    (should-not (seq-find (lambda (m) (string-match-p "Created" m)) messages))))

(ert-deftest org-tickets-test--add-block-link-writes-blocked-by-on-target ()
  "The blocked ticket records the blocker in BLOCKED-BY, after existing ones."
  (let ((requests nil))
    (org-tickets-test--with-command-jira requests
      (org-tickets-test--insert-story "Story" "PROJ-2" "PROJ-1"
                                      "BLOCKED-BY" "PROJ-7")
      (org-tickets-add-block-link "PROJ-1" "PROJ-2")
      (should (equal (org-tickets-test--prop-of "PROJ-2" "BLOCKED-BY")
                     "PROJ-7,PROJ-1")))))

;;;; Sizing label

(ert-deftest org-tickets-test--sizing-label-untouched-when-option-nil ()
  "With no sizing label configured, LABELS is left as it was."
  (with-temp-buffer
    (org-mode)
    (org-tickets-test--insert-story "S" "P-1" nil "LABELS" "Other")
    (let ((org-tickets-needs-sizing-label nil))
      (org-tickets--update-sizing-label "P-1" nil)
      (org-tickets--update-sizing-label "P-1" 3))
    (should (equal (org-tickets-test--prop-of "P-1" "LABELS") "Other"))))

(ert-deftest org-tickets-test--sizing-label-not-added-twice ()
  "Ensuring the sizing label when already present keeps a single copy."
  (with-temp-buffer
    (org-mode)
    (org-tickets-test--insert-story "S" "P-1" nil "LABELS" "Other,NeedsSizing")
    (org-tickets--update-sizing-label "P-1" nil)
    (should (equal (org-tickets-test--prop-of "P-1" "LABELS")
                   "Other,NeedsSizing"))))

;;;; Issue types

(ert-deftest org-tickets-test--ensure-issue-types-keeps-loaded-types ()
  "Already-loaded issue types are neither re-read nor fetched."
  (let ((calls nil))
    (org-tickets-test--with-fake-config
      (org-tickets-test--with-stubs
          ((org-tickets--load-issue-types (lambda () (push 'load calls) nil))
           (org-tickets--fetch-issue-types (lambda () (push 'fetch calls) nil)))
        (let ((org-tickets--issue-type-ids '(("Story" . "10001"))))
          (org-tickets--ensure-issue-types)
          (should (equal org-tickets--issue-type-ids '(("Story" . "10001")))))))
    (should-not calls)))

(provide 'org-tickets-test-sync-commands)

;;; org-tickets-test-sync-commands.el ends here
