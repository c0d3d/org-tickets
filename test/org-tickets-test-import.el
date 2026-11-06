;;; org-tickets-test-import.el --- Tests for org-tickets ADF import functions  -*- lexical-binding: t; -*-

;; Copyright (C) 2024

;; Author: Your Name
;; Maintainer: Your Name
;; URL: https://github.com/yourname/org-tickets
;; Version: 0.0.1
;; Package-Requires: ((emacs "27.1") (org "9.0"))

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tests for ADF→org import functions including:
;; - org-tickets--parse-adf-description (structured ADF importer, see
;;   org-tickets-adf-import.el and org-tickets-test-roundtrip.el)
;; - org-tickets--parse-jira-issue
;; - org-tickets--update-org-heading-from-ticket
;; - org-tickets--pull-remote-changes-for-current-ticket

;;; Code:

(require 'ert)
(require 'org)
(require 'org-element)

;; Load the main library
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; ensure-list Tests

(ert-deftest org-tickets-test--ensure-list-proper-list ()
  "Test that ensure-list returns a proper list unchanged (same object)."
  (let ((input (list '((type . "paragraph")) '((type . "text")))))
    (should (eq input (org-tickets--ensure-list input)))))

;;;; ADF Import Tests

(ert-deftest org-tickets-test--adf-import-list-followed-by-paragraph ()
  "Test that paragraph after list stays after list in org output."
  (let* ((adf (org-tickets-test--json "{\"type\": \"doc\", \"content\": [{\"type\": \"bulletList\", \"content\": [{\"type\": \"listItem\", \
    \"content\": [{\"type\": \"paragraph\", \"content\": [{\"type\": \"text\", \
    \"text\": \"List item\"}]}]}]}, {\"type\": \"paragraph\", \"content\": [{\"type\": \"text\", \
    \"text\": \"Text after list\"}]}]}"))
         (result (org-tickets--parse-adf-description adf))
         (list-pos (string-match-p "List item" result))
         (para-pos (string-match-p "Text after list" result)))
    (should (string-match-p "List item" result))
    (should (string-match-p "Text after list" result))
    (should (< list-pos para-pos))))

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
  "Test that org-tickets--pull-remote-changes-for-current-ticket errors without JIRA_KEY."
  (with-temp-buffer
    (insert "* Heading without JIRA_KEY\n")
    (org-mode)
    (goto-char (point-min))
    (re-search-forward "\\*" nil t)
    ;; Should signal an error when JIRA_KEY is missing
    (condition-case err
        (progn
          (org-tickets--pull-remote-changes-for-current-ticket)
          (should nil))  ; should not reach here
      (error
       (should (string-match-p "JIRA_KEY" (error-message-string err)))))))

(ert-deftest org-tickets-test--parse-jira-issue-preserves-attachment-id ()
  "Test that parse-jira-issue preserves the Jira attachment ID."
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
    (should (string= (org-tickets--attachment-id (cadr attachments)) "10002"))))

;;;; Media / Attachment Import Tests

(ert-deftest org-tickets-test--adf-import-media-inline-as-attachment-link ()
  "Test that mediaInline ADF nodes import as [[attachment:filename]] links."
  (let* ((id-map (list (cons "att-uuid-123" "design.pdf")
                       (cons "att-uuid-456" "report.xlsx")))
         (adf (org-tickets-test--json "{\"type\": \"doc\", \"version\": 1, \"content\": [{\"type\": \"paragraph\", \"content\": [{\"type\": \"text\", \
    \"text\": \"See \"}, {\"type\": \"mediaInline\", \"attrs\": {\"id\": \"att-uuid-123\", \
    \"collection\": \"\", \"type\": \"file\"}}, {\"type\": \"text\", \"text\": \" for details\"}]}]}")))
    (let ((result (org-tickets--parse-adf-description adf id-map)))
      (should (string-match-p "\\[\\[attachment:design\\.pdf\\]\\]" result)))))

(ert-deftest org-tickets-test--adf-import-media-single-as-attachment-link ()
  "Test that mediaSingle ADF nodes import as [[attachment:filename]] links when ID is known."
  (let* ((id-map (list (cons "abc123" "screenshot.png")))
         (adf (org-tickets-test--json "{\"type\": \"doc\", \"version\": 1, \"content\": [{\"type\": \"mediaSingle\", \
    \"attrs\": {\"width\": 800, \"layout\": \"align-start\"}, \"content\": [{\"type\": \"media\", \
    \"attrs\": {\"type\": \"file\", \"id\": \"abc123\", \"collection\": \"\"}}]}]}")))
    (let ((result (org-tickets--parse-adf-description adf id-map)))
      (should (string-match-p "\\[\\[attachment:screenshot\\.png\\]\\]" result)))))

(ert-deftest org-tickets-test--adf-import-media-single-unknown-id-fallback ()
  "Test that mediaSingle falls back to [media: id] when attachment ID is unknown."
  (let* ((adf (org-tickets-test--json "{\"type\": \"doc\", \"version\": 1, \"content\": [{\"type\": \"mediaSingle\", \
    \"content\": [{\"type\": \"media\", \"attrs\": {\"type\": \"file\", \"id\": \"unknown-id\", \
    \"collection\": \"\"}}]}]}")))
    (let ((result (org-tickets--parse-adf-description adf)))
      (should (string-match-p "\\[media: unknown-id\\]" result)))))

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

(ert-deftest org-tickets-test--adf-convert-attachment-link-with-symbol-keys ()
  "Regression: attachment link conversion must handle symbol-keyed alists.
The Jira API response uses json-object-type 'alist which produces symbol keys,
but the converter was using string keys with assoc, silently failing."
  (let ((org-tickets--adf-attachments
         (org-tickets-test--json "[{\"id\": \"10234\", \"filename\": \"spec.pdf\", \"mediaApiFileId\": \"sym-uuid-1\"}]")))
    (with-temp-buffer
      (insert "See [[attachment:spec.pdf]]\n")
      (org-mode)
      (let* ((ast (org-element-parse-buffer))
             (adf-content (org-tickets--convert-to-adf-content ast)))
        ;; Should have produced a mediaInline node, not a plain text fallback
        (let* ((para (car adf-content))
               (content (cdr (assoc "content" para)))
               (media-node (seq-find
                            (lambda (node)
                              (equal (cdr (assoc "type" node)) "mediaInline"))
                            content)))
          (should media-node)
          (should (string= (cdr (assoc "id" (cdr (assoc "attrs" media-node))))
                           "sym-uuid-1")))))))

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

;;;; Task A1: description-region correctness

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

(ert-deftest org-tickets-test--pull-nil-description-keeps-structure ()
  "Clearing the description must not fuse :END: with the next heading."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n:PROPERTIES:\n:JIRA_KEY: P-1\n:JIRA_TYPE: Feature\n:END:\n"
            "Body.\n** Child\n:PROPERTIES:\n:JIRA_KEY: P-2\n:JIRA_TYPE: Story\n:END:\n")
    (goto-char (point-min))
    (org-tickets--update-org-heading-from-ticket
     (org-tickets--ticket-create :key "P-1" :type "Feature" :summary "Parent"
                              :description nil :labels nil))
    (should (string-match-p "^\\*\\* Child" (buffer-string)))
    (should (string-match-p ":END:\n" (buffer-string)))))

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

(ert-deftest org-tickets-test--pull-replaces-description-subheadings ()
  "Pulling replaces old description headings but keeps child tickets."
  (with-temp-buffer
    (org-mode)
    (insert "* F\n:PROPERTIES:\n:JIRA_KEY: P-1\n:JIRA_TYPE: Feature\n:END:\n"
            "Old.\n*** Old heading\nOld body.\n"
            "** Child\n:PROPERTIES:\n:JIRA_KEY: P-2\n:JIRA_TYPE: Story\n:END:\n")
    (goto-char (point-min))
    (org-tickets--update-org-heading-from-ticket
     (org-tickets--ticket-create :key "P-1" :type "Feature" :summary "F"
                              :description "*** New heading\n\nNew." :labels nil))
    (let ((text (buffer-string)))
      (should (string-match-p "^\\*\\*\\* New heading$" text))
      (should-not (string-match-p "Old" text))
      (should (string-match-p "^\\*\\* Child$" text)))))

;;;; Task A2: new inline layer

(ert-deftest org-tickets-test--adf-import-hardbreak-in-paragraph ()
  "hardBreak inside a top-level paragraph becomes a newline, not nothing."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[
                      {\"type\":\"paragraph\",\"content\":[
                        {\"type\":\"text\",\"text\":\"line1\"},
                        {\"type\":\"hardBreak\"},
                        {\"type\":\"text\",\"text\":\"line2\"}]}]}"))
                 "line1\nline2")))

(ert-deftest org-tickets-test--adf-import-marks ()
  "strong/em/code/underline/strike/link marks map to org markup."
  (let ((doc "{\"type\":\"doc\",\"version\":1,\"content\":[
               {\"type\":\"paragraph\",\"content\":[
                 {\"type\":\"text\",\"text\":\"b\",\"marks\":[{\"type\":\"strong\"}]},
                 {\"type\":\"text\",\"text\":\"i\",\"marks\":[{\"type\":\"em\"}]},
                 {\"type\":\"text\",\"text\":\"c\",\"marks\":[{\"type\":\"code\"}]},
                 {\"type\":\"text\",\"text\":\"s\",\"marks\":[{\"type\":\"strike\"}]},
                 {\"type\":\"text\",\"text\":\"l\",\"marks\":[{\"type\":\"link\",\"attrs\":{\"href\":\"https://x.test\"}}]}]}]}"))
    (should (equal (org-tickets--parse-adf-description (org-tickets-test--json doc))
                   "*b*/i/~c~+s+[[https://x.test][l]]"))))

;;;; Task A3: block layer

(ert-deftest org-tickets-test--adf-import-blockquote ()
  "Blockquotes import as org quote blocks (round-trippable)."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[
                      {\"type\":\"blockquote\",\"content\":[
                        {\"type\":\"paragraph\",\"content\":[
                          {\"type\":\"text\",\"text\":\"quoted text\"}]}]}]}"))
                 "#+BEGIN_QUOTE\nquoted text\n#+END_QUOTE")))

(ert-deftest org-tickets-test--adf-import-rule ()
  "Rules import as org horizontal rules."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[{\"type\":\"rule\"}]}"))
                 "-----")))

(ert-deftest org-tickets-test--adf-import-heading-is-org-headline ()
  "Headings import as org headlines two levels deeper (h1 is ***), and
push back as the same heading."
  (let ((result (org-tickets--parse-adf-description
                 (org-tickets-test--json
                  "{\"type\":\"doc\",\"version\":1,\"content\":[
                     {\"type\":\"heading\",\"attrs\":{\"level\":2},
                      \"content\":[{\"type\":\"text\",\"text\":\"Section\"}]}]}"))))
    (should (equal result "**** Section"))))

(ert-deftest org-tickets-test--adf-import-code-block ()
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[
                      {\"type\":\"codeBlock\",\"attrs\":{\"language\":\"python\"},
                       \"content\":[{\"type\":\"text\",\"text\":\"x = 1\\ny = 2\"}]}]}"))
                 "#+BEGIN_SRC python\nx = 1\ny = 2\n#+END_SRC")))

(ert-deftest org-tickets-test--adf-import-table ()
  "Tables import as org tables; a leading all-tableHeader row imports
with an org rule row after it (so it re-exports as a header table),
and | in content is escaped."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[
                      {\"type\":\"table\",\"content\":[
                        {\"type\":\"tableRow\",\"content\":[
                          {\"type\":\"tableHeader\",\"content\":[
                            {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"H1\"}]}]},
                          {\"type\":\"tableHeader\",\"content\":[
                            {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"H2\"}]}]}]},
                        {\"type\":\"tableRow\",\"content\":[
                          {\"type\":\"tableCell\",\"content\":[
                            {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"a\"}]}]},
                          {\"type\":\"tableCell\",\"content\":[
                            {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"b|c\"}]}]}]}]}]}"))
                 "| H1 | H2 |\n|---+---|\n| a | b\\vert{}c |")))

(ert-deftest org-tickets-test--adf-import-doc-blank-line-separation ()
  "Top-level blocks are separated by exactly one blank line."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[
                      {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"one\"}]},
                      {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"two\"}]}]}"))
                 "one\n\ntwo")))

;;;; Task A4: list layout with string indents

(ert-deftest org-tickets-test--adf-import-nested-bullet-list ()
  "Nested bullets get their own indented lines, not jammed inline."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[
                      {\"type\":\"bulletList\",\"content\":[
                        {\"type\":\"listItem\",\"content\":[
                          {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"first\"}]},
                          {\"type\":\"bulletList\",\"content\":[
                            {\"type\":\"listItem\",\"content\":[
                              {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"nested\"}]}]}]}]}]}]}"))
                 "- first\n  - nested")))

(ert-deftest org-tickets-test--adf-import-nested-list-under-ordered-item ()
  "Ordered items indent children past their marker width (\"1. \" = 3 cols)."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[
                      {\"type\":\"orderedList\",\"content\":[
                        {\"type\":\"listItem\",\"content\":[
                          {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"first\"}]},
                          {\"type\":\"bulletList\",\"content\":[
                            {\"type\":\"listItem\",\"content\":[
                              {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"nested\"}]}]}]}]}]}]}"))
                 "1. first\n   - nested")))

(ert-deftest org-tickets-test--adf-import-multiline-list-item ()
  "hardBreak continuation lines inside an item align under the item text."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[
                      {\"type\":\"bulletList\",\"content\":[
                        {\"type\":\"listItem\",\"content\":[
                          {\"type\":\"paragraph\",\"content\":[
                            {\"type\":\"text\",\"text\":\"a\"},
                            {\"type\":\"hardBreak\"},
                            {\"type\":\"text\",\"text\":\"b\"}]}]}]}]}"))
                 "- a\n  b")))

(ert-deftest org-tickets-test--adf-import-ordered-numbering ()
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[
                      {\"type\":\"orderedList\",\"content\":[
                        {\"type\":\"listItem\",\"content\":[
                          {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"one\"}]}]},
                        {\"type\":\"listItem\",\"content\":[
                          {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"two\"}]}]}]}]}"))
                 "1. one\n2. two")))

;;;; Task A5: parse-failure fallback

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

;;;; Task A6: import-side hardening

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
