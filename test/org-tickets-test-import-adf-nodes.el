;;; org-tickets-test-import-adf-nodes.el --- ADF import: node types and edge cases  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for `org-tickets--parse-adf-description' on the less common ADF
;; node types, marks and malformed-but-real shapes Jira sends: empty
;; paragraphs, header-only tables, inline cards, unknown nodes, and
;; blocks nested in list items.  The common shapes are in
;; org-tickets-test-import-adf.el.

;;; Code:

(require 'ert)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; Helpers

(defun org-tickets-test--node (type &rest slots)
  "Return an ADF node of TYPE; SLOTS are alternating string keys and values.
A list value for \"content\" or \"marks\" becomes a JSON array."
  (let ((node (list (cons "type" type))))
    (while slots
      (let ((key (pop slots))
            (value (pop slots)))
        (push (cons key (if (member key '("content" "marks")) (vconcat value) value))
              node)))
    (nreverse node)))

(defun org-tickets-test--text (text &rest marks)
  "Return an ADF text node holding TEXT with MARKS (each an ADF mark)."
  (if marks
      (org-tickets-test--node "text" "text" text "marks" marks)
    (org-tickets-test--node "text" "text" text)))

(defun org-tickets-test--mark (type &optional attrs)
  "Return an ADF mark of TYPE with ATTRS."
  (if attrs
      (org-tickets-test--node type "attrs" attrs)
    (org-tickets-test--node type)))

(defun org-tickets-test--para-of (&rest inlines)
  "Return an ADF paragraph of INLINES."
  (org-tickets-test--node "paragraph" "content" inlines))

(defun org-tickets-test--pull-blocks (&rest blocks)
  "Import a doc of BLOCKS, passed through JSON like an API response."
  (org-tickets-test--pull (apply #'org-tickets-test--adf-doc blocks)))

(defun org-tickets-test--pull-inlines (&rest inlines)
  "Import a doc holding one paragraph of INLINES."
  (org-tickets-test--pull-blocks (apply #'org-tickets-test--para-of inlines)))

(defun org-tickets-test--item (&rest blocks)
  "Return an ADF listItem of BLOCKS."
  (org-tickets-test--node "listItem" "content" blocks))

(defun org-tickets-test--cell (type text)
  "Return an ADF table cell of TYPE holding paragraph TEXT."
  (org-tickets-test--node type "content" (list (org-tickets-test--adf-para text))))

(defun org-tickets-test--row (&rest cells)
  "Return an ADF tableRow of CELLS."
  (org-tickets-test--node "tableRow" "content" cells))

;;;; Empty paragraphs

(ert-deftest org-tickets-test--adf-import-empty-paragraph-adds-no-blank-lines ()
  "An empty paragraph between two paragraphs imports like it is absent,
so blank lines do not grow on every pull."
  (let ((expected (org-tickets-test--pull-blocks
                   (org-tickets-test--adf-para "a")
                   (org-tickets-test--adf-para "b"))))
    (should (equal expected "a\n\nb"))
    (should (equal (org-tickets-test--pull-blocks
                    (org-tickets-test--adf-para "a")
                    (org-tickets-test--node "paragraph")
                    (org-tickets-test--node "paragraph" "content" nil)
                    (org-tickets-test--adf-para "b"))
                   expected))))

(ert-deftest org-tickets-test--adf-import-only-empty-paragraphs-is-nil ()
  "A doc of only empty paragraphs has no description."
  (should-not (org-tickets-test--pull-blocks
               (org-tickets-test--node "paragraph")
               (org-tickets-test--node "paragraph" "content" nil))))

;;;; Tables

(ert-deftest org-tickets-test--adf-import-header-only-table-keeps-rule ()
  "A table whose only row is a header row still gets its rule row."
  (should (equal (org-tickets-test--pull-blocks
                  (org-tickets-test--node
                   "table" "content"
                   (list (org-tickets-test--row
                          (org-tickets-test--cell "tableHeader" "H1")
                          (org-tickets-test--cell "tableHeader" "H2")))))
                 "| H1 | H2 |\n|---+---|")))

(ert-deftest org-tickets-test--roundtrip-header-only-table ()
  "A header-only table survives pull+push as a header table."
  (should (equal (org-tickets-test--roundtrip "| H1 | H2 |\n|---+---|")
                 "| H1 | H2 |\n|---+---|")))

(ert-deftest org-tickets-test--adf-import-ragged-table ()
  "Rows keep their own cell counts; the rule row follows the header's."
  (should (equal (org-tickets-test--pull-blocks
                  (org-tickets-test--node
                   "table" "content"
                   (list (org-tickets-test--row
                          (org-tickets-test--cell "tableHeader" "H1")
                          (org-tickets-test--cell "tableHeader" "H2"))
                         (org-tickets-test--row
                          (org-tickets-test--cell "tableCell" "a"))
                         (org-tickets-test--row
                          (org-tickets-test--cell "tableCell" "b")
                          (org-tickets-test--cell "tableCell" "c")
                          (org-tickets-test--cell "tableCell" "d")))))
                 "| H1 | H2 |\n|---+---|\n| a |\n| b | c | d |")))

(ert-deftest org-tickets-test--adf-import-table-row-without-cells ()
  "A row with no cells imports as an empty org table row, and a leading
empty row is not mistaken for a header."
  (should (equal (org-tickets-test--pull-blocks
                  (org-tickets-test--node
                   "table" "content"
                   (list (org-tickets-test--node "tableRow")
                         (org-tickets-test--row
                          (org-tickets-test--cell "tableHeader" "H")))))
                 "|  |\n| H |")))

;;;; Inline nodes

(ert-deftest org-tickets-test--adf-import-mention-and-emoji-use-their-text ()
  "Mentions and emoji import as their display text."
  (should (equal (org-tickets-test--pull-inlines
                  (org-tickets-test--text "hi ")
                  (org-tickets-test--node "mention" "attrs" '(("id" . "u1")
                                                             ("text" . "@Ann")))
                  (org-tickets-test--text " ")
                  (org-tickets-test--node "emoji" "attrs" '(("shortName" . ":smile:")
                                                           ("text" . "😄"))))
                 "hi @Ann 😄")))

(ert-deftest org-tickets-test--adf-import-mention-without-text-is-empty ()
  "A mention with no text attribute imports as nothing."
  (should (equal (org-tickets-test--pull-inlines
                  (org-tickets-test--text "a")
                  (org-tickets-test--node "mention" "attrs" '(("id" . "u1")))
                  (org-tickets-test--text "b"))
                 "ab")))

(ert-deftest org-tickets-test--adf-import-inline-card ()
  "An inlineCard imports as a bare org link; without a url it is dropped."
  (should (equal (org-tickets-test--pull-inlines
                  (org-tickets-test--text "see ")
                  (org-tickets-test--node "inlineCard"
                                          "attrs" '(("url" . "https://x.test/1")))
                  (org-tickets-test--text " and ")
                  (org-tickets-test--node "inlineCard" "attrs" '(("data" . "x"))))
                 "see [[https://x.test/1]] and ")))

(ert-deftest org-tickets-test--adf-import-unknown-inline-keeps-text ()
  "An unknown inline node keeps the text of its content, or its text attr."
  (should (equal (org-tickets-test--pull-inlines
                  (org-tickets-test--text "a ")
                  (org-tickets-test--node "fancyInline" "content"
                                          (list (org-tickets-test--text "nested")))
                  (org-tickets-test--text " ")
                  (org-tickets-test--node "status" "attrs" '(("text" . "DONE")
                                                            ("color" . "green"))))
                 "a nested DONE")))

;;;; Unknown and container blocks

(ert-deftest org-tickets-test--adf-import-unknown-block-keeps-inline-text ()
  "An unknown block holding inline nodes imports as their text."
  (should (equal (org-tickets-test--pull-blocks
                  (org-tickets-test--node "fancyBlock" "content"
                                          (list (org-tickets-test--text "a")
                                                (org-tickets-test--text "b"))))
                 "ab")))

(ert-deftest org-tickets-test--adf-import-unknown-block-keeps-block-children ()
  "An unknown block holding blocks keeps each one on its own line,
including through unknown intermediate containers."
  (should (equal (org-tickets-test--pull-blocks
                  (org-tickets-test--node
                   "layoutSection" "content"
                   (list (org-tickets-test--node
                          "layoutColumn" "content"
                          (list (org-tickets-test--adf-para "left")))
                         (org-tickets-test--node
                          "layoutColumn" "content"
                          (list (org-tickets-test--adf-para "right"))))))
                 "left\nright")))

(ert-deftest org-tickets-test--adf-import-expand-and-panel-keep-blocks ()
  "expand and panel blocks import as their content blocks."
  (should (equal (org-tickets-test--pull-blocks
                  (org-tickets-test--node
                   "expand" "attrs" '(("title" . "More"))
                   "content" (list (org-tickets-test--adf-para "x")
                                   (org-tickets-test--adf-para "y")))
                  (org-tickets-test--node
                   "panel" "content" (list (org-tickets-test--adf-para "z"))))
                 "x\ny\n\nz")))

(ert-deftest org-tickets-test--adf-import-media-group ()
  "A mediaGroup imports each media child as an attachment link."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--adf-doc
                   (org-tickets-test--node
                    "mediaGroup" "content"
                    (list (org-tickets-test--node "media" "attrs" '(("id" . "u1")))
                          (org-tickets-test--node "media" "attrs" '(("id" . "u2"))))))
                  '(("u1" . "a.png") ("u2" . "b.pdf")))
                 "[[attachment:a.png]][[attachment:b.pdf]]")))

(ert-deftest org-tickets-test--adf-import-media-fallbacks ()
  "Media with no known id falls back to its alt, then to [media: unknown];
a non-media child of mediaSingle imports as nothing."
  (should (equal (org-tickets-test--pull-blocks
                  (org-tickets-test--node
                   "mediaSingle" "content"
                   (list (org-tickets-test--node "media" "attrs" '(("alt" . "x.png")))))
                  (org-tickets-test--node
                   "mediaSingle" "content"
                   (list (org-tickets-test--node "media" "attrs" '(("type" . "file")))))
                  (org-tickets-test--node
                   "mediaSingle" "content"
                   (list (org-tickets-test--node "caption" "content"
                                                 (list (org-tickets-test--text "cap")))
                         (org-tickets-test--node "media" "attrs" '(("id" . "z"))))))
                 "[[attachment:x.png]]\n\n[media: unknown]\n\n[media: z]")))

;;;; Marks

(ert-deftest org-tickets-test--adf-import-underline-mark ()
  "The underline mark imports as org underline."
  (should (equal (org-tickets-test--pull-inlines
                  (org-tickets-test--text "u" (org-tickets-test--mark "underline")))
                 "_u_")))

(ert-deftest org-tickets-test--adf-import-link-without-href-is-plain ()
  "A link mark with no href leaves the text unlinked."
  (should (equal (org-tickets-test--pull-inlines
                  (org-tickets-test--text "t" (org-tickets-test--mark
                                               "link" '(("title" . "x")))))
                 "t")))

(ert-deftest org-tickets-test--adf-import-unknown-mark-keeps-text ()
  "An unknown mark is dropped; its text and the other marks are kept."
  (should (equal (org-tickets-test--pull-inlines
                  (org-tickets-test--text "t"
                                          (org-tickets-test--mark
                                           "textColor" '(("color" . "#ff0000")))
                                          (org-tickets-test--mark "strong")))
                 "*t*")))

(ert-deftest org-tickets-test--adf-import-text-node-without-text ()
  "A text node with no text imports as nothing, marks or not."
  (should (equal (org-tickets-test--pull-inlines
                  (org-tickets-test--text "a")
                  (org-tickets-test--node "text")
                  (org-tickets-test--node "text" "marks"
                                          (list (org-tickets-test--mark "strong")))
                  (org-tickets-test--text "b"))
                 "ab")))

(ert-deftest org-tickets-test--adf-import-mark-on-empty-text-emits-no-markup ()
  "Marks on empty text emit no bare markers such as **."
  (should (equal (org-tickets-test--pull-inlines
                  (org-tickets-test--text "a")
                  (org-tickets-test--text "" (org-tickets-test--mark "strong")
                                          (org-tickets-test--mark
                                           "link" '(("href" . "https://x.test"))))
                  (org-tickets-test--text "b"))
                 "ab")))

(ert-deftest org-tickets-test--adf-import-plain-text-markup-is-verbatim ()
  "Plain text that looks like org markup is imported verbatim, unescaped.
Org has no escape for emphasis markers short of inserting zero-width
spaces, which the exporter would then send to Jira.  So text such as
\"/x/\" or \"[[x]]\" with no marks becomes formatting on the next push:
a known limitation.  Intra-word markers such as a*b*c are not org
emphasis, so they do survive a round trip as plain text."
  (should (equal (org-tickets-test--pull-inlines
                  (org-tickets-test--text "a*b*c see /x/ and [[x]]"))
                 "a*b*c see /x/ and [[x]]"))
  (should (equal (org-tickets-test--roundtrip "a*b*c") "a*b*c")))

;;;; Code blocks and quotes

(ert-deftest org-tickets-test--adf-import-empty-code-block-and-quote ()
  "An empty codeBlock and blockquote import as empty org blocks."
  (should (equal (org-tickets-test--pull-blocks
                  (org-tickets-test--node "codeBlock")
                  (org-tickets-test--node "blockquote"))
                 "#+BEGIN_SRC\n\n#+END_SRC\n\n#+BEGIN_QUOTE\n\n#+END_QUOTE")))

;;;; Lists

(ert-deftest org-tickets-test--adf-import-list-item-with-two-paragraphs ()
  "A second paragraph in a list item is indented under the item."
  (should (equal (org-tickets-test--pull-blocks
                  (org-tickets-test--node
                   "bulletList" "content"
                   (list (org-tickets-test--item (org-tickets-test--adf-para "a")
                                                 (org-tickets-test--adf-para "b")))))
                 "- a\n\n  b")))

(ert-deftest org-tickets-test--adf-import-blocks-inside-list-item ()
  "A code block, quote and table inside an item are indented under it."
  (should (equal (org-tickets-test--pull-blocks
                  (org-tickets-test--node
                   "orderedList" "content"
                   (list (org-tickets-test--item
                          (org-tickets-test--adf-para "a")
                          (org-tickets-test--node
                           "codeBlock" "content"
                           (list (org-tickets-test--text "x\ny")))
                          (org-tickets-test--node
                           "blockquote" "content"
                           (list (org-tickets-test--adf-para "q")))
                          (org-tickets-test--node
                           "table" "content"
                           (list (org-tickets-test--row
                                  (org-tickets-test--cell "tableCell" "c"))))))))
                 (concat "1. a\n\n"
                         "   #+BEGIN_SRC\n   x\n   y\n   #+END_SRC\n\n"
                         "   #+BEGIN_QUOTE\n   q\n   #+END_QUOTE\n\n"
                         "   | c |"))))

(ert-deftest org-tickets-test--adf-import-bullets-under-ordered-list-with-order ()
  "Bullets nested in an ordered list starting at 9 indent past \"10. \"."
  (should (equal (org-tickets-test--pull-blocks
                  (org-tickets-test--node
                   "orderedList" "attrs" '(("order" . 9))
                   "content"
                   (list (org-tickets-test--item (org-tickets-test--adf-para "a"))
                         (org-tickets-test--item
                          (org-tickets-test--adf-para "b")
                          (org-tickets-test--node
                           "bulletList" "content"
                           (list (org-tickets-test--item
                                  (org-tickets-test--adf-para "c"))))))))
                 "9. a\n10. b\n    - c")))

(ert-deftest org-tickets-test--adf-import-checkbox-and-description-items ()
  "List items whose text is \"[X] done\" or \"Term :: def\" import as
org checkbox and description items."
  (should (equal (org-tickets-test--pull-blocks
                  (org-tickets-test--node
                   "bulletList" "content"
                   (list (org-tickets-test--item (org-tickets-test--adf-para "[X] done"))
                         (org-tickets-test--item (org-tickets-test--adf-para "[ ] todo"))
                         (org-tickets-test--item
                          (org-tickets-test--adf-para "Term :: def")))))
                 "- [X] done\n- [ ] todo\n- Term :: def")))

(provide 'org-tickets-test-import-adf-nodes)

;;; org-tickets-test-import-adf-nodes.el ends here
