;;; org-tickets-test-inheritance.el --- Parent-inheritance tests  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Neil Locketz

;; Author: Neil Locketz <neil@nlocketz.com>
;; Keywords: org, jira, tests

;;; Commentary:

;; Regression tests for what a child ticket takes from its parent.
;;
;; A child with no DUE_DATE or FIX_VERSION of its own takes its parent's,
;; and the value must reach Jira on the SAME sync that discovers it.
;; Three separate bugs are pinned here:
;;
;;   - Inheritance ran only in phase 3, after every create/update call had
;;     been sent, so the value landed in the org buffer but Jira kept an
;;     empty due date until the next sync.
;;   - It skipped tickets created during the run, whose ticket struct
;;     carries no key until the buffer is updated.
;;   - Fix version was never inherited at all, and only tickets literally
;;     typed "Story" counted as children -- a Task got no inheritance, no
;;     parent link, and on the sequential phase-1 path no Jira issue.
;;
;; Assertions on request payloads are deliberate: a value that reaches the
;; org drawer but never leaves Emacs must fail these tests.

;;; Code:

(require 'ert)
(require 'org)
(require 'org-tickets-test-fixtures)

(require 'org-tickets)

;;;; Helpers

(defun org-tickets-test--due-date-of (key)
  "Return the DUE_DATE property of the heading whose JIRA_KEY is KEY."
  (save-excursion
    (goto-char (org-tickets--find-ticket-by-key key))
    (org-entry-get (point) "DUE_DATE")))

(defun org-tickets-test--fix-version-of (key)
  "Return the FIX_VERSION property of the heading whose JIRA_KEY is KEY."
  (save-excursion
    (goto-char (org-tickets--find-ticket-by-key key))
    (org-entry-get (point) "FIX_VERSION")))

(defun org-tickets-test--payload-due-date (data)
  "Return the duedate field of a request DATA payload, or nil."
  (cdr (assq 'duedate (cdr (assq 'fields data)))))

(defun org-tickets-test--payload-fix-version (data)
  "Return the single fixVersions name in a request DATA payload, or nil."
  (cdr (assoc "name" (car (cdr (assq 'fixVersions (cdr (assq 'fields data))))))))

(defun org-tickets-test--insert-child (title type &optional key)
  "Insert a level-2 ticket heading with TITLE, JIRA_TYPE TYPE and KEY."
  (goto-char (point-max))
  (insert (format "** %s\n" title))
  (org-entry-put (point) "JIRA_TYPE" type)
  (when key
    (org-entry-put (point) "JIRA_KEY" key)))

;;;; The buffer pass

(ert-deftest org-tickets-test--due-date-inherited-from-outline-parent ()
  "A child heading with no due date takes its parent's."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n"
            ":DUE_DATE: 2026-08-01\n:END:\n"
            "** Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-2\n:END:\n")
    (org-tickets--inherit-parent-properties-in-buffer)
    (should (equal (org-tickets-test--due-date-of "P-2") "2026-08-01"))))

(ert-deftest org-tickets-test--due-date-inheritance-cascades-through-levels ()
  "Inheritance reaches a grandchild through a parent that also inherited."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n"
            ":DUE_DATE: 2026-08-01\n:END:\n"
            "** Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-2\n:END:\n"
            "*** Subtask\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-3\n:END:\n")
    (org-tickets--inherit-parent-properties-in-buffer)
    (should (equal (org-tickets-test--due-date-of "P-2") "2026-08-01"))
    (should (equal (org-tickets-test--due-date-of "P-3") "2026-08-01"))))

(ert-deftest org-tickets-test--due-date-inheritance-keeps-existing-date ()
  "A child that already has its own due date keeps it."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n"
            ":DUE_DATE: 2026-08-01\n:END:\n"
            "** Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-2\n"
            ":DUE_DATE: 2026-07-15\n:END:\n")
    (org-tickets--inherit-parent-properties-in-buffer)
    (should (equal (org-tickets-test--due-date-of "P-2") "2026-07-15"))))

(ert-deftest org-tickets-test--due-date-inherited-via-parent-property ()
  "A story whose parent is not an outline ancestor inherits via PARENT."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n"
            ":DUE_DATE: 2026-08-01\n:END:\n"
            "* Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-2\n"
            ":PARENT: P-1\n:END:\n")
    (org-tickets--inherit-parent-properties-in-buffer)
    (should (equal (org-tickets-test--due-date-of "P-2") "2026-08-01"))))

(ert-deftest org-tickets-test--due-date-inherited-via-parent-property-when-nested ()
  "PARENT is honoured on a story nested under a non-ticket heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n"
            ":DUE_DATE: 2026-08-01\n:END:\n"
            "* Sprint notes\n"
            "** Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-2\n"
            ":PARENT: P-1\n:END:\n")
    (org-tickets--inherit-parent-properties-in-buffer)
    (should (equal (org-tickets-test--due-date-of "P-2") "2026-08-01"))))

(ert-deftest org-tickets-test--due-date-inherited-from-parent-not-in-buffer ()
  "A PARENT ticket absent from the buffer supplies its due date from Jira."
  (let ((fetched nil))
    (org-tickets-test--with-stubs
        ((org-tickets--get-ticket
          (lambda (key)
            (push key fetched)
            (org-tickets-test--make-get-response nil "2026-09-30"))))
      (with-temp-buffer
        (org-mode)
        (insert "* Story A\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-2\n"
                ":PARENT: P-1\n:END:\n"
                "* Story B\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-3\n"
                ":PARENT: P-1\n:END:\n")
        (org-tickets--inherit-parent-properties-in-buffer)
        (should (equal (org-tickets-test--due-date-of "P-2") "2026-09-30"))
        (should (equal (org-tickets-test--due-date-of "P-3") "2026-09-30"))))
    (should (equal fetched '("P-1")))))

(ert-deftest org-tickets-test--fix-version-inherited-from-parent-not-in-buffer ()
  "A PARENT ticket absent from the buffer supplies its fix version from Jira."
  (org-tickets-test--with-stubs
      ((org-tickets--get-ticket
        (lambda (_key)
          (org-tickets-test--json
           "{\"fields\": {\"fixVersions\": [{\"name\": \"25.3\"}, {\"name\": \"25.4\"}]}}"))))
    (with-temp-buffer
      (org-mode)
      (insert "* Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-2\n"
              ":PARENT: P-1\n:END:\n")
      (org-tickets--inherit-parent-properties-in-buffer)
      (should (equal (org-tickets-test--fix-version-of "P-2") "25.3")))))

(ert-deftest org-tickets-test--due-date-inheritance-survives-parent-fetch-error ()
  "A failed fetch of an out-of-buffer parent leaves the child unset."
  (org-tickets-test--with-stubs
      ((org-tickets--get-ticket (lambda (_key) (error "Jira API error: 404"))))
    (with-temp-buffer
      (org-mode)
      (insert "* Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-2\n"
              ":PARENT: P-1\n:END:\n")
      (org-tickets--inherit-parent-properties-in-buffer)
      (should-not (org-tickets-test--due-date-of "P-2")))))

(ert-deftest org-tickets-test--due-date-inheritance-without-parent-date-is-noop ()
  "Nothing is written when no ancestor has a due date."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n:END:\n"
            "** Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-2\n:END:\n")
    (org-tickets--inherit-parent-properties-in-buffer)
    (should-not (org-tickets-test--due-date-of "P-2"))))

(ert-deftest org-tickets-test--due-date-inheritance-ignores-non-ticket-headings ()
  "A plain org heading with a DUE_DATE is not a source of inheritance."
  (with-temp-buffer
    (org-mode)
    (insert "* Notes\n:PROPERTIES:\n:DUE_DATE: 2026-01-01\n:END:\n"
            "** Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-2\n:END:\n")
    (org-tickets--inherit-parent-properties-in-buffer)
    (should-not (org-tickets-test--due-date-of "P-2"))))

;;;; The inherited date reaches Jira on the same sync

(ert-deftest org-tickets-test--new-story-sends-inherited-due-date-on-first-sync ()
  "A story created this sync is POSTed with the due date it inherits.
The date used to be written to org only in phase 3, after the POST, so
Jira kept an empty due date until the next sync."
  (let ((post-payloads nil))
    (org-tickets-test--with-sync-mocks
        (lambda (method _endpoint callback &optional data)
          (pcase method
            ("GET" (funcall callback (org-tickets-test--make-get-response) nil))
            ("PUT" (funcall callback nil nil))
            ("POST" (push data post-payloads)
             (funcall callback (list (cons "key" "P-2")) nil))))
      (with-temp-buffer
        (org-mode)
        (org-tickets-test--insert-feature "Feature" "P-1")
        (org-entry-put (point) "DUE_DATE" "2026-08-01")
        (goto-char (point-max))
        (org-tickets-test--insert-story "New Story" nil nil)
        (org-tickets-test--run-sync)
        ;; ...and org records it too.
        (should (equal (org-tickets-test--due-date-of "P-2") "2026-08-01"))))
    (should (= 1 (length post-payloads)))
    (should (equal (org-tickets-test--payload-due-date (car post-payloads))
                   "2026-08-01"))))

(ert-deftest org-tickets-test--existing-story-sends-inherited-due-date ()
  "An existing story with no due date is PUT with the one it inherits."
  (let ((put-payloads nil))
    (org-tickets-test--with-sync-mocks
        (lambda (method endpoint callback &optional data)
          (pcase method
            ("GET" (funcall callback (org-tickets-test--make-get-response) nil))
            ("PUT" (when (string-suffix-p "P-2" endpoint)
                     (push data put-payloads))
             (funcall callback nil nil))))
      (with-temp-buffer
        (org-mode)
        (org-tickets-test--insert-feature "Feature" "P-1")
        (org-entry-put (point) "DUE_DATE" "2026-08-01")
        (goto-char (point-max))
        (org-tickets-test--insert-story "Story" "P-2" nil)
        (org-tickets-test--run-sync)))
    (should (= 1 (length put-payloads)))
    (should (equal (org-tickets-test--payload-due-date (car put-payloads))
                   "2026-08-01"))))

(ert-deftest org-tickets-test--jira-due-date-wins-over-parent-inheritance ()
  "A due date already set in Jira is not replaced by the parent's."
  (org-tickets-test--with-sync-mocks
      (lambda (method endpoint callback &optional _data)
        (pcase method
          ("GET" (funcall callback
                          (org-tickets-test--make-get-response
                           nil (and (string-suffix-p "P-2" endpoint) "2026-07-15"))
                          nil))
          ("PUT" (funcall callback nil nil))))
    (with-temp-buffer
      (org-mode)
      (org-tickets-test--insert-feature "Feature" "P-1")
      (org-entry-put (point) "DUE_DATE" "2026-08-01")
      (goto-char (point-max))
      (org-tickets-test--insert-story "Story" "P-2" nil)
      (org-tickets-test--run-sync)
      (should (equal (org-tickets-test--due-date-of "P-2") "2026-07-15")))))

;;;; Phase 3 inheritance for tickets created during the run

(ert-deftest org-tickets-test--phase-3-inheritance-uses-the-buffer-key ()
  "Phase-3 inheritance re-reads the key the buffer just received, so a
story created during this sync inherits a parent date that only arrived
from Jira in phase 1 (its ticket struct still has no key)."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n"
            ":DUE_DATE: 2026-08-01\n:END:\n"
            "** Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:END:\n")
    (let* ((doc (org-tickets--parse-document))
           (story (car (org-tickets--doc-children doc))))
      ;; Simulate phase 2 having written the freshly created key.
      (org-tickets--set-org-ticket-key story "P-2")
      (org-tickets--apply-due-date-inheritance doc)
      (should (equal (org-tickets-test--due-date-of "P-2") "2026-08-01")))))

;;;; Fix version

(ert-deftest org-tickets-test--fix-version-inherited-from-parent ()
  "A child with no FIX_VERSION takes its parent's."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n"
            ":FIX_VERSION: Aug2026\n:END:\n"
            "** Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-2\n:END:\n")
    (org-tickets--inherit-parent-properties-in-buffer)
    (should (equal (org-tickets-test--fix-version-of "P-2") "Aug2026"))))

(ert-deftest org-tickets-test--fix-version-inheritance-keeps-existing ()
  "A child that already has a FIX_VERSION keeps it."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n"
            ":FIX_VERSION: Aug2026\n:END:\n"
            "** Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-2\n"
            ":FIX_VERSION: Nov2026\n:END:\n")
    (org-tickets--inherit-parent-properties-in-buffer)
    (should (equal (org-tickets-test--fix-version-of "P-2") "Nov2026"))))

(ert-deftest org-tickets-test--new-story-sends-inherited-fix-version ()
  "A story created this sync is POSTed with the fix version it inherits.
`org-tickets--inherit-fix-version' existed but was never called from
anywhere, so a story synced without a FIX_VERSION got none -- in org or
in Jira -- while `org-tickets-insert-story-template' documented otherwise."
  (let ((post-payloads nil))
    (org-tickets-test--with-sync-mocks
        (lambda (method _endpoint callback &optional data)
          (pcase method
            ("GET" (funcall callback (org-tickets-test--make-get-response) nil))
            ("PUT" (funcall callback nil nil))
            ("POST" (push data post-payloads)
             (funcall callback (list (cons "key" "P-2")) nil))))
      (with-temp-buffer
        (org-mode)
        (org-tickets-test--insert-feature "Feature" "P-1")
        (org-entry-put (point) "FIX_VERSION" "Aug2026")
        (org-tickets-test--insert-child "New Story" "Story")
        (org-tickets-test--run-sync)
        (should (equal (org-tickets-test--fix-version-of "P-2") "Aug2026"))))
    (should (= 1 (length post-payloads)))
    (should (equal (org-tickets-test--payload-fix-version (car post-payloads))
                   "Aug2026"))))

;;;; Ticket types other than Story are children too

(ert-deftest org-tickets-test--task-inherits-parent-properties ()
  "A Task inherits its parent's due date and fix version, like a Story."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n"
            ":DUE_DATE: 2026-08-01\n:FIX_VERSION: Aug2026\n:END:\n"
            "** Task\n:PROPERTIES:\n:JIRA_TYPE: Task\n:JIRA_KEY: P-2\n:END:\n")
    (org-tickets--inherit-parent-properties-in-buffer)
    (should (equal (org-tickets-test--due-date-of "P-2") "2026-08-01"))
    (should (equal (org-tickets-test--fix-version-of "P-2") "Aug2026"))))

(ert-deftest org-tickets-test--task-is-parsed-as-a-child-ticket ()
  "A Task lands in the document's child tickets, not just its ticket list."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n:END:\n"
            "** Task\n:PROPERTIES:\n:JIRA_TYPE: Task\n:JIRA_KEY: P-2\n:END:\n")
    (let ((doc (org-tickets--parse-document)))
      (should (= 1 (length (org-tickets--doc-children doc))))
      (should (equal (org-tickets--ticket-type (car (org-tickets--doc-children doc)))
                     "Task")))))

(ert-deftest org-tickets-test--task-gets-parent-blocks-link ()
  "A Task blocks its parent Feature, exactly as a Story does."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n:END:\n"
            "** Task\n:PROPERTIES:\n:JIRA_TYPE: Task\n:JIRA_KEY: P-2\n:END:\n")
    (let* ((doc (org-tickets--parse-document))
           (task (car (org-tickets--doc-children doc)))
           (links nil))
      (org-tickets-test--with-stubs ((org-tickets--async-create-link
                                   (lambda (from to type callback)
                                     (push (list from to type) links)
                                     (funcall callback nil nil))))
        (org-tickets--async-sync-ticket-links task (current-buffer) #'ignore))
      (should (member '("P-2" "P-1" "Blocks") links)))))

(ert-deftest org-tickets-test--task-is-created-when-a-feature-lacks-a-key ()
  "Every non-Feature ticket is created on the sequential path.
Phase 1 used to fire a features batch and then a STORIES batch, so a
ticket that was neither -- a Task, a Bug -- was silently dropped: never
created in Jira, yet the sync reported success."
  (let ((created nil))
    (org-tickets-test--with-sync-mocks
        (lambda (method _endpoint callback &optional data)
          (pcase method
            ("GET" (funcall callback (org-tickets-test--make-get-response) nil))
            ("PUT" (funcall callback nil nil))
            ("POST" (push (cdr (assq 'summary (cdr (assq 'fields data)))) created)
             (funcall callback (list (cons "key" "P-9")) nil))))
      (let ((org-tickets--issue-type-ids
             (list (cons "Feature" "10000") (cons "New Feature" "10000")
                   (cons "Story" "10001") (cons "Task" "10002")
                   (cons "Bug" "10003"))))
        (with-temp-buffer
          (org-mode)
          ;; Feature has no key, which selects the sequential path.
          (org-tickets-test--insert-feature "New Feature" nil)
          (org-tickets-test--insert-child "A Task" "Task")
          (org-tickets-test--insert-child "A Bug" "Bug")
          (org-tickets-test--run-sync))))
    (should (equal (sort created #'string<)
                   '("A Bug" "A Task" "New Feature")))))

;;;; Custom issue types are children too

(ert-deftest org-tickets-test--merge-is-parsed-as-a-child-ticket ()
  "A Merge lands in the document's child tickets."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n:END:\n"
            "** Merge\n:PROPERTIES:\n:JIRA_TYPE: Merge\n:JIRA_KEY: P-2\n:END:\n")
    (let ((doc (org-tickets--parse-document)))
      (should (= 1 (length (org-tickets--doc-children doc))))
      (should (equal (org-tickets--ticket-type (car (org-tickets--doc-children doc)))
                     "Merge")))))

(ert-deftest org-tickets-test--merge-gets-parent-blocks-link ()
  "A Merge blocks its parent Feature, exactly as a Story does."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n:END:\n"
            "** Merge\n:PROPERTIES:\n:JIRA_TYPE: Merge\n:JIRA_KEY: P-2\n:END:\n")
    (let* ((doc (org-tickets--parse-document))
           (merge (car (org-tickets--doc-children doc)))
           (links nil))
      (org-tickets-test--with-stubs ((org-tickets--async-create-link
                                   (lambda (from to type callback)
                                     (push (list from to type) links)
                                     (funcall callback nil nil))))
        (org-tickets--async-sync-ticket-links merge (current-buffer) #'ignore))
      (should (member '("P-2" "P-1" "Blocks") links)))))

(ert-deftest org-tickets-test--merge-inherits-parent-properties ()
  "A Merge inherits its parent's due date and fix version, like a Story."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n"
            ":DUE_DATE: 2026-08-01\n:FIX_VERSION: Aug2026\n:END:\n"
            "** Merge\n:PROPERTIES:\n:JIRA_TYPE: Merge\n:JIRA_KEY: P-2\n:END:\n")
    (org-tickets--inherit-parent-properties-in-buffer)
    (should (equal (org-tickets-test--due-date-of "P-2") "2026-08-01"))
    (should (equal (org-tickets-test--fix-version-of "P-2") "Aug2026"))))

(ert-deftest org-tickets-test--unknown-custom-type-is-a-child-ticket ()
  "Any type that is not a parent type counts as a child.
Enumerating child types is what left Task, Bug and then Merge without a
parent link; a type org-tickets has never heard of must not repeat it."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n:END:\n"
            "** Spike\n:PROPERTIES:\n:JIRA_TYPE: Spike\n:JIRA_KEY: P-2\n:END:\n")
    (let ((doc (org-tickets--parse-document)))
      (should (equal (mapcar #'org-tickets--ticket-type (org-tickets--doc-children doc))
                     '("Spike"))))))

(ert-deftest org-tickets-test--parent-types-are-not-children ()
  "A parent type never counts as a child, so it never blocks its ancestor."
  (should-not (org-tickets--child-type-p "Feature"))
  (should-not (org-tickets--child-type-p "New Feature"))
  (should-not (org-tickets--child-type-p "Improvement"))
  (should-not (org-tickets--child-type-p "Epic"))
  (should-not (org-tickets--child-type-p ""))
  (should-not (org-tickets--child-type-p nil)))

;;;; PARENT precedence

(ert-deftest org-tickets-test--parent-property-wins-over-outline-ancestor ()
  "A story under Feature A with PARENT B inherits from B, the ticket it links to."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature A\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n"
            ":DUE_DATE: 2026-08-01\n:FIX_VERSION: A-1\n:END:\n"
            "** Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-3\n"
            ":PARENT: P-2\n:END:\n"
            "* Feature B\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-2\n"
            ":DUE_DATE: 2026-09-01\n:FIX_VERSION: B-1\n:END:\n")
    (org-tickets--inherit-parent-properties-in-buffer)
    (should (equal (org-tickets-test--due-date-of "P-3") "2026-09-01"))
    (should (equal (org-tickets-test--fix-version-of "P-3") "B-1"))))

(ert-deftest org-tickets-test--outline-ancestor-used-when-parent-lacks-value ()
  "When the PARENT ticket has no value, the outline ancestor still supplies one."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature A\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n"
            ":DUE_DATE: 2026-08-01\n:END:\n"
            "** Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: P-3\n"
            ":PARENT: P-2\n:END:\n"
            "* Feature B\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-2\n:END:\n")
    (org-tickets--inherit-parent-properties-in-buffer)
    (should (equal (org-tickets-test--due-date-of "P-3") "2026-08-01"))))

;;;; org-tickets-create-story

(defmacro org-tickets-test--capturing-create-story (created &rest body)
  "Run BODY with ticket creation stubbed; push each call's args onto CREATED."
  (declare (indent 1))
  `(org-tickets-test--with-stubs
       ((org-tickets--create-ticket
         (lambda (&rest args)
           (push args ,created)
           (list (cons 'key "P-9")))))
     (let ((org-tickets-default-sprint nil))
       ,@body)))

(ert-deftest org-tickets-test--create-story-sends-feature-due-date ()
  "A story created under an in-buffer feature is POSTed with its due date."
  (let ((created nil))
    (org-tickets-test--capturing-create-story created
      (with-temp-buffer
        (org-mode)
        (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n"
                ":DUE_DATE: 2026-08-01\n:FIX_VERSION: 25.3\n:END:\n")
        (org-tickets-create-story "P-1" "New story")))
    (let ((args (car created)))
      (should (equal (nth 3 args) "25.3"))
      (should (equal (nth 8 args) "2026-08-01")))))

(ert-deftest org-tickets-test--create-story-under-feature-not-in-buffer ()
  "A feature absent from the buffer is read from Jira, and the story is inserted."
  (let ((created nil))
    (org-tickets-test--capturing-create-story created
      (org-tickets-test--with-stubs
          ((org-tickets--get-ticket
            (lambda (_key)
              (org-tickets-test--json
               (concat "{\"fields\": {\"duedate\": \"2026-09-30\","
                       " \"labels\": [\"Team\"],"
                       " \"fixVersions\": [{\"name\": \"25.4\"}]}}")))))
        (with-temp-buffer
          (org-mode)
          (insert "* Unrelated\n")
          (should (equal (org-tickets-create-story "P-1" "New story") "P-9"))
          (goto-char (org-tickets--find-ticket-by-key "P-9"))
          (should (equal (org-entry-get (point) "PARENT") "P-1"))
          (should (equal (org-entry-get (point) "LABELS") "Team")))))
    (let ((args (car created)))
      (should (equal (nth 3 args) "25.4"))
      (should (equal (nth 4 args) '("Team")))
      (should (equal (nth 8 args) "2026-09-30")))))

(provide 'org-tickets-test-inheritance)

;;; org-tickets-test-inheritance.el ends here
