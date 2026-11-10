;;; org-tickets-test-macro.el --- Tests for org-tickets org-macro handling  -*- lexical-binding: t; -*-

;; Copyright (C) 2024

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

;; Tests for org-tickets org-macro handling (regression tests).
;; These tests verify that org macros like {{{my-macro}}} are correctly
;; parsed and processed, and that undefined macros don't appear as
;; literal {{{...}}} in Jira output.

;;; Code:

(require 'ert)
(require 'org)
(require 'org-element)

(require 'org-tickets)
(require 'org-tickets-test-fixtures)

(defvar org-tickets-test--macro-ran nil
  "Set when a test's (eval ...) macro body runs.")

(ert-deftest org-tickets-test--undefined-macro-not-kept-as-literal-in-adf ()
  "An undefined macro does not appear as literal {{{...}}} in ADF output,
and leaves no empty text node behind."
  (let ((content "Before {{{unknown-macro}}} after."))
    (let ((json-str (json-encode (org-tickets--build-adf-description content))))
      (should-not (string-match-p "{{{unknown-macro}}}" json-str))
      (should (string-match-p "Before" json-str))
      (should (string-match-p "after" json-str))
      ;; Jira rejects empty text nodes.
      (should-not (string-match-p "\"text\":\"\"" json-str)))))

(defun org-tickets-test--macro-text (org-text)
  "Return all ADF text pushed for ORG-TEXT concatenated into one string."
  (apply #'concat (org-tickets-test--adf-texts
                   (org-tickets-test--adf-blocks org-text))))

(ert-deftest org-tickets-test--global-macro-expands ()
  "A macro defined in the global `org-macro-templates' expands, with
its arguments substituted."
  (let ((org-macro-templates '(("greet" . "hello $1"))))
    (should (equal (org-tickets-test--macro-text "say {{{greet(world)}}} now")
                   "say hello world now"))))

(ert-deftest org-tickets-test--description-macro-expands ()
  "A #+MACRO defined in the description itself expands, and its
definition line pushes nothing."
  (should (equal (org-tickets-test--macro-text
                  "#+MACRO: greet hello $1\nsay {{{greet(world)}}} now")
                 "say hello world now")))

(ert-deftest org-tickets-test--description-macro-overrides-global ()
  "A description's own #+MACRO wins over a global one of the same name."
  (let ((org-macro-templates '(("greet" . "global"))))
    (should (equal (org-tickets-test--macro-text
                    "#+MACRO: greet local\n{{{greet}}}")
                   "local"))))

(ert-deftest org-tickets-test--description-eval-macro-never-runs ()
  "An (eval ...) #+MACRO in the description is never evaluated: the
text may have come from Jira, and pushing must not run its code."
  (let ((org-tickets-test--macro-ran nil))
    (should-not (string-match-p
                 "ran"
                 (org-tickets-test--macro-text
                  (concat "#+MACRO: boom (eval (progn (setq "
                          "org-tickets-test--macro-ran t) \"ran\"))\n"
                          "x {{{boom}}} y"))))
    (should-not org-tickets-test--macro-ran)))

(provide 'org-tickets-test-macro)

;;; org-tickets-test-macro.el ends here
