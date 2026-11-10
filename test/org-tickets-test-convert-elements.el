;;; org-tickets-test-convert-elements.el --- Tests for less common org elements in ADF  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Neil Locketz

;; Author: Neil Locketz <neil@nlocketz.com>
;; Keywords: org, jira, tests

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Tests for how `org-tickets--build-adf-description' handles list item
;; tags and checkboxes, links, edge-case tables, drawers, footnotes,
;; blocks, keywords, targets and the smaller converter branches.

;;; Code:

(require 'ert)
(require 'org)
(require 'org-element)
(require 'json)

(require 'org-tickets)
(require 'org-tickets-test-fixtures)

(defun org-tickets-test--flat-text (org-text)
  "Return all ADF text pushed for ORG-TEXT concatenated into one string."
  (apply #'concat (org-tickets-test--adf-texts
                   (org-tickets-test--adf-blocks org-text))))

(defun org-tickets-test--adf-json (org-text)
  "Return the JSON that would be sent for ORG-TEXT."
  (json-encode (org-tickets--build-adf-description org-text)))

;;;; List item tags and checkboxes

(ert-deftest org-tickets-test--list-tag-kept-as-text ()
  "A description list item keeps its term as \"Term :: def\"."
  (should (equal (org-tickets-test--flat-text "- Term :: def") "Term :: def")))

(ert-deftest org-tickets-test--list-checkbox-kept-as-text ()
  "Checkbox items keep their checkbox state as text."
  (should (equal (org-tickets-test--adf-outline "- [X] done\n- [ ] todo\n- [-] half")
                 '(("bulletList" . "[X] done[ ] todo[-] half")))))

(ert-deftest org-tickets-test--list-tag-keeps-markup ()
  "Markup inside a tag pushes as marked text before the separator."
  (let ((nodes (org-tickets-test--adf-first-paragraph "- *Term* :: def")))
    (should (equal (cdr (assoc "text" (car nodes))) "Term"))
    (should (equal (cdr (assoc "type" (car (cdr (assoc "marks" (car nodes))))))
                   "strong"))
    (should (equal (apply #'concat (org-tickets-test--adf-texts nodes))
                   "Term :: def"))))

(ert-deftest org-tickets-test--list-tag-without-body ()
  "A tagged item with no body still pushes its term."
  (should (equal (org-tickets-test--flat-text "- [X] Term ::") "[X] Term ::")))

(ert-deftest org-tickets-test--list-tag-and-checkbox-roundtrip ()
  "Tags and checkboxes come back from Jira as the same org text."
  (dolist (org '("- Term :: def"
                 "- [X] done\n- [ ] todo"
                 "- [X] Term :: def"))
    (should (equal (org-tickets-test--roundtrip org) org))))

;;;; Links

(ert-deftest org-tickets-test--bare-link-forms-push-as-linked-url ()
  "Plain, angle and bracket links without a description push the URL
as text carrying an href link mark."
  (dolist (org '("see https://x.test now"
                 "see <https://x.test> now"
                 "see [[https://x.test]] now"))
    (let ((link (seq-find (lambda (node)
                            (assoc "marks" node))
                          (org-tickets-test--adf-first-paragraph org))))
      (should (equal (cdr (assoc "text" link)) "https://x.test"))
      (should (equal (car (cdr (assoc "marks" link)))
                     '(("type" . "link")
                       ("attrs" ("href" . "https://x.test"))))))))

;;;; Tables

(ert-deftest org-tickets-test--separator-only-table-skipped ()
  "A table holding only rule rows pushes nothing, not an empty table."
  (should (equal (org-tickets-test--adf-outline "before\n\n|---|\n|---|\n\nafter")
                 '(("paragraph" . "before") ("paragraph" . "after")))))

(ert-deftest org-tickets-test--empty-table-cell-is-empty-paragraph ()
  "An empty cell holds a paragraph with no content, never an empty text node."
  (let* ((table (car (org-tickets-test--adf-blocks "| a | |")))
         (row (car (cdr (assoc "content" table))))
         (cell (nth 1 (cdr (assoc "content" row)))))
    (should (equal cell '(("type" . "tableCell")
                          ("content" (("type" . "paragraph"))))))
    (should-not (string-match-p "\"text\":\"\""
                                (org-tickets-test--adf-json "| a | |")))))

;;;; Elements the converter has no dedicated clause for

(ert-deftest org-tickets-test--drawers-do-not-leak ()
  "Drawer contents (clock lines, state notes, private notes) stay out."
  (should (equal (org-tickets-test--adf-outline
                  (concat "text\n:LOGBOOK:\n"
                          "- State \"DONE\" from \"TODO\" [2026-01-01 Thu 10:00]\n"
                          "CLOCK: [2026-01-01 Thu 10:00]--[2026-01-01 Thu 11:00] =>  1:00\n"
                          ":END:\n:NOTES:\nprivate\n:END:\nafter"))
                 '(("paragraph" . "text") ("paragraph" . "after")))))

(ert-deftest org-tickets-test--footnotes-keep-their-labels ()
  "Footnote references and definitions keep their [fn:N] labels."
  (should (equal (org-tickets-test--adf-outline "Foo[fn:1] bar\n\n[fn:1] note")
                 '(("paragraph" . "Foo[fn:1] bar")
                   ("paragraph" . "[fn:1] note")))))

(ert-deftest org-tickets-test--footnotes-roundtrip ()
  "Footnote references and definitions come back as the same org text."
  (let ((org "Foo[fn:1] bar\n\n[fn:1] note"))
    (should (equal (org-tickets-test--roundtrip org) org))))

(ert-deftest org-tickets-test--inline-footnote-keeps-text ()
  "An inline footnote keeps its delimiters and its text."
  (should (equal (org-tickets-test--flat-text "a [fn::side *note*] b")
                 "a [fn::side note] b")))

(ert-deftest org-tickets-test--center-and-special-blocks-keep-text ()
  "Center and custom (special) blocks push their contents as paragraphs."
  (should (equal (org-tickets-test--adf-outline
                  "#+BEGIN_CENTER\ncentered\n#+END_CENTER\n#+BEGIN_NOTE\nnoted\n#+END_NOTE")
                 '(("paragraph" . "centered") ("paragraph" . "noted")))))

(ert-deftest org-tickets-test--comments-and-keywords-dropped ()
  "Comment blocks, comment lines and keywords push nothing."
  (should (equal (org-tickets-test--adf-outline
                  (concat "#+TITLE: T\n#+BEGIN_COMMENT\nsecret\n#+END_COMMENT\n"
                          "# hidden\nvisible"))
                 '(("paragraph" . "visible")))))

(ert-deftest org-tickets-test--targets-keep-source-text ()
  "Targets and radio targets push as their literal source text."
  (should (equal (org-tickets-test--flat-text "a <<tgt>> b <<<radio>>> c")
                 "a <<tgt>> b <<<radio>>> c")))

(ert-deftest org-tickets-test--inline-babel-call-is-code ()
  "An inline babel call keeps its source text as code, spacing intact."
  (let ((nodes (org-tickets-test--adf-first-paragraph "x call_foo(a=1) y")))
    (should (equal (apply #'concat (org-tickets-test--adf-texts nodes))
                   "x call_foo(a=1) y"))
    (should (equal (cdr (assoc "marks" (nth 1 nodes)))
                   '((("type" . "code")))))))

;;;; Small converter branches

(ert-deftest org-tickets-test--src-block-without-language-is-text ()
  "A src block with no language is a codeBlock in language \"text\"."
  (should (equal (car (org-tickets-test--adf-blocks "#+BEGIN_SRC\nx\n#+END_SRC"))
                 '(("type" . "codeBlock") ("attrs" ("language" . "text"))
                   ("content" (("type" . "text") ("text" . "x")))))))

(ert-deftest org-tickets-test--export-block-without-type-is-text ()
  "An export block with no backend is a codeBlock in language \"text\"."
  (should (equal (car (org-tickets-test--adf-blocks
                       "#+BEGIN_EXPORT\nraw\n#+END_EXPORT"))
                 '(("type" . "codeBlock") ("attrs" ("language" . "text"))
                   ("content" (("type" . "text") ("text" . "raw")))))))

(ert-deftest org-tickets-test--entity-without-utf8-uses-name ()
  "An entity with no UTF-8 form falls back to its name."
  (should (equal (org-tickets--convert-to-adf-content
                  (org-element-create 'entity '(:name "foo" :post-blank 1)))
                 '((("type" . "text") ("text" . "foo "))))))

(ert-deftest org-tickets-test--unbraced-script-with-entity ()
  "An unbraced subscript holding an entity keeps the marker and the
entity's character as literal text."
  (should (equal (org-tickets-test--flat-text "a_\\alpha b") "a_α b")))

(provide 'org-tickets-test-convert-elements)
;;; org-tickets-test-convert-elements.el ends here
