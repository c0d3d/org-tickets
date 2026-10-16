;;; org-tickets-test-convert-nodes.el --- Tests for ADF conversion of additional org node types  -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;;; Commentary:

;; Tests that previously-unhandled org element/object types convert to
;; faithful ADF instead of being silently dropped or losing formatting.
;;
;; Category A: constructs whose payload lives in :value/:raw-value and
;;   were dropped entirely (entity, timestamp, inline-src-block,
;;   example-block, fixed-width, horizontal-rule, statistics-cookie,
;;   latex-fragment, latex-environment, export-block, export-snippet).
;; Category B: constructs whose text survived but formatting was lost
;;   (strike-through, underline, quote-block, verse-block).

;;; Code:

(require 'ert)
(require 'org)
(require 'org-element)

(require 'org-tickets)

;;;; Helpers

(defun org-tickets-test--flatten-adf-text (adf-elements)
  "Extract all text content from ADF ELEMENTS, a list of content nodes.
Test-only helper: walks nested \"content\" the way an ADF renderer
would, returning the list of text strings regardless of which node
carries them.  Not a production function — org-tickets-convert.el has no
need to flatten ADF back to text."
  (mapcan (lambda (elem)
            (when (listp elem)
              (let ((text (cdr (assoc "text" elem))))
                (if text
                    (list text)
                  (let ((content (cdr (assoc "content" elem))))
                    (when content
                      (org-tickets-test--flatten-adf-text content)))))))
          adf-elements))

(defun org-tickets-test--adf-top-content (content)
  "Return the top-level ADF content node list for org CONTENT string."
  (cdr (assoc "content" (org-tickets--build-adf-description content))))

(defun org-tickets-test--adf-flat-text (content)
  "Return all ADF text for org CONTENT string concatenated into one string."
  (apply #'concat
         (org-tickets-test--flatten-adf-text (org-tickets-test--adf-top-content content))))

(defun org-tickets-test--first-paragraph-nodes (content)
  "Return the inline node list of the first paragraph for org CONTENT."
  (cdr (assoc "content" (car (org-tickets-test--adf-top-content content)))))

(defun org-tickets-test--node-mark-types (node)
  "Return the list of ADF mark type strings on NODE."
  (mapcar (lambda (m) (cdr (assoc "type" m))) (cdr (assoc "marks" node))))

;;;; Category A: dropped content

(ert-deftest org-tickets-test--adf-entity-renders-utf8 ()
  "An org entity such as \\alpha renders as its UTF-8 character, not dropped."
  (let ((all (org-tickets-test--adf-flat-text "alpha \\alpha done")))
    (should (string-match-p "α" all))
    (should (string-match-p "alpha α done" all))))

(ert-deftest org-tickets-test--adf-timestamp-preserved ()
  "A timestamp keeps its literal raw value instead of being dropped."
  (should (string-match-p "<2026-07-28 Tue>"
                          (org-tickets-test--adf-flat-text "due <2026-07-28 Tue>"))))

(ert-deftest org-tickets-test--adf-inline-src-block-code-mark ()
  "Inline source keeps its code and gets a code mark."
  (let* ((nodes (org-tickets-test--first-paragraph-nodes "run src_python{print(1)} now"))
         (node (seq-find (lambda (n)
                           (string-prefix-p "print(1)" (or (cdr (assoc "text" n)) "")))
                         nodes)))
    (should node)
    (should (member "code" (org-tickets-test--node-mark-types node)))))

(ert-deftest org-tickets-test--adf-code-mark-excludes-trailing-space ()
  "The code mark covers only the code, never the trailing space.
Regression: org stores the space after ~code~ in :post-blank; it must be
re-emitted as a separate unmarked text node so Jira does not render the
backtick styling over the trailing space."
  (dolist (case '(("This is ~code~ text" . "code")
                  ("This is =verbatim= text" . "verbatim")
                  ("run src_python{print(1)} now" . "print(1)")))
    (let* ((nodes (org-tickets-test--first-paragraph-nodes (car case)))
           (node (seq-find
                  (lambda (n)
                    (member "code" (org-tickets-test--node-mark-types n)))
                  nodes)))
      (should node)
      ;; The code-marked node holds exactly the code, no trailing space.
      (should (equal (cdr (assoc "text" node)) (cdr case))))))

(ert-deftest org-tickets-test--adf-example-block-code-block ()
  "An example block becomes a codeBlock preserving its interior lines."
  (let ((block (car (org-tickets-test--adf-top-content
                     "#+begin_example\nkeep me\nline2\n#+end_example"))))
    (should (equal (cdr (assoc "type" block)) "codeBlock"))
    (should (equal (cdr (assoc "text" (car (cdr (assoc "content" block)))))
                   "keep me\nline2"))))

(ert-deftest org-tickets-test--adf-fixed-width-code-block ()
  "Fixed-width (colon) lines become a codeBlock, not dropped."
  (let* ((block (car (org-tickets-test--adf-top-content ": colon one\n: colon two")))
         (text (cdr (assoc "text" (car (cdr (assoc "content" block)))))))
    (should (equal (cdr (assoc "type" block)) "codeBlock"))
    (should (string-match-p "colon one" text))
    (should (string-match-p "colon two" text))))

(ert-deftest org-tickets-test--adf-horizontal-rule ()
  "A horizontal rule becomes an ADF rule node, not dropped."
  (let ((types (mapcar (lambda (n) (cdr (assoc "type" n)))
                       (org-tickets-test--adf-top-content "above\n\n-----\n\nbelow"))))
    (should (member "rule" types))))

(ert-deftest org-tickets-test--adf-statistics-cookie-preserved ()
  "A statistics cookie keeps its literal value."
  (should (string-match-p "\\[1/2\\]"
                          (org-tickets-test--adf-flat-text "task [1/2] here"))))

(ert-deftest org-tickets-test--adf-latex-fragment-preserved ()
  "A latex fragment keeps its literal source instead of being dropped."
  (should (string-match-p "\\$x\\^2\\$"
                          (org-tickets-test--adf-flat-text "eq $x^2$ end"))))

(ert-deftest org-tickets-test--adf-latex-environment-code-block ()
  "A latex environment becomes a codeBlock preserving its source."
  (let* ((block (car (org-tickets-test--adf-top-content
                      "\\begin{equation}\nx=1\n\\end{equation}")))
         (text (cdr (assoc "text" (car (cdr (assoc "content" block)))))))
    (should (equal (cdr (assoc "type" block)) "codeBlock"))
    (should (string-match-p "\\\\begin{equation}" text))
    (should (string-match-p "x=1" text))))

(ert-deftest org-tickets-test--adf-export-block-code-block ()
  "An export block becomes a codeBlock preserving its body."
  (let* ((block (car (org-tickets-test--adf-top-content
                      "#+begin_export html\n<b>hi</b>\n#+end_export")))
         (text (cdr (assoc "text" (car (cdr (assoc "content" block)))))))
    (should (equal (cdr (assoc "type" block)) "codeBlock"))
    (should (string-match-p "<b>hi</b>" text))))

(ert-deftest org-tickets-test--adf-export-snippet-preserved ()
  "An inline export snippet keeps its literal body."
  (should (string-match-p "<b>hi</b>"
                          (org-tickets-test--adf-flat-text "text @@html:<b>hi</b>@@ more"))))

;;;; Category B: formatting lost

(ert-deftest org-tickets-test--adf-strike-through-mark ()
  "Strike-through text carries an ADF strike mark."
  (let* ((nodes (org-tickets-test--first-paragraph-nodes "a +struck+ b"))
         (node (seq-find (lambda (n)
                           (string-prefix-p "struck" (or (cdr (assoc "text" n)) "")))
                         nodes)))
    (should node)
    (should (member "strike" (org-tickets-test--node-mark-types node)))))

(ert-deftest org-tickets-test--adf-underline-mark ()
  "Underlined text carries an ADF underline mark."
  (let* ((nodes (org-tickets-test--first-paragraph-nodes "a _under_ b"))
         (node (seq-find (lambda (n)
                           (string-prefix-p "under" (or (cdr (assoc "text" n)) "")))
                         nodes)))
    (should node)
    (should (member "underline" (org-tickets-test--node-mark-types node)))))

(defun org-tickets-test--subsup-node (content text)
  "Return the first-paragraph node for org CONTENT whose text is TEXT."
  (seq-find (lambda (n) (equal (cdr (assoc "text" n)) text))
            (org-tickets-test--first-paragraph-nodes content)))

(ert-deftest org-tickets-test--adf-braced-subscript-mark ()
  "A braced subscript like H_{2}O carries an ADF subsup mark of type sub."
  (let ((node (org-tickets-test--subsup-node "H_{2}O" "2")))
    (should node)
    (should (equal (cdr (assoc "marks" node))
                   '((("type" . "subsup") ("attrs" ("type" . "sub"))))))))

(ert-deftest org-tickets-test--adf-braced-superscript-mark ()
  "A braced superscript like x^{2} carries an ADF subsup mark of type sup."
  (let ((node (org-tickets-test--subsup-node "x^{2} here" "2")))
    (should node)
    (should (equal (cdr (assoc "marks" node))
                   '((("type" . "subsup") ("attrs" ("type" . "sup"))))))
    (should (equal (org-tickets-test--adf-flat-text "x^{2} here") "x2 here"))))

(ert-deftest org-tickets-test--adf-quote-block-blockquote ()
  "A quote block becomes an ADF blockquote wrapping its paragraphs."
  (let ((block (car (org-tickets-test--adf-top-content
                     "#+begin_quote\nquoted line\n#+end_quote"))))
    (should (equal (cdr (assoc "type" block)) "blockquote"))
    (should (string-match-p
             "quoted line"
             (apply #'concat (org-tickets-test--flatten-adf-text (list block)))))))

(ert-deftest org-tickets-test--adf-verse-block-preserves-lines ()
  "A verse block becomes a paragraph whose interior newlines are hardBreaks."
  (let* ((para (car (org-tickets-test--adf-top-content
                     "#+begin_verse\nline a\nline b\n#+end_verse")))
         (nodes (cdr (assoc "content" para)))
         (types (mapcar (lambda (n) (cdr (assoc "type" n))) nodes))
         (texts (delq nil (mapcar (lambda (n) (cdr (assoc "text" n))) nodes))))
    (should (equal (cdr (assoc "type" para)) "paragraph"))
    (should (member "hardBreak" types))
    (should (member "line a" texts))
    (should (member "line b" texts))))

;;;; ADF node constructors

(ert-deftest org-tickets-test--adf-text-node-drops-empty ()
  "Jira rejects empty text nodes; the constructor must not emit them."
  (should (null (org-tickets--adf-text-node "")))
  (should (null (org-tickets--adf-text-node nil)))
  (should (equal (org-tickets--adf-text-node "x")
                 '((("type" . "text") ("text" . "x"))))))

(ert-deftest org-tickets-test--adf-node-shape ()
  (should (equal (org-tickets--adf-node "rule") '(("type" . "rule"))))
  (should (equal (org-tickets--adf-node "codeBlock"
                                     (list (cons "language" "el"))
                                     (org-tickets--adf-text-node "x"))
                 '(("type" . "codeBlock")
                   ("attrs" . (("language" . "el")))
                   ("content" . ((("type" . "text") ("text" . "x"))))))))

(ert-deftest org-tickets-test--adf-add-mark-layers-marks ()
  (let ((nodes (append (org-tickets--adf-text-node "a" "strong")
                       (list '(("type" . "hardBreak")))
                       (org-tickets--adf-text-node "b"))))
    (let ((marked (org-tickets--adf-add-mark nodes '(("type" . "em")))))
      ;; text nodes gain em on top of existing marks; hardBreak untouched.
      (should (equal (cdr (assoc "marks" (nth 0 marked)))
                     '((("type" . "strong")) (("type" . "em")))))
      (should (equal (nth 1 marked) '(("type" . "hardBreak"))))
      (should (equal (cdr (assoc "marks" (nth 2 marked)))
                     '((("type" . "em"))))))))

(provide 'org-tickets-test-convert-nodes)

;;; org-tickets-test-convert-nodes.el ends here
