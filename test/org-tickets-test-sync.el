;;; org-tickets-test-sync.el --- Tests for org-tickets sync and import functions  -*- lexical-binding: t; -*-

(require 'ert)
(require 'org)
(require 'org-element)

;; Load the main library
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; API Response Tests

(ert-deftest org-tickets-test--api-response-key-extraction ()
  "Test that Jira API response key extraction uses string keys.
This is a regression test - json-read-from-string returns alists with string keys,
not symbols. Using (alist-get 'key result) would fail because it looks for
the symbol 'key, but the alist has the string \"key\"."
  ;; Simulate what org-tickets--create-ticket returns - an alist with string keys
  (let ((api-response (list (cons "key" "PROJ-123") (cons "id" "12345"))))
    ;; Wrong way - using symbol 'key (this would return nil)
    (should (null (alist-get 'key api-response)))
    ;; Correct way - using string "key"
    (should (string= (cdr (assoc "key" api-response)) "PROJ-123"))))

(ert-deftest org-tickets-test--api-response-key-extraction-symbol-key ()
  "Test that Jira API response key extraction handles symbol keys.
This is a regression test - json-read-from-string may return alists with
symbol keys instead of string keys, depending on Emacs version/settings.
The code should handle both string and symbol keys using a fallback."
  ;; Simulate JSON parser returning symbol keys (like 'key instead of "key")
  (let ((api-response (list (cons (intern "key") "PROJ-12751")
                            (cons (intern "id") "108903"))))
    ;; String key lookup fails on symbol-key alist (this is expected)
    (should (null (cdr (assoc "key" api-response))))
    ;; Symbol key lookup works
    (should (string= (cdr (assoc (intern "key") api-response)) "PROJ-12751"))
    ;; The fallback pattern used in the code handles both cases
    (should (string= (or (cdr (assoc "key" api-response))
                         (cdr (assoc (intern-soft "key") api-response)))
                     "PROJ-12751"))))

(ert-deftest org-tickets-test--api-response-parsing ()
  "Test that API response body is properly parsed and returned.
This is a regression test - the org-tickets--api-request function was not
returning the parsed JSON body for successful responses (201 Created, etc).
It was returning nil even when the response had a valid JSON body."
  ;; Simulate a successful HTTP response with a JSON body
  (let ((response-body "{\"key\":\"PROJ-123\",\"id\":\"12345\",\"summary\":\"Test ticket\"}"))
    ;; Parse the body the same way org-tickets--api-request does
    (let ((json-object-type 'alist))
      (let ((parsed (json-read-from-string response-body)))
        ;; Should get a result (not nil)
        (should parsed)
        ;; Body is not empty or whitespace - should be processed
        (should-not (string-match-p "^[[:space:]]*$" response-body))
        (should (> (length response-body) 0))
        ;; The parsed result should contain the key - access via elt since it's a vector of alist
        (let ((key-entry (elt parsed 0)))
          (should (string= (cdr key-entry) "PROJ-123")))))))

(ert-deftest org-tickets-test--api-response-body-with-leading-newline ()
  "Test that API response body with leading newline is properly parsed.
This is a regression test - the HTTP response body may start with a newline
character after the headers, which was causing the body to be incorrectly
treated as empty/whitespace and returning nil instead of the parsed JSON."
  ;; Simulate a response body that starts with a newline (like after HTTP headers)
  (let ((response-body "\n{\"key\":\"PROJ-12750\",\"id\":\"108902\"}"))
    ;; Trim the body like org-tickets--api-request does
    (let ((trimmed-body (string-trim response-body)))
      ;; Should not be empty after trimming
      (should (> (length trimmed-body) 0))
      (should-not (string-match-p "^[[:space:]]*$" trimmed-body))
      ;; Should parse correctly
      (let ((json-object-type 'alist))
        (let ((parsed (json-read-from-string trimmed-body)))
          (should parsed)
          ;; Access the key - parsed is a vector containing alist entries
          (let ((key-entry (elt parsed 0)))
            (should (string= (cdr key-entry) "PROJ-12750"))))))))

;;;; Tests for Org Property Helpers

(ert-deftest org-tickets-test--set-org-ticket-key ()
  "Test setting JIRA_KEY property in org via the ticket's marker."
  (with-temp-buffer
    (org-mode)
    (insert "* Test\n:PROPERTIES:\n:JIRA_TYPE: Story\n:END:\n")
    (let ((ticket (car (org-tickets--doc-tickets (org-tickets--parse-document)))))
      (org-tickets--set-org-ticket-key ticket "PROJ-999")
      (goto-char (point-min))
      (should (string= (org-entry-get (point) "JIRA_KEY") "PROJ-999")))))

(ert-deftest org-tickets-test--set-org-ticket-key-targets-exact-heading ()
  "Keys go to the parsed heading itself — never to another entry whose
description merely contains the summary text, and never clobbering an
existing JIRA_KEY (both happened with the old summary-text search)."
  (with-temp-buffer
    (org-mode)
    (insert "* Some other feature\n"
            ":PROPERTIES:\n:JIRA_TYPE: Feature\n:JIRA_KEY: PROJ-9\n:END:\n"
            "We should Fix login here.\n"
            "* Fix login\n"
            ":PROPERTIES:\n:JIRA_TYPE: Feature\n:END:\n")
    (let* ((doc (org-tickets--parse-document))
           (new-ticket (seq-find (lambda (tk) (null (org-tickets--ticket-key tk)))
                                 (org-tickets--doc-tickets doc))))
      (should new-ticket)
      (org-tickets--set-org-ticket-key new-ticket "PROJ-100")
      (goto-char (point-min))
      (search-forward "* Some other feature")
      (should (equal (org-entry-get (point) "JIRA_KEY") "PROJ-9"))
      (goto-char (point-min))
      (search-forward "* Fix login")
      (should (equal (org-entry-get (point) "JIRA_KEY") "PROJ-100")))))

(ert-deftest org-tickets-test--set-org-ticket-key-survives-earlier-insertions ()
  "Markers ride along when text above the heading grows during sync."
  (with-temp-buffer
    (org-mode)
    (insert "* First\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:END:\n"
            "* Second\n:PROPERTIES:\n:JIRA_TYPE: Feature\n:END:\n")
    (let* ((doc (org-tickets--parse-document))
           (second (seq-find (lambda (tk)
                               (string= (org-tickets--ticket-summary tk) "Second"))
                             (org-tickets--doc-tickets doc))))
      ;; Simulate phase-2 buffer growth above the target heading.
      (goto-char (point-min))
      (forward-line 1)
      (insert ":ID: 123e4567-e89b-12d3-a456-426614174000\n")
      (org-tickets--set-org-ticket-key second "PROJ-2")
      (goto-char (point-min))
      (search-forward "* Second")
      (should (equal (org-entry-get (point) "JIRA_KEY") "PROJ-2")))))

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

;;;; Import Tests

(ert-deftest org-tickets-test--issue-to-org-feature ()
  "Test converting a feature ticket to org heading."
  (let ((ticket (org-tickets--ticket-create
                 :key "PROJ-100"
                 :type "Feature"
                 :summary "Test Feature"
                 :description "Feature description"
                 :fix-version "v1.0"
                 :labels '("label1" "label2")
                 :story-points nil
                 :blocks nil
                 :blocked-by nil
                 :parent nil
                 :attachments nil)))
    (with-temp-buffer
      (org-mode)
      (org-tickets--issue-to-org ticket)
      (goto-char (point-min))
      ;; Move point to the heading line itself
      (re-search-forward "^\\* Test Feature" nil t)
      (goto-char (match-beginning 0))
      (should (string= (org-entry-get (point) "JIRA_KEY") "PROJ-100"))
      (should (string= (org-entry-get (point) "JIRA_TYPE") "Feature"))
      (should (string= (org-entry-get (point) "FIX_VERSION") "v1.0"))
      (should (string= (org-entry-get (point) "LABELS") "label1,label2")))))

(ert-deftest org-tickets-test--issue-to-org-story ()
  "Test converting a story ticket to org heading."
  (let ((ticket (org-tickets--ticket-create
                 :key "PROJ-200"
                 :type "Story"
                 :summary "Test Story"
                 :description "Story description"
                 :fix-version "v1.0"
                 :labels '("NeedsSizing")
                 :story-points 5
                 :blocks '("PROJ-300")
                 :blocked-by '("PROJ-100")
                 :parent "PROJ-100"
                 :attachments nil)))
    (with-temp-buffer
      (org-mode)
      (org-tickets--issue-to-org ticket)
      (goto-char (point-min))
      ;; Move point to the heading line itself
      (re-search-forward "^\\*\\* Test Story" nil t)
      (goto-char (match-beginning 0))
      (should (string= (org-entry-get (point) "JIRA_KEY") "PROJ-200"))
      (should (string= (org-entry-get (point) "PARENT") "PROJ-100"))
      (should (string= (org-entry-get (point) "STORY_POINTS") "5"))
      (should (string= (org-entry-get (point) "BLOCKS") "PROJ-300"))
      (should (string= (org-entry-get (point) "BLOCKED-BY") "PROJ-100")))))

;;;; Regression tests for JSON parsing

(ert-deftest org-tickets-test--parse-jira-issue-with-json-lists ()
  "Test parsing Jira issue when JSON arrays are parsed as lists.
This tests that fixVersions, labels, and issuelinks are handled correctly
when JSON array-type is set to \\='list."
  (let* ((jira-response
          (list (cons "id" "12345")
                (cons "key" "PROJ-11437")
                (cons "fields"
                      (list (cons "summary" "Test Feature")
                            (cons "issuetype" (list (cons "name" "Feature")))
                            (cons "fixVersions" (list (list (cons "id" "11653")
                                                            (cons "name" "Aug2025")
                                                            (cons "description" "")
                                                            (cons "archived" nil)
                                                            (cons "released" nil))))
                            (cons "labels" (list "label1" "label2"))
                            (cons "customfield_10016" 5)
                            (cons "issuelinks" (list (list (cons "type" (list (cons "name" "Blocks")
                                                                              (cons "outward" "blocks")))
                                                           (cons "outwardIssue" (list (cons "key" "PROJ-200"))))
                                                     (list (cons "type" (list (cons "name" "Blocks")
                                                                              (cons "inward" "is blocked by")))
                                                           (cons "inwardIssue" (list (cons "key" "PROJ-300")))))))))))
    (let ((ticket (org-tickets--parse-jira-issue jira-response)))
      (should (string= (org-tickets--ticket-key ticket) "PROJ-11437"))
      (should (string= (org-tickets--ticket-fix-version ticket) "Aug2025"))
      (should (equal (org-tickets--ticket-labels ticket) '("label1" "label2")))
      (should (= (org-tickets--ticket-story-points ticket) 5))
      (should (member "PROJ-200" (org-tickets--ticket-blocks ticket)))
      (should (member "PROJ-300" (org-tickets--ticket-blocked-by ticket))))))

(ert-deftest org-tickets-test--parse-jira-issue-with-json-vectors ()
  "Test parsing Jira issue when JSON arrays are parsed as vectors.
This tests that fixVersions, labels, and issuelinks are handled correctly
when JSON array-type is set to 'vector (the default in some Emacs versions)."
  (let* ((jira-response
          (list (cons "id" "12345")
                (cons "key" "PROJ-11437")
                (cons "fields"
                      (list (cons "summary" "Test Feature")
                            (cons "issuetype" (list (cons "name" "Feature")))
                            (cons "fixVersions" (vector (list (cons "id" "11653")
                                                              (cons "name" "Aug2025")
                                                              (cons "description" "")
                                                              (cons "archived" nil)
                                                              (cons "released" nil))))
                            (cons "labels" (vector "label1" "label2"))
                            (cons "customfield_10016" 5)
                            (cons "issuelinks" (vector (list (cons "type" (list (cons "name" "Blocks")
                                                                                (cons "outward" "blocks")))
                                                             (cons "outwardIssue" (list (cons "key" "PROJ-200"))))
                                                       (list (cons "type" (list (cons "name" "Blocks")
                                                                                (cons "inward" "is blocked by")))
                                                             (cons "inwardIssue" (list (cons "key" "PROJ-300")))))))))))
    (let ((ticket (org-tickets--parse-jira-issue jira-response)))
      (should (string= (org-tickets--ticket-key ticket) "PROJ-11437"))
      (should (string= (org-tickets--ticket-fix-version ticket) "Aug2025"))
      (should (equal (org-tickets--ticket-labels ticket) '("label1" "label2")))
      (should (= (org-tickets--ticket-story-points ticket) 5))
      (should (member "PROJ-200" (org-tickets--ticket-blocks ticket)))
      (should (member "PROJ-300" (org-tickets--ticket-blocked-by ticket))))))

;;;; Regression tests for ADF table parsing

;; NOTE: org-tickets-test--parse-adf-table and
;; org-tickets-test--parse-adf-paragraph-newlines were removed here.  Both
;; used hand-built cons-shorthand ADF fixtures (e.g. (cons "text" "...")
;; without a "type" field) that only the deleted old parser tolerated,
;; and both are now covered by proper-fixture tests against the public
;; `org-tickets--parse-adf-description' entry point in
;; org-tickets-test-import.el: table/tableHeader/tableCell coverage lives
;; in `org-tickets-test--adf-import-table', and paragraph-to-paragraph
;; double-newline separation lives in
;; `org-tickets-test--adf-import-doc-blank-line-separation'.

(ert-deftest org-tickets-test--parse-adf-marks-code ()
  "Test parsing ADF text with code marks."
  (let ((adf
         (list (cons "content"
                     (list
                      (list (cons "type" "paragraph")
                            (cons "content"
                                  (list (list (cons "type" "text")
                                              (cons "text" "code example")
                                              (cons "marks" (list (list (cons "type" "code")))))))))))))
    (let ((result (org-tickets--parse-adf-description adf)))
      (should (string-match-p "~code example~" result)))))

(ert-deftest org-tickets-test--parse-adf-marks-strong ()
  "Test parsing ADF text with strong marks."
  (let ((adf
         (list (cons "content"
                     (list
                      (list (cons "type" "paragraph")
                            (cons "content"
                                  (list (list (cons "type" "text")
                                              (cons "text" "bold text")
                                              (cons "marks" (list (list (cons "type" "strong")))))))))))))
    (let ((result (org-tickets--parse-adf-description adf)))
      (should (string-match-p "\\*bold text\\*" result)))))

(ert-deftest org-tickets-test--parse-adf-marks-emphasis ()
  "Test parsing ADF text with emphasis marks."
  (let ((adf
         (list (cons "content"
                     (list
                      (list (cons "type" "paragraph")
                            (cons "content"
                                  (list (list (cons "type" "text")
                                              (cons "text" "italic text")
                                              (cons "marks" (list (list (cons "type" "emphasis")))))))))))))
    (let ((result (org-tickets--parse-adf-description adf)))
      (should (string-match-p "/italic text/" result)))))

(ert-deftest org-tickets-test--parse-adf-marks-em ()
  "Test parsing ADF text with 'em' mark type (used in export).
This tests round-trip: export uses 'em', import should also handle 'em'."
  (let ((adf
         (list (cons "content"
                     (list
                      (list (cons "type" "paragraph")
                            (cons "content"
                                  (list (list (cons "type" "text")
                                              (cons "text" "italic text")
                                              (cons "marks" (list (list (cons "type" "em")))))))))))))
    (let ((result (org-tickets--parse-adf-description adf)))
      (should (string-match-p "/italic text/" result)))))

(ert-deftest org-tickets-test--parse-adf-marks-link ()
  "Test parsing ADF text with link marks - should produce proper org links."
  (let ((adf
         (list (cons "content"
                     (list
                      (list (cons "type" "paragraph")
                            (cons "content"
                                  (list (list (cons "type" "text")
                                              (cons "text" "click here")
                                              (cons "marks" (list (list (cons "type" "link")
                                                                        (cons "attrs" (list (cons "href" "https://example.com")))))))))))))))
    (let ((result (org-tickets--parse-adf-description adf)))
      (should (string-match-p "\\[\\[https://example\\.com\\]\\[click here\\]\\]" result)))))

(ert-deftest org-tickets-test--parse-adf-media-single ()
  "Test that mediaSingle with alt falls back to attachment link."
  (let ((adf
         (list (cons "content"
                     (list
                      (list (cons "type" "mediaSingle")
                            (cons "attrs" (list (cons "width" 800) (cons "layout" "align-start")))
                            (cons "content"
                                  (list (list (cons "type" "media")
                                              (cons "attrs" (list (cons "type" "file")
                                                                  (cons "id" "abc123")
                                                                  (cons "alt" "screenshot.png")
                                                                  (cons "collection" ""))))))))))))
    (let ((result (org-tickets--parse-adf-description adf)))
      (should (string-match-p "\\[\\[attachment:screenshot\\.png\\]\\]" result)))))

(ert-deftest org-tickets-test--parse-adf-table-header ()
  "Test parsing ADF table with tableHeader elements."
  (let* ((text1 (list (cons "type" "text") (cons "text" "Header 1")))
         (text2 (list (cons "type" "text") (cons "text" "Header 2")))
         (text3 (list (cons "type" "text") (cons "text" "Cell 1")))
         (text4 (list (cons "type" "text") (cons "text" "Cell 2")))
         (para1 (list (cons "type" "paragraph") (cons "content" (list text1))))
         (para2 (list (cons "type" "paragraph") (cons "content" (list text2))))
         (para3 (list (cons "type" "paragraph") (cons "content" (list text3))))
         (para4 (list (cons "type" "paragraph") (cons "content" (list text4))))
         (header1 (list (cons "type" "tableHeader") (cons "content" (list para1))))
         (header2 (list (cons "type" "tableHeader") (cons "content" (list para2))))
         (cell1 (list (cons "type" "tableCell") (cons "content" (list para3))))
         (cell2 (list (cons "type" "tableCell") (cons "content" (list para4))))
         (row1 (list (cons "type" "tableRow") (cons "content" (list header1 header2))))
         (row2 (list (cons "type" "tableRow") (cons "content" (list cell1 cell2))))
         (table (list (cons "type" "table") (cons "content" (list row1 row2))))
         (adf (list (cons "content" (list table)))))
    (let ((result (org-tickets--parse-adf-description adf)))
      (should (string-match-p "Header 1" result))
      (should (string-match-p "Header 2" result))
      (should (string-match-p "Cell 1" result))
      (should (string-match-p "Cell 2" result))
      (should (string-match-p "|" result)))))

(ert-deftest org-tickets-test--parse-adf-heading-without-attrs ()
  "Test parsing ADF heading when attrs is absent.
The importer defaults to level 1, which is an org level-3 headline."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[
                      {\"type\":\"heading\",
                       \"content\":[{\"type\":\"text\",\"text\":\"Simple Heading\"}]}]}"))
                 "*** Simple Heading")))

(ert-deftest org-tickets-test--parse-adf-codeblock-without-attrs ()
  "Test parsing ADF codeBlock when attrs is absent.
With no \"attrs\"/\"language\", the src block has no language tag."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[
                      {\"type\":\"codeBlock\",
                       \"content\":[{\"type\":\"text\",\"text\":\"some code\"}]}]}"))
                 "#+BEGIN_SRC\nsome code\n#+END_SRC")))

;;;; Regression tests for attachment parsing

(ert-deftest org-tickets-test--parse-jira-issue-with-attachments ()
  "Test parsing Jira issue with attachments."
  (let* ((jira-response
          (org-tickets-test--json
           "{\"id\": \"12345\", \"key\": \"PROJ-100\",
             \"fields\": {\"summary\": \"Test Feature\",
               \"issuetype\": {\"name\": \"Feature\"},
               \"attachment\": [
                 {\"filename\": \"screenshot.png\",
                  \"content\": \"https://example.com/attaches/screenshot.png\",
                  \"size\": 12345},
                 {\"filename\": \"document.pdf\",
                  \"content\": \"https://example.com/attaches/document.pdf\",
                  \"size\": 67890}]}}"))
         (ticket (org-tickets--parse-jira-issue jira-response))
         (attachments (org-tickets--ticket-attachments ticket))
         (att1 (car attachments)))
    (should (string= (org-tickets--ticket-key ticket) "PROJ-100"))
    (should (= (length attachments) 2))
    (should (string= (org-tickets--attachment-filename att1) "screenshot.png"))
    (should (string= (org-tickets--attachment-content-url att1)
                     "https://example.com/attaches/screenshot.png"))
    (should (= (org-tickets--attachment-size att1) 12345))))

(ert-deftest org-tickets-test--issue-to-org-with-description-newlines ()
  "Test that issue-to-org preserves description newlines."
  (let ((ticket (org-tickets--ticket-create
                 :key "PROJ-100"
                 :type "Feature"
                 :summary "Test Feature"
                 :description "First paragraph\n\nSecond paragraph"
                 :fix-version "v1.0"
                 :labels nil
                 :story-points nil
                 :blocks nil
                 :blocked-by nil
                 :parent nil
                 :attachments nil)))
    (with-temp-buffer
      (org-mode)
      (org-tickets--issue-to-org ticket)
      (goto-char (point-min))
      (re-search-forward "^\\* Test Feature" nil t)
      (should (re-search-forward "First paragraph" nil t))
      (should (re-search-forward "Second paragraph" nil t)))))

(ert-deftest org-tickets-test--issue-to-org-no-duplicate-type-prefix ()
  "Test that issue-to-org strips the type prefix from the summary in the heading.

Jira returns summaries that already include the type prefix (e.g., 'Improvement: Do something').
The code should strip this prefix so the heading contains only the clean summary text,
not 'Improvement: Change how portalAPI...' but 'Change how portalAPI...'."
  (let ((ticket (org-tickets--ticket-create
                 :key "PROJ-100"
                 :type "Improvement"
                 :summary "Improvement: Change how portalAPI access is given to new groups"
                 :description "Test description"
                 :fix-version "v1.0"
                 :labels nil
                 :story-points nil
                 :blocks nil
                 :blocked-by nil
                 :parent nil
                 :attachments nil)))
    (with-temp-buffer
      (org-mode)
      (org-tickets--issue-to-org ticket)
      (goto-char (point-min))
      ;; The heading should be "* Change how portalAPI..." (prefix stripped)
      (should (re-search-forward "^\\* Change how portalAPI" nil t)))))

(ert-deftest org-tickets-test--issue-to-org-story-no-duplicate-prefix ()
  "Test that Story tickets strip the type prefix from the summary in the heading."
  (let ((ticket (org-tickets--ticket-create
                 :key "PROJ-200"
                 :type "Story"
                 :summary "Story: User wants to login"
                 :description "Story description"
                 :fix-version "v1.0"
                 :labels nil
                 :story-points 5
                 :blocks nil
                 :blocked-by nil
                 :parent nil
                 :attachments nil)))
    (with-temp-buffer
      (org-mode)
      (org-tickets--issue-to-org ticket)
      (goto-char (point-min))
      ;; The heading should be "** User wants to login" (prefix stripped)
      (should (re-search-forward "^\\*\\* User wants to login" nil t)))))

(ert-deftest org-tickets-test--issue-to-org-nil-type ()
  "Test that issue-to-org handles nil type gracefully.
If type is nil, should not error on regexp-quote."
  (let ((ticket (org-tickets--ticket-create
                 :key "PROJ-300"
                 :type nil
                 :summary "Some summary without type prefix"
                 :description "Test description"
                 :fix-version "v1.0"
                 :labels nil
                 :story-points nil
                 :blocks nil
                 :blocked-by nil
                 :parent nil
                 :attachments nil)))
    (with-temp-buffer
      (org-mode)
      (org-tickets--issue-to-org ticket)
      (goto-char (point-min))
      ;; Should create a heading (using catch-all _ branch)
      (should (re-search-forward "^\\* " nil t))
      ;; Should have the summary text
      (should (re-search-forward "Some summary without type prefix" nil t)))))

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

(ert-deftest org-tickets-test--validate-fix-version-is-anchored ()
  (should (org-tickets--validate-fix-version "Aug2026"))
  (should-not (org-tickets--validate-fix-version "Aug2026-draft"))
  (should-not (org-tickets--validate-fix-version "xxAug2026"))
  (should-not (org-tickets--validate-fix-version "Sep2026")))

(ert-deftest org-tickets-test--sync-reset-recovers-stuck-buffer ()
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

(ert-deftest org-tickets-test--interactive-commands-have-public-names ()
  (dolist (cmd '(org-tickets-create-story org-tickets-add-block-link
                                       org-tickets-set-fix-version org-tickets-update-story-sizing))
    (should (commandp cmd))))

(ert-deftest org-tickets-test--create-ticket-payload ()
  "Creating a ticket record POSTs every field it carries."
  (let* ((org-tickets--project-id "12345")
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

(provide (quote org-tickets-test-sync))
