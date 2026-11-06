;;; org-tickets-test-import-adf.el --- Tests for ADF to org text import  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for `org-tickets--parse-adf-description': what ADF documents
;; import as in org text.  Whole-ticket import lives in
;; org-tickets-test-import.el; headings in org-tickets-test-headings-pull.el.

;;; Code:

(require 'ert)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

(ert-deftest org-tickets-test--adf-import-ordered-numbering ()
  "Ordered list items are numbered from 1."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[
                      {\"type\":\"orderedList\",\"content\":[
                        {\"type\":\"listItem\",\"content\":[
                          {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"one\"}]}]},
                        {\"type\":\"listItem\",\"content\":[
                          {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"two\"}]}]}]}]}"))
                 "1. one\n2. two")))

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

(ert-deftest org-tickets-test--adf-import-doc-blank-line-separation ()
  "Top-level blocks are separated by exactly one blank line."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[
                      {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"one\"}]},
                      {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"two\"}]}]}"))
                 "one\n\ntwo")))

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

(ert-deftest org-tickets-test--adf-import-code-block ()
  "A codeBlock imports as a src block carrying its language."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[
                      {\"type\":\"codeBlock\",\"attrs\":{\"language\":\"python\"},
                       \"content\":[{\"type\":\"text\",\"text\":\"x = 1\\ny = 2\"}]}]}"))
                 "#+BEGIN_SRC python\nx = 1\ny = 2\n#+END_SRC")))

(ert-deftest org-tickets-test--adf-import-rule ()
  "Rules import as org horizontal rules."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[{\"type\":\"rule\"}]}"))
                 "-----")))

(ert-deftest org-tickets-test--adf-import-blockquote ()
  "Blockquotes import as org quote blocks (round-trippable)."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[
                      {\"type\":\"blockquote\",\"content\":[
                        {\"type\":\"paragraph\",\"content\":[
                          {\"type\":\"text\",\"text\":\"quoted text\"}]}]}]}"))
                 "#+BEGIN_QUOTE\nquoted text\n#+END_QUOTE")))

(ert-deftest org-tickets-test--adf-import-marks ()
  "strong, em, emphasis, code, strike and link marks map to org markup."
  (let ((doc "{\"type\":\"doc\",\"version\":1,\"content\":[
               {\"type\":\"paragraph\",\"content\":[
                 {\"type\":\"text\",\"text\":\"b\",\"marks\":[{\"type\":\"strong\"}]},
                 {\"type\":\"text\",\"text\":\"i\",\"marks\":[{\"type\":\"em\"}]},
                 {\"type\":\"text\",\"text\":\"c\",\"marks\":[{\"type\":\"code\"}]},
                 {\"type\":\"text\",\"text\":\"s\",\"marks\":[{\"type\":\"strike\"}]},
                 {\"type\":\"text\",\"text\":\"l\",\"marks\":[{\"type\":\"link\",\"attrs\":{\"href\":\"https://x.test\"}}]},
                 {\"type\":\"text\",\"text\":\" e\",\"marks\":[{\"type\":\"emphasis\"}]}]}]}"))
    (should (equal (org-tickets--parse-adf-description (org-tickets-test--json doc))
                   "*b*/i/~c~+s+[[https://x.test][l]]/ e/"))))

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

(ert-deftest org-tickets-test--adf-import-media-single-unknown-id-fallback ()
  "Test that mediaSingle falls back to [media: id] when attachment ID is unknown."
  (let* ((adf (org-tickets-test--json "{\"type\": \"doc\", \"version\": 1, \"content\": [{\"type\": \"mediaSingle\", \
    \"content\": [{\"type\": \"media\", \"attrs\": {\"type\": \"file\", \"id\": \"unknown-id\", \
    \"collection\": \"\"}}]}]}")))
    (let ((result (org-tickets--parse-adf-description adf)))
      (should (string-match-p "\\[media: unknown-id\\]" result)))))

(ert-deftest org-tickets-test--adf-import-media-single-as-attachment-link ()
  "Test that mediaSingle ADF nodes import as [[attachment:filename]] links when ID is known."
  (let* ((id-map (list (cons "abc123" "screenshot.png")))
         (adf (org-tickets-test--json "{\"type\": \"doc\", \"version\": 1, \"content\": [{\"type\": \"mediaSingle\", \
    \"attrs\": {\"width\": 800, \"layout\": \"align-start\"}, \"content\": [{\"type\": \"media\", \
    \"attrs\": {\"type\": \"file\", \"id\": \"abc123\", \"collection\": \"\"}}]}]}")))
    (let ((result (org-tickets--parse-adf-description adf id-map)))
      (should (string-match-p "\\[\\[attachment:screenshot\\.png\\]\\]" result)))))

(ert-deftest org-tickets-test--adf-import-media-inline-as-attachment-link ()
  "A mediaInline node imports as an [[attachment:FILE]] link."
  (let* ((id-map (list (cons "att-uuid-123" "design.pdf")
                       (cons "att-uuid-456" "report.xlsx")))
         (adf (org-tickets-test--json "{\"type\": \"doc\", \"version\": 1, \"content\": [{\"type\": \"paragraph\", \"content\": [{\"type\": \"text\", \
    \"text\": \"See \"}, {\"type\": \"mediaInline\", \"attrs\": {\"id\": \"att-uuid-123\", \
    \"collection\": \"\", \"type\": \"file\"}}, {\"type\": \"text\", \"text\": \" for details\"}]}]}")))
    (should (equal (org-tickets--parse-adf-description adf id-map)
                   "See [[attachment:design.pdf]] for details"))))

(ert-deftest org-tickets-test--adf-import-list-followed-by-paragraph ()
  "A paragraph after a list stays after the list in the org output."
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

(ert-deftest org-tickets-test--adf-import-code-block-without-attrs ()
  "A codeBlock with no attrs imports as a src block without a language."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"version\":1,\"content\":[
                      {\"type\":\"codeBlock\",
                       \"content\":[{\"type\":\"text\",\"text\":\"some code\"}]}]}"))
                 "#+BEGIN_SRC\nsome code\n#+END_SRC")))

(provide 'org-tickets-test-import-adf)

;;; org-tickets-test-import-adf.el ends here
