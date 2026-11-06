;;; org-tickets-test-parse.el --- Tests for org-tickets parsing functions  -*- lexical-binding: t; -*-

(require 'ert)
(require 'org)
(require 'org-element)

;; Load the main library
(require 'org-tickets)

;;;; Description extraction tests

(ert-deftest org-tickets-test--description-simple ()
  (let ((content "* Heading
Some description text."))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "^\*" nil t)
      (let* ((node (org-element-at-point))
             (desc (org-tickets--get-ticket-description node)))
        (should (string= desc "Some description text."))))))

(ert-deftest org-tickets-test--description-with-child-headings ()
  "Test that org-tickets--get-ticket-description gets content before first child heading."
  (let ((content "* Parent Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-123
:END:
This is the parent description.
** Child Story
:PROPERTIES:
:JIRA_TYPE: Story
:END:
Story description."))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "Parent Feature" nil t)
      (let* ((node (org-element-at-point))
             (desc (org-tickets--get-ticket-description node)))
        (should desc)
        (should (string= desc "This is the parent description."))))))

(ert-deftest org-tickets-test--description-includes-non-ticket-subheadings ()
  "Non-ticket child headings belong to the description; the first child
ticket ends it."
  (with-temp-buffer
    (insert "** Story
:PROPERTIES:
:JIRA_TYPE: Story
:END:
Intro.
*** Details
More.
*** Sub-task
:PROPERTIES:
:JIRA_TYPE: Sub-task
:END:
Child body.")
    (org-mode)
    (goto-char (point-min))
    (should (string= (org-tickets--get-ticket-description (org-element-at-point))
                     "Intro.\n*** Details\nMore."))))

(ert-deftest org-tickets-test--description-bold-not-confused-with-heading ()
  "Test that bold markup like **NOTE:** is not mistaken for a child heading."
  (let ((content "* My Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-200
:END:

**NOTE:** something something

more text
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "My Story" nil t)
      (let* ((node (org-element-at-point))
             (desc (org-tickets--get-ticket-description node)))
        (should desc)
        (should (string-match-p "\\*\\*NOTE:\\*\\*" desc))
        (should (string-match-p "more text" desc))))))

(ert-deftest org-tickets-test--description-with-properties-drawer ()
  "Test that org-tickets--get-ticket-description handles properties drawer correctly."
  (let ((content "* Test
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:END:
Description after properties drawer."))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "^\\* Test" nil t)
      (let* ((node (org-element-at-point))
             (desc (org-tickets--get-ticket-description node)))
        (should (string= desc "Description after properties drawer."))))))

;;;; Parent ticket key finding tests

(ert-deftest org-tickets-test--find-parent-ticket-key-from-outline ()
  "Test that org-tickets--find-parent-ticket-key finds parent from org hierarchy."
  (let ((content "* Parent Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-123
:END:
** Child Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-456
:END:
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      ;; Navigate to the Story heading
      (re-search-forward "^\\*\\* Child Story" nil t)
      (goto-char (match-beginning 0))
      (org-entry-put (point) "JIRA_TYPE" "Story")
      (org-entry-put (point) "JIRA_KEY" "PROJ-456")
      ;; Now test finding parent
      (let ((parent-key (org-tickets--find-parent-ticket-key)))
        (should (string= parent-key "PROJ-123"))))))

(ert-deftest org-tickets-test--find-parent-ticket-key-no-parent ()
  "Test that org-tickets--find-parent-ticket-key returns nil when no parent."
  (let ((content "* Standalone Story
:PROPERTIES:
:JIRA_TYPE: Story
:END:
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "Standalone Story" nil t)
      (goto-char (match-beginning 0))
      (let ((parent-key (org-tickets--find-parent-ticket-key)))
        (should (null parent-key))))))

(ert-deftest org-tickets-test--find-parent-ticket-key-empty-parent ()
  "Test that org-tickets--find-parent-ticket-key returns nil for empty JIRA_KEY."
  (let ((content "* Parent Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY:
:END:
** Child Story
:PROPERTIES:
:JIRA_TYPE: Story
:END:
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "^\\*\\* Child Story" nil t)
      (goto-char (match-beginning 0))
      (let ((parent-key (org-tickets--find-parent-ticket-key)))
        (should (null parent-key))))))

(ert-deftest org-tickets-test--empty-parent-property-handling ()
  "Test that empty PARENT property in org is treated as nil."
  (let ((content "* Parent Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-123
:END:
** Child Story
:PROPERTIES:
:JIRA_TYPE: Story
:PARENT:
:JIRA_KEY: PROJ-456
:END:
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "^\\*\\* Child Story" nil t)
      (goto-char (match-beginning 0))
      ;; Get the PARENT property - it should be an empty string
      (let ((parent-prop (org-entry-get (point) "PARENT")))
        ;; Simulate what the code does: check if it's an empty string
        (should (string= parent-prop ""))
        ;; Now test our check logic
        (should (null (and parent-prop (> (length parent-prop) 0))))))))

(ert-deftest org-tickets-test--parse-ticket-with-empty-parent ()
  "Test parsing a ticket with empty PARENT property returns nil for parent."
  (let ((content "* Parent Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-123
:END:
** Child Story
:PROPERTIES:
:JIRA_TYPE: Story
:PARENT:
:JIRA_KEY: PROJ-456
:END:
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "^\\*\\* Child Story" nil t)
      (let ((ticket (org-tickets--parse-ticket-at-point)))
        (should ticket)
        ;; Parent should be nil (not empty string) since PARENT: is empty
        (should (null (org-tickets--ticket-parent ticket)))))))

;;;; Tests for Ticket Parsing

(ert-deftest org-tickets-test--parse-document-multiple-tickets ()
  "Test parsing a document with multiple tickets."
  (let ((content "* Test Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:FIX_VERSION: Aug2026
:END:
Description here.
** Test Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-101
:BLOCKS: PROJ-100
:LABELS: NeedsSizing
:FIX_VERSION: Aug2026
:END:
Story description.
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (let ((doc (org-tickets--parse-document)))
        (should (= 2 (length (org-tickets--doc-tickets doc))))
        (should (= 1 (length (org-tickets--doc-features doc))))
        (should (= 1 (length (org-tickets--doc-children doc))))
        ;; Check feature
        (let ((feature (car (org-tickets--doc-features doc))))
          (should (string= (org-tickets--ticket-key feature) "PROJ-100"))
          (should (string= (org-tickets--ticket-type feature) "New Feature"))
          (should (string= (org-tickets--ticket-summary feature) "Test Feature"))
          (should (string= (org-tickets--ticket-fix-version feature) "Aug2026")))
        ;; Check story
        (let ((story (car (org-tickets--doc-children doc))))
          (should (string= (org-tickets--ticket-key story) "PROJ-101"))
          (should (string= (org-tickets--ticket-type story) "Story"))
          (should (string= (org-tickets--ticket-summary story) "Test Story"))
          (should (member "PROJ-100" (org-tickets--ticket-blocks story)))
          (should (member "NeedsSizing" (org-tickets--ticket-labels story))))))))

(ert-deftest org-tickets-test--parse-ticket-at-point-no-jira-type ()
  "A heading with no JIRA_TYPE property is not a ticket.
This is the contract that lets users keep a notes-only heading in
the document without it being synced to Jira."
  (let ((content "* Scratch notes
Just some free-form notes here.
No JIRA_TYPE property, so this must never become a ticket.
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "^\\* Scratch notes" nil t)
      (should (null (org-tickets--parse-ticket-at-point))))))

(ert-deftest org-tickets-test--parse-document-skips-notes-heading ()
  "A top-level notes heading (no JIRA_TYPE) is skipped, not synced.
Parsing a document that mixes a notes heading with a real ticket
must yield only the real ticket and must not error."
  (let ((content "* Project notes
Free-form notes that should never be turned into a ticket.
Nested content, links, whatever the user wants.

* Real Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:END:
Description here.
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (let ((doc (org-tickets--parse-document)))
        ;; Only the real ticket is parsed; the notes heading is ignored.
        (should (= 1 (length (org-tickets--doc-tickets doc))))
        (should (= 1 (length (org-tickets--doc-features doc))))
        (should (= 0 (length (org-tickets--doc-children doc))))
        (let ((ticket (car (org-tickets--doc-tickets doc))))
          (should (string= (org-tickets--ticket-key ticket) "PROJ-100"))
          (should (string= (org-tickets--ticket-summary ticket) "Real Feature")))))))

(ert-deftest org-tickets-test--parse-document-with-feature-type ()
  "Test parsing a document with 'Feature' type (not 'New Feature')."
  (let ((content "* Test Feature
:PROPERTIES:
:JIRA_TYPE: Feature
:JIRA_KEY: PROJ-100
:FIX_VERSION: May2025
:END:
Description here.
** Test Story
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-101
:END:
Story description.
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (let ((doc (org-tickets--parse-document)))
        (should (= 2 (length (org-tickets--doc-tickets doc))))
        (should (= 1 (length (org-tickets--doc-features doc))))
        (should (= 1 (length (org-tickets--doc-children doc))))
        ;; Check feature is recognized
        (let ((feature (car (org-tickets--doc-features doc))))
          (should (string= (org-tickets--ticket-key feature) "PROJ-100"))
          (should (string= (org-tickets--ticket-type feature) "Feature"))
          (should (string= (org-tickets--ticket-summary feature) "Test Feature"))
          (should (string= (org-tickets--ticket-fix-version feature) "May2025")))))))

(ert-deftest org-tickets-test--parse-document-with-both-feature-types ()
  "Test parsing a document with both 'Feature' and 'New Feature' types."
  (let ((content "* Old Style Feature
:PROPERTIES:
:JIRA_TYPE: Feature
:JIRA_KEY: PROJ-100
:END:
Description.
** Story under Feature
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-101
:END:
* New Style Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-200
:END:
Description.
** Story under New Feature
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-201
:END:
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (let ((doc (org-tickets--parse-document)))
        (should (= 4 (length (org-tickets--doc-tickets doc))))
        (should (= 2 (length (org-tickets--doc-features doc))))
        (should (= 2 (length (org-tickets--doc-children doc))))
        ;; Check first feature is recognized as Feature
        (let ((feature-1 (seq-find (lambda (tk)
                                     (string= (org-tickets--ticket-key tk) "PROJ-100"))
                                   (org-tickets--doc-features doc))))
          (should feature-1)
          (should (string= (org-tickets--ticket-type feature-1) "Feature")))
        ;; Check second feature is recognized as New Feature
        (let ((feature-2 (seq-find (lambda (tk)
                                     (string= (org-tickets--ticket-key tk) "PROJ-200"))
                                   (org-tickets--doc-features doc))))
          (should feature-2)
          (should (string= (org-tickets--ticket-type feature-2) "New Feature")))))))

(ert-deftest org-tickets-test--parse-ticket-at-point ()
  "Test parsing a single ticket at point."
  (let ((content "* Test Improvement
:PROPERTIES:
:JIRA_TYPE: Improvement
:JIRA_KEY: PROJ-200
:LABELS: label1,label2
:STORY_POINTS: 5
:END:
Improvement description.
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "Test Improvement" nil t)
      (let ((ticket (org-tickets--parse-ticket-at-point)))
        (should ticket)
        (should (string= (org-tickets--ticket-key ticket) "PROJ-200"))
        (should (string= (org-tickets--ticket-type ticket) "Improvement"))
        (should (string= (org-tickets--ticket-summary ticket) "Test Improvement"))
        (should (string= (org-tickets--ticket-description ticket) "Improvement description."))
        (should (member "label1" (org-tickets--ticket-labels ticket)))
        (should (member "label2" (org-tickets--ticket-labels ticket)))
        (should (= 5 (org-tickets--ticket-story-points ticket)))))))

;;;; Tests for Validation

(ert-deftest org-tickets-test--validate-fix-version ()
  "Test validating Fix Version format."
  (should (org-tickets--validate-fix-version "Aug2026"))
  (should (org-tickets--validate-fix-version "Feb2025"))
  (should (org-tickets--validate-fix-version "May2027"))
  (should (org-tickets--validate-fix-version "Nov2024"))
  (should (null (org-tickets--validate-fix-version "Jan2026")))  ;; Invalid month
  (should (null (org-tickets--validate-fix-version "Aug202")))   ;; Invalid year
  (should (null (org-tickets--validate-fix-version "2026Aug"))) ;; Wrong order
  (should (null (org-tickets--validate-fix-version "")))         ;; Empty
  (should (null (org-tickets--validate-fix-version nil))))      ;; Nil

(ert-deftest org-tickets-test--issue-link-json-format ()
  "Test that issue link format produces valid Jira API payload.
This is a regression test - the payload must have type, inwardIssue, and outwardIssue
at the top level (not nested under 'body'), and the outward field should not have
a double 's' suffix."
  (let* ((from-key "PROJ-12640")
         (to-key "PROJ-12637")
         (link-type "Blocks")
         ;; Build the same structure as org-tickets--create-link
         (link-payload (list (cons 'type (list (cons "name" link-type)))
                             (cons "inwardIssue" (list (cons "key" from-key)))
                             (cons "outwardIssue" (list (cons "key" to-key)))))
         (json-str (json-encode link-payload)))
    ;; Verify the JSON structure - should have type, inwardIssue, outwardIssue at top level
    (should (string-match-p "\"type\":" json-str))
    (should (string-match-p "\"inwardIssue\":" json-str))
    (should (string-match-p "\"outwardIssue\":" json-str))
    ;; Should NOT have 'body' wrapper (was a bug)
    (should-not (string-match-p "\"body\":" json-str))
    ;; Should NOT have 'blockss' typo (was a bug - extra 's')
    (should-not (string-match-p "blockss" json-str))
    ;; Should have correct key values
    (should (string-match-p (regexp-quote from-key) json-str))
    (should (string-match-p (regexp-quote to-key) json-str))))

;;;; Tests for Sprint parsing from Jira

(ert-deftest org-tickets-test--parse-sprint-from-jira ()
  "Test parsing Sprint field from Jira response."
  (let* ((jira-response
          (list (cons "id" 1)
                (cons "key" "TEST-123")
                (cons "fields"
                      (list (cons "summary" "Test")
                            (cons "issuetype" (list (cons "name" "Task")))
                            (cons "customfield_10020" (list (cons "name" "Sprint 1")
                                                            (cons "state" "active")))))))
         (ticket (org-tickets--parse-jira-issue jira-response)))
    (should (string= (org-tickets--ticket-sprint ticket) "Sprint 1"))))

(ert-deftest org-tickets-test--parse-sprint-no-sprint ()
  "Test parsing Jira response with no Sprint field."
  (let* ((jira-response
          (list (cons "id" 1)
                (cons "key" "TEST-124")
                (cons "fields"
                      (list (cons "summary" "Test")
                            (cons "issuetype" (list (cons "name" "Task")))))))
         (ticket (org-tickets--parse-jira-issue jira-response)))
    (should (null (org-tickets--ticket-sprint ticket)))))

(ert-deftest org-tickets-test--parse-sprint-list-of-sprints ()
  "Test parsing Sprint field when it contains a list of multiple sprints.
The code should return the first sprint from the list."
  (let* ((jira-response
          (list (cons "id" 1)
                (cons "key" "TEST-125")
                (cons "fields"
                      (list (cons "summary" "Test")
                            (cons "issuetype" (list (cons "name" "Task")))
                            (cons "customfield_10020"
                                  (list (list (cons "name" "Sprint 1")
                                              (cons "state" "active"))
                                        (list (cons "name" "Sprint 2")
                                              (cons "state" "future"))))))))
         (ticket (org-tickets--parse-jira-issue jira-response)))
    ;; Should return the first sprint, not the full list
    (should (string= (org-tickets--ticket-sprint ticket) "Sprint 1"))))

(ert-deftest org-tickets-test--parse-sprint-dotted-pair ()
  "Test parsing Sprint field when it comes as a dotted pair.
This can happen with certain JSON parsers."
  (let* ((jira-response
          (list (cons "id" 1)
                (cons "key" "TEST-126")
                (cons "fields"
                      (list (cons "summary" "Test")
                            (cons "issuetype" (list (cons "name" "Task")))
                            ;; Dotted pair format: (first . second)
                            (cons "customfield_10020"
                                  (cons (cons "name" "Sprint A")
                                        (cons "state" "active")))))))
         (ticket (org-tickets--parse-jira-issue jira-response)))
    ;; Should handle dotted pair and return the first element's name
    (should (string= (org-tickets--ticket-sprint ticket) "Sprint A"))))

(ert-deftest org-tickets-test--parse-sprint-nil-value ()
  "Test parsing Sprint field when it has a nil value."
  (let* ((jira-response
          (list (cons "id" 1)
                (cons "key" "TEST-127")
                (cons "fields"
                      (list (cons "summary" "Test")
                            (cons "issuetype" (list (cons "name" "Task")))
                            (cons "customfield_10020" nil)))))
         (ticket (org-tickets--parse-jira-issue jira-response)))
    (should (null (org-tickets--ticket-sprint ticket)))))

(ert-deftest org-tickets-test--parse-ticket-with-due-date ()
  "Test parsing a ticket with DUE_DATE property."
  (let ((content "* Test Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:DUE_DATE: 2026-06-15
:END:
Description.
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "Test Feature" nil t)
      (let ((ticket (org-tickets--parse-ticket-at-point)))
        (should ticket)
        (should (string= (org-tickets--ticket-due-date ticket) "2026-06-15"))))))

(ert-deftest org-tickets-test--parse-ticket-without-due-date ()
  "Test parsing a ticket without DUE_DATE returns nil."
  (let ((content "* Test Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:END:
Description.
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "Test Feature" nil t)
      (let ((ticket (org-tickets--parse-ticket-at-point)))
        (should ticket)
        (should (null (org-tickets--ticket-due-date ticket)))))))

(ert-deftest org-tickets-test--parse-ticket-with-empty-due-date ()
  "Test parsing a ticket with empty DUE_DATE returns nil."
  (let ((content "* Test Feature
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-100
:DUE_DATE:
:END:
Description.
"))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "Test Feature" nil t)
      (let ((ticket (org-tickets--parse-ticket-at-point)))
        (should ticket)
        (should (null (org-tickets--ticket-due-date ticket)))))))

(ert-deftest org-tickets-test--field-id-defcustoms-exist ()
  "The Jira custom-field IDs are configurable, not hardcoded."
  (should (equal org-tickets-story-points-field "customfield_10016"))
  (should (equal org-tickets-sprint-field "customfield_10020"))
  (should (get 'org-tickets-story-points-field 'custom-type))
  (should (get 'org-tickets-sprint-field 'custom-type)))

(ert-deftest org-tickets-test--parse-captures-heading-markers ()
  (with-temp-buffer
    (org-mode)
    (insert "* T\n:PROPERTIES:\n:JIRA_TYPE: Story\n:END:\n")
    (let* ((doc (org-tickets--parse-document))
           (m (org-tickets--ticket-marker (car (org-tickets--doc-tickets doc)))))
      (should (markerp m))
      (should (eq (marker-buffer m) (current-buffer)))
      (should (= (marker-position m) 1)))))

(ert-deftest org-tickets-test--find-parent-never-returns-self ()
  "A top-level Feature has no parent — it must not return itself."
  (with-temp-buffer
    (org-mode)
    (insert "* Feature\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: P-1\n:END:\n")
    (goto-char (point-min))
    (should (null (org-tickets--find-parent-ticket-key)))))

(defun org-tickets-test--blocks-of-5-after-resolving (times)
  "Resolve BLOCKED-BY TIMES times in a PROJ-1/PROJ-5 buffer; return PROJ-5 BLOCKS."
  (with-temp-buffer
    (org-mode)
    (insert "* A\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: PROJ-1\n:BLOCKED-BY: PROJ-5\n:END:\n"
            "* B\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: PROJ-5\n:BLOCKS: PROJ-12\n:END:\n")
    (let ((doc (org-tickets--parse-document)))
      (dotimes (_ times)
        (org-tickets--resolve-blocked-by-in-org doc)))
    (goto-char (org-tickets--find-ticket-by-key "PROJ-5"))
    (org-entry-get (point) "BLOCKS")))

(ert-deftest org-tickets-test--blocked-by-adds-key-that-is-a-prefix-of-existing ()
  "A blocker already listing PROJ-12 still gains PROJ-1."
  (should (equal (org-tickets-test--blocks-of-5-after-resolving 1)
                 "PROJ-12,PROJ-1")))

(ert-deftest org-tickets-test--blocked-by-is-idempotent ()
  "Resolving twice does not duplicate the key in BLOCKS."
  (should (equal (org-tickets-test--blocks-of-5-after-resolving 2)
                 "PROJ-12,PROJ-1")))

(ert-deftest org-tickets-test--blocked-by-ignores-whitespace-padding ()
  "A BLOCKS value like \"PROJ-12, PROJ-1\" already contains PROJ-1."
  (with-temp-buffer
    (org-mode)
    (insert "* A\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: PROJ-1\n:BLOCKED-BY: PROJ-5\n:END:\n"
            "* B\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: PROJ-5\n:BLOCKS: PROJ-12, PROJ-1\n:END:\n")
    (org-tickets--resolve-blocked-by-in-org (org-tickets--parse-document))
    (goto-char (org-tickets--find-ticket-by-key "PROJ-5"))
    (should (equal (org-entry-get (point) "BLOCKS") "PROJ-12, PROJ-1"))))

(ert-deftest org-tickets-test--valid-ticket-key-forms ()
  "Project keys may contain digits and underscores but must start with a capital."
  (dolist (key '("PROJ-1" "AB2-12" "A_B-7"))
    (should (org-tickets--valid-ticket-key-p key)))
  (dolist (key '("2AB-1" "ab-1" "PROJ-" "PROJ-1x" "-1" nil))
    (should-not (org-tickets--valid-ticket-key-p key))))

(provide (quote org-tickets-test-parse))
