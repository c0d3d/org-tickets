;;; org-tickets-test-parse.el --- Tests for org-tickets parsing functions  -*- lexical-binding: t; -*-

(require 'ert)
(require 'org)
(require 'org-element)

;; Load the main library
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; Description extraction tests

(ert-deftest org-tickets-test--description-simple ()
  "A plain description is the text under the heading."
  (let ((content "* Heading
Some description text."))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "^\*" nil t)
      (let ((desc (org-tickets--get-ticket-description)))
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
      (let ((desc (org-tickets--get-ticket-description)))
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
    (should (string= (org-tickets--get-ticket-description)
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
      (let ((desc (org-tickets--get-ticket-description)))
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
      (let ((desc (org-tickets--get-ticket-description)))
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

;;;; Description boundaries

(ert-deftest org-tickets-test--description-nil-for-drawer-without-body ()
  "A ticket with a properties drawer and no body has no description."
  (should-not (org-tickets-test--description-of
               (org-tickets-test--ticket-text "*" "Story" "Bare" "" "P-1")
               "Bare")))

(ert-deftest org-tickets-test--description-without-drawer ()
  "A heading without a properties drawer yields its whole body."
  (with-temp-buffer
    (org-mode)
    (insert "* No drawer\nJust the body.\n** Sub\nMore.\n")
    (goto-char (point-min))
    (should (equal (org-tickets--get-ticket-description)
                   "Just the body.\n** Sub\nMore."))))

;;;; Phase batches

(ert-deftest org-tickets-test--non-feature-batch-holds-other-types ()
  "A ticket of a type that is neither a parent nor a Story (e.g. Bug)
lands in the non-feature batch, so it still reaches Jira."
  (with-temp-buffer
    (org-mode)
    (insert (org-tickets-test--ticket-text "*" "Feature" "F" "")
            (org-tickets-test--ticket-text "**" "Bug" "B" "")
            (org-tickets-test--ticket-text "**" "Story" "S" ""))
    (should (equal (mapcar #'org-tickets--ticket-summary
                           (org-tickets--doc-non-feature-tickets
                            (org-tickets--parse-document)))
                   '("B" "S")))))

;;;; Issue types keyword

(defun org-tickets-test--issue-types-from (value)
  "Return the issue types loaded from a #+JIRA_ISSUE_TYPES keyword of VALUE."
  (with-temp-buffer
    (org-mode)
    (insert "#+JIRA_ISSUE_TYPES: " value "\n* H\n")
    (org-tickets--load-issue-types)))

(ert-deftest org-tickets-test--issue-types-drop-malformed-pairs ()
  "Pairs without a NAME=ID shape are dropped, and the rest still save."
  (let ((types (org-tickets-test--issue-types-from "Story=1,garbage, =3,Bug=2")))
    (should (equal types '(("Story" . "1") ("Bug" . "2"))))
    (should (equal (org-tickets--format-issue-types types)
                   "#+JIRA_ISSUE_TYPES: Story=1,Bug=2"))))

(ert-deftest org-tickets-test--issue-type-pair-splits-at-last-equals ()
  "In A=B=C the id is after the last `=': ids are numeric, names are not."
  (should (equal (org-tickets-test--issue-types-from "A=B=C")
                 '(("A=B" . "C")))))

(ert-deftest org-tickets-test--parse-document-error-releases-markers ()
  "A ticket that fails to parse frees the markers of the tickets before it."
  (with-temp-buffer
    (insert "* F\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:END:\n"
            "** S\n:PROPERTIES:\n:JIRA_TYPE: Story\n:END:\n"
            "*** Too deep\n:PROPERTIES:\n:JIRA_TYPE: Story\n:END:\n")
    (org-mode)
    (let ((markers nil))
      (org-tickets-test--recording-markers markers
        (should-error (org-tickets--parse-document) :type 'user-error))
      (should (= (length markers) 2))
      (should-not (seq-some #'marker-buffer markers)))))

(provide 'org-tickets-test-parse)

;;; org-tickets-test-parse.el ends here
