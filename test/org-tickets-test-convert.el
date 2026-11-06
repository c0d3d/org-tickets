;;; org-tickets-test-convert.el --- Tests for org-tickets conversion and ADF functions  -*- lexical-binding: t; -*-

;; Copyright (C) 2024

;;; Commentary:

;; Tests for `org-tickets--build-adf-description' (org -> ADF) and its
;; interplay with attachments.  Org -> ADF -> org round-trips are in
;; org-tickets-test-roundtrip.el; ADF import in org-tickets-test-import-adf.el.

;;; Code:

(require 'ert)
(require 'org)
(require 'org-element)

(require 'org-tickets)
(require 'org-tickets-test-fixtures)

(ert-deftest org-tickets-test--build-adf-description-list-nodes ()
  "Ordered and bullet lists convert to orderedList and bulletList nodes."
  (should (equal (mapcar #'org-tickets-test--block-type
                         (org-tickets-test--adf-blocks "1. First\n2. Second"))
                 '("orderedList")))
  (should (equal (mapcar #'org-tickets-test--block-type
                         (org-tickets-test--adf-blocks "- Alpha\n- Beta"))
                 '("bulletList"))))

(ert-deftest org-tickets-test--build-adf-description-code-block ()
  "A src block becomes one codeBlock whose text is the code, unescaped,
and whose attrs carry the language Jira's schema requires."
  (should (equal (car (cdr (assoc "content"
                                  (org-tickets--build-adf-description
                                   "#+begin_src js\nfunction test() {\n  return true;\n}\n#+end_src"))))
                 '(("type" . "codeBlock")
                   ("attrs" ("language" . "js"))
                   ("content" (("type" . "text")
                               ("text" . "function test() {\n  return true;\n}"))))))
  (should (equal (cdr (assoc "attrs"
                             (car (cdr (assoc "content"
                                              (org-tickets--build-adf-description
                                               "#+begin_src text\nDoing the thing\n#+end_src"))))))
                 '(("language" . "text")))))

(ert-deftest org-tickets-test--build-adf-description-link-is-link-mark ()
  "An org link becomes its description text carrying a link mark."
  (should (equal (cdr (assoc "content"
                             (car (cdr (assoc "content"
                                              (org-tickets--build-adf-description
                                               "[[https://example.com][Click here]]"))))))
                 '((("type" . "text") ("text" . "Click here")
                    ("marks" (("type" . "link")
                              ("attrs" ("href" . "https://example.com")))))))))

(ert-deftest org-tickets-test--adf-text-not-escaped ()
  "Test that ADF text nodes contain literal text without markdown escaping.
ADF uses structured marks for formatting, not markup characters.
Characters like { } [ ] should pass through unescaped in plain text nodes."
  ;; Use content with { } [ ] which org does not consume as markup
  (let* ((content "Use {braces} and [brackets] here.")
         (adf (org-tickets--build-adf-description content)))
    (should adf)
    (let* ((content-list (cdr (assoc "content" adf)))
           (para (car content-list))
           (text-nodes (cdr (assoc "content" para)))
           (all-text (mapconcat (lambda (node)
                                  (or (cdr (assoc "text" node)) ""))
                                text-nodes "")))
      ;; Text should NOT contain backslash escapes
      (should-not (string-match-p "\\\\" all-text))
      ;; Original characters should be preserved literally
      (should (string-match-p "{braces}" all-text))
      (should (string-match-p "\\[brackets\\]" all-text)))))

(ert-deftest org-tickets-test--build-adf-description-simple-text ()
  "Test building ADF description with simple text."
  (let ((content "This is simple text."))
    (let ((adf (org-tickets--build-adf-description content)))
      (should adf)
      (should (equal (cdr (assoc "type" adf)) "doc"))
      (should (cdr (assoc "content" adf)))
      (let ((content-list (cdr (assoc "content" adf))))
        (should (= (length content-list) 1))
        (let ((para (car content-list)))
          (should (equal (cdr (assoc "type" para)) "paragraph"))
          (let ((text-content (cdr (assoc "content" para))))
            (should (= (length text-content) 1))
            (should (equal (cdr (assoc "text" (car text-content))) "This is simple text."))))))))

(ert-deftest org-tickets-test--build-adf-description-table-header-attr ()
  "Test that ADF table header cells use the tableHeader node type.
Regression test: the old code set a non-schema \"header\" attr on
tableCell instead of emitting the ADF-defined tableHeader node type."
  (let ((content "| Header1 | Header2 |
|----------+----------|
| Value1   | value2   |"))
    (let ((adf (org-tickets--build-adf-description content)))
      (should adf)
      (let ((table (car (cdr (assoc "content" adf)))))
        (should (equal (cdr (assoc "type" table)) "table"))
        (let ((table-rows (cdr (assoc "content" table))))
          ;; First row should be header row: both cells are tableHeader.
          (let ((first-row (car table-rows)))
            (let ((cells (cdr (assoc "content" first-row))))
              (let ((first-cell (car cells)))
                (should (equal (cdr (assoc "type" first-cell)) "tableHeader"))
                (should-not (cdr (assoc "attrs" first-cell))))
              (let ((second-cell (cadr cells)))
                (should (equal (cdr (assoc "type" second-cell)) "tableHeader"))
                (should-not (cdr (assoc "attrs" second-cell))))))
          ;; Second row is a data row: cells are tableCell, not tableHeader.
          (let ((second-row (cadr table-rows)))
            (let ((cells (cdr (assoc "content" second-row))))
              (let ((first-cell (car cells)))
                (should (equal (cdr (assoc "type" first-cell)) "tableCell"))))))))))

(ert-deftest org-tickets-test--build-adf-description-empty ()
  "Test building ADF description with empty content."
  (should (null (org-tickets--build-adf-description "")))
  (should (null (org-tickets--build-adf-description nil))))

(ert-deftest org-tickets-test--build-adf-description-mixed ()
  "Test building ADF description with mixed content (text, code, table)."
  (let ((content "Some text before.
#+begin_src python
print(\"hello\")
#+end_src

And some text after.

| Col1 | Col2 |
|------|------|
| A    | B    |"))
    (let ((adf (org-tickets--build-adf-description content)))
      (should adf)
      (let ((content-list (cdr (assoc "content" adf))))
        ;; Should have 4 content nodes: paragraph, codeBlock, paragraph, table
        (should (= (length content-list) 4))
        ;; First is paragraph with text
        (should (equal (cdr (assoc "type" (nth 0 content-list))) "paragraph"))
        ;; Second is code block
        (should (equal (cdr (assoc "type" (nth 1 content-list))) "codeBlock"))
        ;; Third is paragraph with text
        (should (equal (cdr (assoc "type" (nth 2 content-list))) "paragraph"))
        ;; Fourth is table
        (should (equal (cdr (assoc "type" (nth 3 content-list))) "table"))))))

(ert-deftest org-tickets-test--build-adf-table-with-bold-cell ()
  "Test building ADF table when a cell contains bold text.
Regression test: convert-to-adf-table-cell crashed because (car ...)
returned an alist instead of a string when processing formatted content."
  (let ((content "| *Bold* | Normal |"))
    (let ((adf (org-tickets--build-adf-description content)))
      (should adf)
      (let* ((content-list (cdr (assoc "content" adf)))
             (table (car content-list)))
        (should (equal (cdr (assoc "type" table)) "table"))
        ;; Verify table has rows with cells
        (let* ((rows (cdr (assoc "content" table)))
               (first-row (car rows))
               (cells (cdr (assoc "content" first-row)))
               (first-cell (car cells)))
          ;; Cell should have paragraph content
          (let* ((cell-content (cdr (assoc "content" first-cell)))
                 (para (car cell-content))
                 (para-content (cdr (assoc "content" para))))
            ;; Should contain text node(s) with "Bold"
            (should (seq-some (lambda (node)
                                (and (equal (cdr (assoc "type" node)) "text")
                                     (string-match-p "Bold" (cdr (assoc "text" node)))))
                              para-content))))))))

(ert-deftest org-tickets-test--build-adf-bold-with-nested-code ()
  "Test that bold text containing inline code converts to ADF without crashing.
Regression test: (car (convert-to-adf-content elem)) returned an alist
instead of a string for nested code elements."
  (let* ((content "*bold =code= text*")
         (adf (org-tickets--build-adf-description content)))
    (should adf)
    (let* ((content-list (cdr (assoc "content" adf)))
           (para (car content-list))
           (text-nodes (cdr (assoc "content" para))))
      ;; Should produce text node(s) containing "bold" and "code" and "text"
      (let ((all-text (mapconcat (lambda (node)
                                   (or (cdr (assoc "text" node)) ""))
                                 text-nodes "")))
        (should (string-match-p "bold" all-text))
        (should (string-match-p "code" all-text))))))

(ert-deftest org-tickets-test--adf-attachment-link-becomes-media-inline ()
  "Mid-text attachment: links become mediaInline nodes carrying the media UUID.
Regression: Jira renders media nodes only when their id is the Media
Services UUID (the attachment's mediaApiFileId).  The numeric REST
attachment id must never be emitted — Jira shows a broken file card."
  (let* ((attachments (org-tickets-test--json "[{\"id\": \"10001\", \"filename\": \"design.pdf\", \"mediaApiFileId\": \"med-uuid-123\"}]"))
         (content "See [[attachment:design.pdf][design doc]] for details")
         (adf (org-tickets--build-adf-description content attachments)))
    (should adf)
    (let* ((content-list (cdr (assoc "content" adf)))
           (para (car content-list))
           (para-content (cdr (assoc "content" para)))
           (media-node (seq-find (lambda (node)
                                   (string= (cdr (assoc "type" node)) "mediaInline"))
                                 para-content)))
      (should media-node)
      (let ((attrs (cdr (assoc "attrs" media-node))))
        (should (string= (cdr (assoc "id" attrs)) "med-uuid-123"))
        (should (string= (cdr (assoc "type" attrs)) "file"))))))

(ert-deftest org-tickets-test--adf-attachment-without-media-uuid-falls-back-to-text ()
  "An attachment lacking a mediaApiFileId renders as plain text, not media.
Regression: emitting a media node with the numeric REST attachment id
produces a permanently broken embed in Jira; plain text degrades safely."
  (let* ((attachments (org-tickets-test--json "[{\"id\": \"10001\", \"filename\": \"design.pdf\"}]"))
         (content "See [[attachment:design.pdf][design doc]] for details")
         (adf (org-tickets--build-adf-description content attachments)))
    (should adf)
    (let* ((content-list (cdr (assoc "content" adf)))
           (para (car content-list))
           (para-content (cdr (assoc "content" para))))
      (should-not (seq-find (lambda (node)
                              (member (cdr (assoc "type" node))
                                      '("mediaInline" "media" "mediaSingle")))
                            para-content))
      (should (seq-find (lambda (node)
                          (string-match-p "design"
                                          (or (cdr (assoc "text" node)) "")))
                        para-content)))))

(ert-deftest org-tickets-test--adf-standalone-attachment-link-becomes-media-single ()
  "An attachment link alone in its paragraph becomes a block mediaSingle.
mediaInline renders as a small file chip; only a mediaSingle > media
block displays an image inline in the description."
  (let* ((attachments (org-tickets-test--json "[{\"id\": \"10002\", \"filename\": \"screenshot.png\", \"mediaApiFileId\": \"med-uuid-shot\"}]"))
         (content "[[attachment:screenshot.png]]")
         (adf (org-tickets--build-adf-description content attachments))
         (content-list (cdr (assoc "content" adf)))
         (media-single (seq-find (lambda (node)
                                   (string= (cdr (assoc "type" node)) "mediaSingle"))
                                 content-list)))
    (should media-single)
    (let* ((children (cdr (assoc "content" media-single)))
           (media (car children))
           (attrs (cdr (assoc "attrs" media))))
      (should (string= (cdr (assoc "type" media)) "media"))
      (should (string= (cdr (assoc "id" attrs)) "med-uuid-shot"))
      (should (string= (cdr (assoc "type" attrs)) "file")))))

(ert-deftest org-tickets-test--adf-standalone-attachment-between-paragraphs ()
  "A standalone attachment paragraph becomes a mediaSingle between paragraphs.
Surrounding prose stays in ordinary paragraph nodes."
  (let* ((attachments (org-tickets-test--json "[{\"id\": \"10002\", \"filename\": \"screenshot.png\", \"mediaApiFileId\": \"med-uuid-shot\"}]"))
         (content "Before text\n\n[[attachment:screenshot.png]]\n\nAfter text")
         (adf (org-tickets--build-adf-description content attachments))
         (types (mapcar (lambda (node) (cdr (assoc "type" node)))
                        (cdr (assoc "content" adf)))))
    (should (equal types '("paragraph" "mediaSingle" "paragraph")))))

(ert-deftest org-tickets-test--adf-attachment-link-unknown-id-falls-back-to-text ()
  "Test that attachment: links render as text when no matching attachment ID is found."
  (let* ((attachments (org-tickets-test--json "[{\"id\": \"att-other\", \"filename\": \"other.pdf\"}]"))
         (content "See [[attachment:unknown.pdf]]")
         (adf (org-tickets--build-adf-description content attachments)))
    (should adf)
    (let* ((content-list (cdr (assoc "content" adf)))
           (para (car content-list))
           (para-content (cdr (assoc "content" para)))
           (text-node (seq-find (lambda (node)
                                  (string-match-p "unknown\\.pdf"
                                                  (or (cdr (assoc "text" node)) "")))
                                para-content)))
      (should text-node)
      (should (string= (cdr (assoc "type" text-node)) "text"))
      (should-not (cdr (assoc "marks" text-node))))))

(ert-deftest org-tickets-test--attachment-link-round-trip ()
  "Test that attachment: links survive org -> ADF -> org round-trip.
The outbound media node carries the media UUID (mediaApiFileId), and the
import side resolves that same UUID back to the filename."
  (let* ((attachments (org-tickets-test--json "[{\"id\": \"10042\", \"filename\": \"notes.pdf\", \"mediaApiFileId\": \"rt-uuid-1\"}]"))
         (org-content "Check [[attachment:notes.pdf][notes]] please")
         (adf (org-tickets--build-adf-description org-content attachments))
         ;; Build ID→filename map for import side
         (result (org-tickets--parse-adf-description
                  adf (list (cons "rt-uuid-1" "notes.pdf")))))
    (should (string-match-p "\\[\\[attachment:notes\\.pdf\\]\\]" result))))

(ert-deftest org-tickets-test--standalone-attachment-round-trip ()
  "A standalone attachment link survives org -> mediaSingle -> org."
  (let* ((attachments (org-tickets-test--json "[{\"id\": \"10043\", \"filename\": \"diagram.png\", \"mediaApiFileId\": \"rt-uuid-2\"}]"))
         (org-content "[[attachment:diagram.png]]")
         (adf (org-tickets--build-adf-description org-content attachments))
         (result (org-tickets--parse-adf-description
                  adf (list (cons "rt-uuid-2" "diagram.png")))))
    (should (string-match-p "\\[\\[attachment:diagram\\.png\\]\\]" result))))

(ert-deftest org-tickets-test--adf-inline-markup-preserves-trailing-space ()
  "Test that inline markup (bold, italic, code, verbatim, link) preserves trailing space.
Regression test: org-mode stores the space after inline markup in the element's
:post-blank property, not in the following text string.  The ADF converters must
emit that space so it is not silently deleted."
  ;; Bold
  (let* ((adf (org-tickets--build-adf-description "This is *bold* text"))
         (texts (org-tickets-test--adf-texts (cdr (assoc "content" adf))))
         (all (mapconcat #'identity texts "")))
    (should (string-match-p "bold text" all)))
  ;; Italic
  (let* ((adf (org-tickets--build-adf-description "This is /italic/ text"))
         (texts (org-tickets-test--adf-texts (cdr (assoc "content" adf))))
         (all (mapconcat #'identity texts "")))
    (should (string-match-p "italic text" all)))
  ;; Code
  (let* ((adf (org-tickets--build-adf-description "This is ~code~ text"))
         (texts (org-tickets-test--adf-texts (cdr (assoc "content" adf))))
         (all (mapconcat #'identity texts "")))
    (should (string-match-p "code text" all)))
  ;; Verbatim
  (let* ((adf (org-tickets--build-adf-description "This is =verbatim= text"))
         (texts (org-tickets-test--adf-texts (cdr (assoc "content" adf))))
         (all (mapconcat #'identity texts "")))
    (should (string-match-p "verbatim text" all)))
  ;; Link
  (let* ((adf (org-tickets--build-adf-description "Click [[https://example.com][here]] now"))
         (texts (org-tickets-test--adf-texts (cdr (assoc "content" adf))))
         (all (mapconcat #'identity texts "")))
    (should (string-match-p "here now" all))))

(ert-deftest org-tickets-test--adf-inline-markup-no-trailing-space-at-end ()
  "Test that inline markup at end of paragraph does not add spurious space."
  (let* ((adf (org-tickets--build-adf-description "End with *bold*"))
         (texts (org-tickets-test--adf-texts (cdr (assoc "content" adf))))
         (all (mapconcat #'identity texts "")))
    (should (string-match-p "with bold" all))
    ;; Should not have trailing space
    (should-not (string-match-p "bold " all))))

(ert-deftest org-tickets-test--adf-underscore-not-subscript ()
  "Regression: `release/26_02' must survive as literal text.
Org parses `26_02' as a subscript, dropping the underscore and the
space that follows.  The ADF output must keep both."
  (let* ((adf (org-tickets--build-adf-description
               "- release/26_02 job server job works"))
         (texts (org-tickets-test--adf-texts (cdr (assoc "content" adf))))
         (all (mapconcat #'identity texts "")))
    (should (string-match-p "release/26_02 job server job works" all))))

(ert-deftest org-tickets-test--adf-superscript-not-consumed ()
  "Regression: a caret token like `x^2' keeps its caret as literal text."
  (let* ((adf (org-tickets--build-adf-description "value x^2 here"))
         (texts (org-tickets-test--adf-texts (cdr (assoc "content" adf))))
         (all (mapconcat #'identity texts "")))
    (should (string-match-p "x\\^2 here" all))))

(ert-deftest org-tickets-test--adf-list-item-no-trailing-newline ()
  "Regression: list item paragraph text must not carry org's trailing newline.
A trailing newline renders as a spurious blank line inside each bullet."
  (let* ((adf (org-tickets--build-adf-description
               "- release/26_02 job works\n- development job works\n- demo"))
         (texts (org-tickets-test--adf-texts (cdr (assoc "content" adf)))))
    (should texts)
    (dolist (s texts)
      (should-not (string-match-p "\n" s)))))

(ert-deftest org-tickets-test--adf-soft-newline-becomes-hardbreak ()
  "A single newline within a paragraph becomes an ADF hardBreak node.
Without this, a multi-line paragraph collapses onto one visual line in Jira."
  (let* ((adf (org-tickets--build-adf-description "line one\nline two"))
         (para (car (cdr (assoc "content" adf))))
         (nodes (cdr (assoc "content" para))))
    (should (equal (mapcar (lambda (n) (cdr (assoc "type" n))) nodes)
                   '("text" "hardBreak" "text")))
    (should (equal (cdr (assoc "text" (nth 0 nodes))) "line one"))
    (should (equal (cdr (assoc "text" (nth 2 nodes))) "line two"))))

(ert-deftest org-tickets-test--adf-no-trailing-hardbreak ()
  "The structural newline that terminates a paragraph must not emit a hardBreak."
  (let* ((adf (org-tickets--build-adf-description "just one line\n"))
         (para (car (cdr (assoc "content" adf))))
         (nodes (cdr (assoc "content" para))))
    (should (equal (mapcar (lambda (n) (cdr (assoc "type" n))) nodes)
                   '("text")))
    (should (equal (cdr (assoc "text" (car nodes))) "just one line"))))

(ert-deftest org-tickets-test--adf-hard-line-break-becomes-hardbreak ()
  "An org hard line break (\\\\) becomes an ADF hardBreak instead of being
dropped and fusing the surrounding words."
  (let* ((adf (org-tickets--build-adf-description "line one\\\\\nline two"))
         (para (car (cdr (assoc "content" adf))))
         (nodes (cdr (assoc "content" para)))
         (types (mapcar (lambda (n) (cdr (assoc "type" n))) nodes))
         (texts (delq nil (mapcar (lambda (n) (cdr (assoc "text" n))) nodes))))
    ;; A hardBreak separates the two lines, so the words are not fused.
    (should (member "hardBreak" types))
    (should (member "line one" texts))
    (should (member "line two" texts))
    (should-not (member "line oneline two" texts))))

(ert-deftest org-tickets-test--table-without-rule-has-no-header-row ()
  "A table without a rule row emits no tableHeader nodes."
  (let* ((adf (org-tickets--build-adf-description "| a | b |\n| c | d |"))
         (json (json-encode adf)))
    (should-not (string-match-p "tableHeader" json))))

(ert-deftest org-tickets-test--link-description-not-truncated-to-first-string ()
  "The full link description survives, not just the text before the
first nested mark.  The tail after `*this*' — \"whole description\" —
lands in a SINGLE contiguous text node that itself carries the link
mark, so the tail can't silently escape the hyperlink."
  (let* ((adf (org-tickets--build-adf-description
               "[[https://x.test][see *this* whole description]]"))
         (json (json-encode adf)))
    ;; The tail is one text node, and its marks include the link.
    (should (string-match-p
             (regexp-quote
              "\"text\":\"whole description\",\"marks\":[{\"type\":\"link\",\"attrs\":{\"href\":\"https://x.test\"}}]")
             json))
    (should (string-match-p "\"href\":\"https://x.test\"" json))))

(ert-deftest org-tickets-test--nested-marks-compose ()
  "Italic inside bold keeps BOTH marks instead of flattening."
  (let* ((adf (org-tickets--build-adf-description "*bold with /italic/ inside*"))
         (json (json-encode adf)))
    ;; The italic run carries em AND strong.
    (should (string-match-p "\"marks\":\\[{\"type\":\"em\"},{\"type\":\"strong\"}\\]"
                            json))
    ;; The plain-bold runs carry strong.
    (should (string-match-p "\"marks\":\\[{\"type\":\"strong\"}\\]" json))))

(ert-deftest org-tickets-test--hardbreak-inside-bold-survives ()
  "A line break inside bold text stays inside the bold run."
  (let* ((adf (org-tickets--build-adf-description "*line1\nline2*"))
         (json (json-encode adf)))
    (should (string-match-p "hardBreak" json))
    (should (string-match-p "line1" json))
    (should (string-match-p "line2" json))))

(ert-deftest org-tickets-test--code-and-verbatim-convert-identically ()
  "Org code and verbatim markup both convert to a code mark."
  (let ((code (org-tickets--build-adf-description "before ~x~ after"))
        (verb (org-tickets--build-adf-description "before =x= after")))
    (should (equal code verb))))

(ert-deftest org-tickets-test--build-adf-description-resolves-attachment-link ()
  "An attachment: link becomes a mediaInline node carrying the media UUID."
  (let* ((attachments (org-tickets-test--json
                       "[{\"id\": \"10234\", \"filename\": \"spec.pdf\",
                          \"mediaApiFileId\": \"sym-uuid-1\"}]"))
         (adf (org-tickets--build-adf-description
               "See [[attachment:spec.pdf]]" attachments))
         (para (car (cdr (assoc "content" adf))))
         (media (seq-find (lambda (node)
                            (equal (cdr (assoc "type" node)) "mediaInline"))
                          (cdr (assoc "content" para)))))
    (should media)
    (should (equal (cdr (assoc "id" (cdr (assoc "attrs" media)))) "sym-uuid-1"))))

(provide 'org-tickets-test-convert)

;;; org-tickets-test-convert.el ends here
