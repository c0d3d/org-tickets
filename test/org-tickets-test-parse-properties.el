;;; org-tickets-test-parse-properties.el --- Tests for parsing ticket properties  -*- lexical-binding: t; -*-

(require 'ert)
(require 'org)
(require 'org-element)

(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; Tests for Validation

(ert-deftest org-tickets-test--validate-fix-version ()
  "Fix Version must be a configured month followed by a four-digit year."
  (let ((org-tickets-fix-version-months '("Feb" "May" "Aug" "Nov")))
    (should (org-tickets--validate-fix-version "Aug2026"))
    (should (org-tickets--validate-fix-version "Feb2025"))
    (should (org-tickets--validate-fix-version "May2027"))
    (should (org-tickets--validate-fix-version "Nov2024"))
    (should (null (org-tickets--validate-fix-version "Jan2026")))  ;; Invalid month
    (should (null (org-tickets--validate-fix-version "Aug202")))   ;; Invalid year
    (should (null (org-tickets--validate-fix-version "2026Aug"))) ;; Wrong order
    (should (null (org-tickets--validate-fix-version "")))         ;; Empty
    (should (null (org-tickets--validate-fix-version nil)))      ;; Nil
    (should-not (org-tickets--validate-fix-version "Aug2026-draft"))
    (should-not (org-tickets--validate-fix-version "xxAug2026"))))

;;;; Tests for Sprint parsing from Jira

(ert-deftest org-tickets-test--parse-sprint-from-jira ()
  "Test parsing Sprint field from Jira response."
  (let* ((jira-response
          (org-tickets-test--json "{\"id\": 1, \"key\": \"TEST-123\", \"fields\": {\"summary\": \"Test\", \"issuetype\": {\"name\": \"Task\"}, \
    \"customfield_10020\": [{\"name\": \"Sprint 1\", \"state\": \"active\"}]}}"))
         (ticket (org-tickets--parse-jira-issue jira-response)))
    (should (string= (org-tickets--ticket-sprint ticket) "Sprint 1"))))

(ert-deftest org-tickets-test--parse-ticket-sprint-property ()
  "A ticket's SPRINT property is parsed into its sprint slot."
  (with-temp-buffer
    (insert "* Test\n:PROPERTIES:\n:JIRA_KEY: TEST-123\n:JIRA_TYPE: Task\n"
            ":SPRINT: Sprint 1\n:END:\n")
    (org-mode)
    (goto-char (point-min))
    (should (equal (org-tickets--ticket-sprint
                    (org-tickets--parse-ticket-at-point))
                   "Sprint 1"))))

(ert-deftest org-tickets-test--parse-sprint-no-sprint ()
  "Test parsing Jira response with no Sprint field."
  (let* ((jira-response
          (org-tickets-test--json "{\"id\": 1, \"key\": \"TEST-124\", \"fields\": {\"summary\": \"Test\", \"issuetype\": {\"name\": \"Task\"}}}"))
         (ticket (org-tickets--parse-jira-issue jira-response)))
    (should (null (org-tickets--ticket-sprint ticket)))))

(ert-deftest org-tickets-test--parse-sprint-list-of-sprints ()
  "Test parsing Sprint field when it contains a list of multiple sprints.
The code should return the first sprint from the list."
  (let* ((jira-response
          (org-tickets-test--json "{\"id\": 1, \"key\": \"TEST-125\", \"fields\": {\"summary\": \"Test\", \"issuetype\": {\"name\": \"Task\"}, \
    \"customfield_10020\": [{\"name\": \"Sprint 1\", \"state\": \"active\"}, \
    {\"name\": \"Sprint 2\", \"state\": \"future\"}]}}"))
         (ticket (org-tickets--parse-jira-issue jira-response)))
    ;; Should return the first sprint, not the full list
    (should (string= (org-tickets--ticket-sprint ticket) "Sprint 1"))))

(ert-deftest org-tickets-test--parse-sprint-nil-value ()
  "Test parsing Sprint field when it has a nil value."
  (let* ((jira-response
          (org-tickets-test--json "{\"id\": 1, \"key\": \"TEST-127\", \"fields\": {\"summary\": \"Test\", \"issuetype\": {\"name\": \"Task\"}, \
    \"customfield_10020\": null}}"))
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

(ert-deftest org-tickets-test--parse-captures-heading-markers ()
  "Parsing records a marker that leads back to the ticket's heading."
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

(ert-deftest org-tickets-test--find-ticket-by-key-returns-heading ()
  "The lookup lands on the ticket's heading line, not inside its drawer."
  (with-temp-buffer
    (org-mode)
    (insert "* A\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: PROJ-1\n:END:\nBody.\n")
    (goto-char (org-tickets--find-ticket-by-key "PROJ-1"))
    (should (org-at-heading-p))
    (should (equal (org-get-heading t t t t) "A"))))

(ert-deftest org-tickets-test--find-ticket-by-key-ignores-body-mentions ()
  "A key mentioned in another ticket's body does not match that ticket."
  (with-temp-buffer
    (org-mode)
    (insert "* Other\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: PROJ-2\n:END:\nSee PROJ-1\n"
            "* Target\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: PROJ-1\n:END:\n")
    (goto-char (org-tickets--find-ticket-by-key "PROJ-1"))
    (should (org-at-heading-p))
    (should (equal (org-get-heading t t t t) "Target"))))

(ert-deftest org-tickets-test--valid-ticket-key-forms ()
  "Project keys may contain digits and underscores but must start with a capital."
  (dolist (key '("PROJ-1" "AB2-12" "A_B-7"))
    (should (org-tickets--valid-ticket-key-p key)))
  (dolist (key '("2AB-1" "ab-1" "PROJ-" "PROJ-1x" "-1" nil))
    (should-not (org-tickets--valid-ticket-key-p key))))

;;;; Whitespace-only properties

(ert-deftest org-tickets-test--whitespace-only-properties-are-empty ()
  "Whitespace-only PARENT, SPRINT and DUE_DATE parse as absent.
A whitespace-only LABELS or STORY_POINTS still means \"clear\"."
  (with-temp-buffer
    (insert "* Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:LABELS:   \n"
            ":PARENT:  \n:SPRINT:  \n:DUE_DATE:   \n:STORY_POINTS:  \n:END:\n")
    (org-mode)
    (goto-char (point-min))
    (let ((tk (org-tickets--parse-ticket-at-point)))
      (should-not (org-tickets--ticket-labels tk))
      (should-not (org-tickets--ticket-parent tk))
      (should-not (org-tickets--ticket-sprint tk))
      (should-not (org-tickets--ticket-due-date tk))
      (should (org-tickets--ticket-clear-labels tk))
      (should (org-tickets--ticket-clear-story-points tk)))))

(ert-deftest org-tickets-test--csv-properties-trim-entries ()
  "Comma-separated properties drop blank entries and surrounding spaces."
  (with-temp-buffer
    (insert "* Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:LABELS: a , b,\n"
            ":BLOCKS: P-1 , P-2\n:BLOCKED-BY: , \n:END:\n")
    (org-mode)
    (goto-char (point-min))
    (let ((tk (org-tickets--parse-ticket-at-point)))
      (should (equal (org-tickets--ticket-labels tk) '("a" "b")))
      (should (equal (org-tickets--ticket-blocks tk) '("P-1" "P-2")))
      (should-not (org-tickets--ticket-blocked-by tk))
      (should-not (org-tickets--ticket-clear-labels tk)))))

(ert-deftest org-tickets-test--blank-csv-labels-clear ()
  "A LABELS value holding only separators and spaces clears labels."
  (with-temp-buffer
    (insert "* Story\n:PROPERTIES:\n:JIRA_TYPE: Story\n:LABELS: , ,\n:END:\n")
    (org-mode)
    (goto-char (point-min))
    (let ((tk (org-tickets--parse-ticket-at-point)))
      (should-not (org-tickets--ticket-labels tk))
      (should (org-tickets--ticket-clear-labels tk)))))

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

(provide 'org-tickets-test-parse-properties)

;;; org-tickets-test-parse-properties.el ends here
