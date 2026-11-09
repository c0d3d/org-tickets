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

(provide 'org-tickets-test-parse)

;;; org-tickets-test-parse.el ends here
