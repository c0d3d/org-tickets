;;; org-tickets-test-import.el --- Tests for org-tickets ADF import functions  -*- lexical-binding: t; -*-

;; Copyright (C) 2024

;;; Commentary:

;; Tests for importing Jira issues into org:
;; - `org-tickets--parse-jira-issue' and the issue accessors
;; - `org-tickets--issue-to-org'
;; - `org-tickets--update-org-heading-from-ticket'
;; - `org-tickets--pull-remote-changes-for-current-ticket'
;; ADF text import is in org-tickets-test-import-adf.el.

;;; Code:

(require 'ert)
(require 'org)
(require 'org-element)

(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; ensure-list

(ert-deftest org-tickets-test--ensure-list-normalizes-shapes ()
  "Vectors become lists, lists pass through, nil stays nil, atoms are wrapped."
  (should (equal (org-tickets--ensure-list [1 2 3]) '(1 2 3)))
  (should (equal (org-tickets--ensure-list '((a . 1) (b . 2))) '((a . 1) (b . 2))))
  (should (equal (org-tickets--ensure-list nil) nil))
  (should (equal (org-tickets--ensure-list "x") '("x"))))

;;;; Pull Remote / Update Heading Tests

(ert-deftest org-tickets-test--update-org-heading-from-ticket-updates-properties ()
  "Test that org-tickets--update-org-heading-from-ticket updates org properties and headline."
  (let* ((ticket (org-tickets--ticket-create
                  :key "PROJ-42"
                  :type "New Feature"
                  :summary "Updated Feature Title"
                  :description "Updated description body."
                  :fix-version "Aug2026"
                  :labels '("backend" "urgent")
                  :story-points nil
                  :blocks '("PROJ-10")
                  :blocked-by '("PROJ-20")
                  :parent nil
                  :attachments nil
                  :sprint "Sprint 5")))
    (with-temp-buffer
      (insert "* Old Title\n")
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "\\*" nil t)
      (org-tickets--update-org-heading-from-ticket ticket)
      ;; Headline should be updated to the ticket summary
      (should (string= (org-get-heading) "Updated Feature Title"))
      ;; Properties should be set correctly
      (should (string= (org-entry-get (point) "JIRA_KEY") "PROJ-42"))
      (should (string= (org-entry-get (point) "JIRA_TYPE") "New Feature"))
      (should (string= (org-entry-get (point) "FIX_VERSION") "Aug2026"))
      (should (string= (org-entry-get (point) "LABELS") "backend,urgent"))
      (should (string= (org-entry-get (point) "BLOCKS") "PROJ-10"))
      (should (string= (org-entry-get (point) "BLOCKED-BY") "PROJ-20"))
      (should (string= (org-entry-get (point) "SPRINT") "Sprint 5")))))

(ert-deftest org-tickets-test--update-org-heading-from-ticket-story ()
  "Test that org-tickets--update-org-heading-from-ticket handles Story tickets."
  (let* ((ticket (org-tickets--ticket-create
                  :key "PROJ-99"
                  :type "Story"
                  :summary "Implement login"
                  :description "Add SSO support."
                  :fix-version nil
                  :labels '("frontend")
                  :story-points 5
                  :blocks nil
                  :blocked-by nil
                  :parent "PROJ-42"
                  :attachments nil
                  :sprint "Sprint 3")))
    (with-temp-buffer
      (insert "* Old Story Title\n")
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "\\*" nil t)
      (org-tickets--update-org-heading-from-ticket ticket)
      ;; Headline should be updated
      (should (string= (org-get-heading) "Implement login"))
      ;; Story-specific properties
      (should (string= (org-entry-get (point) "JIRA_KEY") "PROJ-99"))
      (should (string= (org-entry-get (point) "JIRA_TYPE") "Story"))
      (should (string= (org-entry-get (point) "PARENT") "PROJ-42"))
      (should (string= (org-entry-get (point) "STORY_POINTS") "5"))
      (should (string= (org-entry-get (point) "LABELS") "frontend"))
      (should (string= (org-entry-get (point) "SPRINT") "Sprint 3"))
      ;; No fix version or blocks for this story
      (should (string= (org-entry-get (point) "FIX_VERSION") ""))
      (should (string= (org-entry-get (point) "BLOCKS") ""))
      (should (string= (org-entry-get (point) "BLOCKED-BY") "")))))

(ert-deftest org-tickets-test--pull-remote-changes-no-key-error ()
  "Pulling a heading that has no JIRA_KEY is a user error naming JIRA_KEY."
  (with-temp-buffer
    (insert "* Heading without JIRA_KEY\n")
    (org-mode)
    (goto-char (point-min))
    (re-search-forward "\\*" nil t)
    (let ((err (should-error (org-tickets--pull-remote-changes-for-current-ticket)
                             :type 'user-error)))
      (should (string-match-p "JIRA_KEY" (error-message-string err))))))

(ert-deftest org-tickets-test--parse-jira-issue-preserves-attachment-id ()
  "Parsed attachments keep their Jira ID, filename, content URL and size."
  (let* ((jira-response
          (org-tickets-test--json
           "{\"id\": \"99999\", \"key\": \"PROJ-200\",
             \"fields\": {\"issuetype\": {\"name\": \"Story\"},
               \"summary\": \"Test ticket\",
               \"attachment\": [
                 {\"id\": \"10001\", \"filename\": \"report.pdf\",
                  \"content\": \"https://example.com/att/10001\", \"size\": 5000},
                 {\"id\": \"10002\", \"filename\": \"image.png\",
                  \"content\": \"https://example.com/att/10002\", \"size\": 3000}]}}"))
         (ticket (org-tickets--parse-jira-issue jira-response))
         (attachments (org-tickets--ticket-attachments ticket)))
    (should (= (length attachments) 2))
    (should (string= (org-tickets--attachment-id (car attachments)) "10001"))
    (should (string= (org-tickets--attachment-filename (car attachments)) "report.pdf"))
    (should (string= (org-tickets--attachment-content-url (car attachments))
                     "https://example.com/att/10001"))
    (should (= (org-tickets--attachment-size (car attachments)) 5000))
    (should (string= (org-tickets--attachment-id (cadr attachments)) "10002"))))

;;;; Media / Attachment Import Tests

(ert-deftest org-tickets-test--parse-jira-issue-resolves-media-inline-to-attachment ()
  "Test that parse-jira-issue resolves mediaInline in description to attachment links."
  (let* ((jira-response
          (org-tickets-test--json "{\"id\": \"99999\", \"key\": \"PROJ-300\", \"fields\": {\"issuetype\": {\"name\": \"Story\"}, \
    \"summary\": \"Media test\", \"description\": {\"type\": \"doc\", \"version\": 1, \
    \"content\": [{\"type\": \"paragraph\", \"content\": [{\"type\": \"text\", \
    \"text\": \"See \"}, {\"type\": \"mediaInline\", \"attrs\": {\"id\": \"media-uuid-1\", \
    \"collection\": \"\", \"type\": \"file\"}}, {\"type\": \"text\", \"text\": \" here\"}]}]}, \
    \"attachment\": [{\"id\": \"media-uuid-1\", \"filename\": \"spec.pdf\", \
    \"content\": \"https://example.com/att/1\", \"size\": 1000}]}}")))
    (let* ((ticket (org-tickets--parse-jira-issue jira-response))
           (desc (org-tickets--ticket-description ticket)))
      (should (string-match-p "\\[\\[attachment:spec\\.pdf\\]\\]" desc)))))

(ert-deftest org-tickets-test--parse-jira-issue-resolves-media-via-media-api-file-id ()
  "Regression: mediaInline UUID should match via mediaApiFileId, not numeric id.
Jira Cloud returns numeric id (e.g. \"10234\") in the attachment metadata but
ADF media nodes reference a UUID.  The mediaApiFileId field bridges the two."
  (let* ((jira-response
          (org-tickets-test--json "{\"id\": \"99999\", \"key\": \"PROJ-400\", \"fields\": {\"issuetype\": {\"name\": \"Story\"}, \
    \"summary\": \"UUID media test\", \"description\": {\"type\": \"doc\", \
    \"version\": 1, \"content\": [{\"type\": \"paragraph\", \"content\": [{\"type\": \"mediaInline\", \
    \"attrs\": {\"id\": \"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\", \"collection\": \"\", \
    \"type\": \"file\"}}]}]}, \"attachment\": [{\"id\": \"10234\", \"filename\": \"design.png\", \
    \"content\": \"https://example.com/att/10234\", \"size\": 5000, \"mediaApiFileId\": \"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\"}]}}")))
    (let* ((ticket (org-tickets--parse-jira-issue jira-response))
           (desc (org-tickets--ticket-description ticket)))
      (should (string-match-p "\\[\\[attachment:design\\.png\\]\\]" desc)))))

(ert-deftest org-tickets-test--parse-jira-issue-media-alt-fallback ()
  "Regression: mediaSingle with alt text should resolve to attachment link.
When neither numeric ID nor mediaApiFileId matches, the alt attribute
(which Jira sets to the filename) should be used as attachment link."
  (let* ((jira-response
          (org-tickets-test--json "{\"id\": \"99999\", \"key\": \"PROJ-401\", \"fields\": {\"issuetype\": {\"name\": \"Story\"}, \
    \"summary\": \"Alt fallback test\", \"description\": {\"type\": \"doc\", \
    \"version\": 1, \"content\": [{\"type\": \"mediaSingle\", \"content\": [{\"type\": \"media\", \
    \"attrs\": {\"id\": \"no-match-uuid\", \"alt\": \"image-20260327-164023.png\", \
    \"type\": \"file\"}}]}]}, \"attachment\": [{\"id\": \"10234\", \"filename\": \"image-20260327-164023.png\", \
    \"content\": \"https://example.com/att/10234\", \"size\": 3000}]}}")))
    (let* ((ticket (org-tickets--parse-jira-issue jira-response))
           (desc (org-tickets--ticket-description ticket)))
      (should (string-match-p "\\[\\[attachment:image-20260327-164023\\.png\\]\\]" desc)))))

(ert-deftest org-tickets-test--update-org-heading-sets-due-date ()
  "Test that org-tickets--update-org-heading-from-ticket sets DUE_DATE property."
  (let* ((ticket (org-tickets--ticket-create
                  :key "PROJ-42"
                  :type "New Feature"
                  :summary "Feature Title"
                  :description "Description."
                  :fix-version nil
                  :labels nil
                  :story-points nil
                  :blocks nil
                  :blocked-by nil
                  :parent nil
                  :attachments nil
                  :sprint nil
                  :due-date "2026-08-01")))
    (with-temp-buffer
      (insert "* Old Title\n")
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "\\*" nil t)
      (org-tickets--update-org-heading-from-ticket ticket)
      (should (string= (org-entry-get (point) "DUE_DATE") "2026-08-01")))))

(ert-deftest org-tickets-test--update-org-heading-clears-due-date ()
  "Test that update-org-heading-from-ticket clears DUE_DATE when nil."
  (let* ((ticket (org-tickets--ticket-create
                  :key "PROJ-42"
                  :type "New Feature"
                  :summary "Feature Title"
                  :description "Description."
                  :fix-version nil
                  :labels nil
                  :story-points nil
                  :blocks nil
                  :blocked-by nil
                  :parent nil
                  :attachments nil
                  :sprint nil
                  :due-date nil)))
    (with-temp-buffer
      (insert "* Old Title
:PROPERTIES:
:DUE_DATE: 2026-01-01
:END:
")
      (org-mode)
      (goto-char (point-min))
      (re-search-forward "\\*" nil t)
      (org-tickets--update-org-heading-from-ticket ticket)
      (let ((val (org-entry-get (point) "DUE_DATE")))
        (should (or (null val) (string= val "")))))))

;;;; Description region on pull

(ert-deftest org-tickets-test--pull-preserves-child-subtrees ()
  "Updating a parent's description must not delete its child headings."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent Feature\n"
            ":PROPERTIES:\n:JIRA_KEY: PROJ-1\n:JIRA_TYPE: Feature\n:END:\n"
            "Old description.\n"
            "** Child Story\n"
            ":PROPERTIES:\n:JIRA_KEY: PROJ-2\n:JIRA_TYPE: Story\n:END:\n"
            "Child body.\n")
    (goto-char (point-min))
    (org-tickets--update-org-heading-from-ticket
     (org-tickets--ticket-create
      :key "PROJ-1" :type "Feature" :summary "Parent Feature"
      :description "New desc from Jira." :labels nil))
    (let ((text (buffer-string)))
      (should (string-match-p "New desc from Jira\\." text))
      (should (string-match-p "^\\*\\* Child Story" text))
      (should (string-match-p "Child body\\." text))
      (should-not (string-match-p "Old description\\." text)))))

(ert-deftest org-tickets-test--pull-correct-region-after-summary-and-property-edits ()
  "Region math must be computed after headline/property edits shift positions."
  (with-temp-buffer
    (org-mode)
    (insert "* Short\n"
            ":PROPERTIES:\n:JIRA_KEY: PROJ-3\n:JIRA_TYPE: Story\n:END:\n"
            "Old body line.\n")
    (goto-char (point-min))
    ;; Much longer summary + properties that did not exist before both
    ;; shift buffer positions after the initial org-element-at-point.
    (org-tickets--update-org-heading-from-ticket
     (org-tickets--ticket-create
      :key "PROJ-3" :type "Story"
      :summary "A considerably longer summary than before"
      :description "Fresh body." :labels '("x" "y")
      :sprint "Sprint 9" :due-date "2026-08-01"))
    (let ((text (buffer-string)))
      (should (string-match-p "Fresh body\\." text))
      (should-not (string-match-p "Old body line\\." text))
      ;; Drawer intact and exactly one properties drawer.
      (should (= 1 (seq-count (lambda (l) (string= l ":PROPERTIES:"))
                              (split-string text "\n")))))))

(ert-deftest org-tickets-test--pull-escapes-headline-like-description-lines ()
  "A description line starting like an org heading must not become one."
  (with-temp-buffer
    (org-mode)
    (insert "* T\n:PROPERTIES:\n:JIRA_KEY: P-9\n:JIRA_TYPE: Story\n:END:\nx\n")
    (goto-char (point-min))
    (org-tickets--update-org-heading-from-ticket
     (org-tickets--ticket-create :key "P-9" :type "Story" :summary "T"
                              :description (org-tickets-test--pull
                                              (org-tickets-test--adf-doc
                                               (org-tickets-test--adf-para
                                                "* looks like a heading")))
                              :labels nil))
    (goto-char (point-min))
    ;; Exactly one headline in the buffer.
    (let ((count 0))
      (while (re-search-forward org-outline-regexp-bol nil t)
        (setq count (1+ count)))
      (should (= count 1)))))

;;;; issue-to-org and parse-jira-issue

(defun org-tickets-test--issue-org-text (&rest slots)
  "Return the org text `org-tickets--issue-to-org' writes for a ticket of SLOTS."
  (with-temp-buffer
    (org-mode)
    (org-tickets--issue-to-org (apply #'org-tickets--ticket-create slots))
    (buffer-string)))

(ert-deftest org-tickets-test--issue-to-org-feature ()
  "A feature imports as a level-1 heading carrying its properties."
  (let ((text (org-tickets-test--issue-org-text
               :key "PROJ-100" :type "Feature" :summary "Test Feature"
               :description "Feature description" :fix-version "v1.0"
               :labels '("label1" "label2"))))
    (should (string-match-p "^\\* Test Feature$" text))
    (should (string-match-p ":JIRA_KEY: +PROJ-100$" text))
    (should (string-match-p ":JIRA_TYPE: +Feature$" text))
    (should (string-match-p ":FIX_VERSION: +v1.0$" text))
    (should (string-match-p ":LABELS: +label1,label2$" text))
    (should (string-match-p "^Feature description$" text))))

(ert-deftest org-tickets-test--issue-to-org-story ()
  "A story imports one level below the top, with links and points as properties."
  (let ((text (org-tickets-test--issue-org-text
               :key "PROJ-200" :type "Story" :summary "Test Story"
               :description "Story description" :labels '("NeedsSizing")
               :story-points 5 :blocks '("PROJ-300") :blocked-by '("PROJ-100")
               :parent "PROJ-100")))
    (should (string-match-p "^\\*\\* Test Story$" text))
    (should (string-match-p ":PARENT: +PROJ-100$" text))
    (should (string-match-p ":STORY_POINTS: +5$" text))
    (should (string-match-p ":BLOCKS: +PROJ-300$" text))
    (should (string-match-p ":BLOCKED-BY: +PROJ-100$" text))))

(ert-deftest org-tickets-test--issue-to-org-keeps-description-paragraphs ()
  "Description paragraphs, and the blank line between them, are preserved."
  (should (string-match-p
           "First paragraph\n\nSecond paragraph"
           (org-tickets-test--issue-org-text
            :key "PROJ-100" :type "Feature" :summary "Test Feature"
            :description "First paragraph\n\nSecond paragraph"))))

(ert-deftest org-tickets-test--issue-to-org-strips-type-prefix-from-summary ()
  "A summary that Jira prefixed with the type name gets a clean heading."
  (should (string-match-p
           "^\\* Change how portalAPI access is given$"
           (org-tickets-test--issue-org-text
            :key "PROJ-100" :type "Improvement"
            :summary "Improvement: Change how portalAPI access is given")))
  (should (string-match-p
           "^\\*\\* User wants to login$"
           (org-tickets-test--issue-org-text
            :key "PROJ-200" :type "Story" :summary "Story: User wants to login"))))

(ert-deftest org-tickets-test--issue-to-org-nil-type ()
  "A ticket without a type still imports under its summary."
  (should (string-match-p
           "^\\* Some summary without type prefix$"
           (org-tickets-test--issue-org-text
            :key "PROJ-300" :summary "Some summary without type prefix"))))

(ert-deftest org-tickets-test--parse-jira-issue-with-json-lists ()
  "Fix version, labels, story points and blocking links are read from the issue."
  (let* ((response
          (org-tickets-test--json
           "{\"id\": \"12345\", \"key\": \"PROJ-1\", \"fields\": {
              \"summary\": \"Test Feature\", \"issuetype\": {\"name\": \"Feature\"},
              \"fixVersions\": [{\"id\": \"1\", \"name\": \"Aug2025\"}],
              \"labels\": [\"label1\", \"label2\"], \"customfield_10016\": 5,
              \"issuelinks\": [
                {\"type\": {\"name\": \"Blocks\", \"outward\": \"blocks\"},
                 \"outwardIssue\": {\"key\": \"PROJ-200\"}},
                {\"type\": {\"name\": \"Blocks\", \"inward\": \"is blocked by\"},
                 \"inwardIssue\": {\"key\": \"PROJ-300\"}}]}}"))
         (ticket (org-tickets--parse-jira-issue response)))
    (should (equal (org-tickets--ticket-key ticket) "PROJ-1"))
    (should (equal (org-tickets--ticket-fix-version ticket) "Aug2025"))
    (should (equal (org-tickets--ticket-labels ticket) '("label1" "label2")))
    (should (= (org-tickets--ticket-story-points ticket) 5))
    (should (equal (org-tickets--ticket-blocks ticket) '("PROJ-200")))
    (should (equal (org-tickets--ticket-blocked-by ticket) '("PROJ-300")))))

(ert-deftest org-tickets-test--parse-jira-issue-reads-due-date ()
  "The issue's duedate becomes the ticket's due date; absent stays nil."
  (let ((with (org-tickets-test--json
               "{\"id\": \"1\", \"key\": \"PROJ-1\", \"fields\": {\"summary\": \"S\",
                 \"issuetype\": {\"name\": \"Feature\"}, \"duedate\": \"2026-06-15\"}}"))
        (without (org-tickets-test--json
                  "{\"id\": \"1\", \"key\": \"PROJ-1\", \"fields\": {\"summary\": \"S\",
                    \"issuetype\": {\"name\": \"Feature\"}}}")))
    (should (equal (org-tickets--ticket-due-date
                    (org-tickets--parse-jira-issue with))
                   "2026-06-15"))
    (should-not (org-tickets--ticket-due-date
                 (org-tickets--parse-jira-issue without)))))

(ert-deftest org-tickets-test--issue-to-org-writes-due-date ()
  "A ticket's due date is written as the DUE_DATE property."
  (should (string-match-p
           ":DUE_DATE: +2026-06-15$"
           (org-tickets-test--issue-org-text
            :key "PROJ-100" :type "Feature" :summary "Test Feature"
            :due-date "2026-06-15"))))

;;;; Parse-failure fallback

(ert-deftest org-tickets-test--adf-parse-failure-yields-nil-description ()
  "A description that cannot be parsed becomes nil, never a raw %S dump."
  (let ((response (org-tickets-test--json
                   "{\"id\":\"1\",\"key\":\"P-1\",\"fields\":{
                      \"issuetype\":{\"name\":\"Story\"},
                      \"summary\":\"S\",
                      \"description\":{\"type\":\"doc\",\"version\":1},
                      \"labels\":[]}}")))
    ;; content missing -> old code error'd then dumped the alist as text.
    (let ((ticket (org-tickets--parse-jira-issue response)))
      (should (null (org-tickets--ticket-description ticket))))))

;;;; Import hardening

(ert-deftest org-tickets-test--issue-to-org-escapes-headline-lines ()
  "Imported descriptions with headline-like lines stay one heading."
  (with-temp-buffer
    (org-mode)
    (org-tickets--issue-to-org
     (org-tickets--ticket-create
      :key "P-1" :type "Story" :summary "S"
      :description (org-tickets-test--pull
                    (org-tickets-test--adf-doc
                     (org-tickets-test--adf-para "* not a heading")))
      :labels nil))
    (goto-char (point-min))
    (let ((count 0))
      (while (re-search-forward org-outline-regexp-bol nil t) (setq count (1+ count)))
      (should (= count 1)))))

(ert-deftest org-tickets-test--parse-jira-issue-uses-field-defcustoms ()
  "Story points and sprint are read from the configurable field IDs."
  (let* ((org-tickets-story-points-field "customfield_99991")
         (org-tickets-sprint-field "customfield_99992")
         (ticket (org-tickets--parse-jira-issue
                  (org-tickets-test--json
                   "{\"id\":\"1\",\"key\":\"P-1\",\"fields\":{
                      \"issuetype\":{\"name\":\"Story\"},
                      \"summary\":\"S\",\"labels\":[],
                      \"customfield_99991\": 5,
                      \"customfield_99992\": [{\"name\":\"Sprint 7\",\"id\":1}]}}"))))
    (should (= (org-tickets--ticket-story-points ticket) 5))
    (should (equal (org-tickets--ticket-sprint ticket) "Sprint 7"))))

(ert-deftest org-tickets-test--issue-accessors ()
  "The issue accessors read due date, fix version, sprint and attachments."
  (let ((org-tickets-sprint-field "customfield_10020")
        (full (org-tickets-test--json
               "{\"key\":\"P-1\",\"fields\":{
                  \"duedate\":\"2026-08-01\",
                  \"fixVersions\":[{\"name\":\"25.3\"},{\"name\":\"25.4\"}],
                  \"customfield_10020\":[{\"id\":1,\"name\":\"Sprint 1\"},{\"id\":2,\"name\":\"Sprint 2\"}],
                  \"attachment\":[{\"id\":\"9\",\"filename\":\"a.png\"}]}}"))
        (empty (org-tickets-test--json
                "{\"key\":\"P-2\",\"fields\":{\"fixVersions\":[],
                  \"customfield_10020\":null,\"attachment\":[]}}")))
    (should (equal (org-tickets--issue-due-date full) "2026-08-01"))
    (should (equal (org-tickets--issue-fix-version full) "25.3"))
    (should (equal (org-tickets--issue-sprint full) "Sprint 1"))
    (should (equal (org-tickets--alist-get "filename"
                                           (car (org-tickets--issue-attachments full)))
                   "a.png"))
    (should-not (org-tickets--issue-due-date empty))
    (should-not (org-tickets--issue-fix-version empty))
    (should-not (org-tickets--issue-sprint empty))
    (should-not (org-tickets--issue-attachments empty))))

(provide 'org-tickets-test-import)

;;; org-tickets-test-import.el ends here
