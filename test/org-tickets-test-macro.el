;;; org-tickets-test-macro.el --- Tests for org-tickets org-macro handling  -*- lexical-binding: t; -*-

;; Copyright (C) 2024

;; Author: org-tickets contributors
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

;; Load the main library
(require 'org-tickets)

;;;; Tests for Org Macro Handling (Regression Tests)

(ert-deftest org-tickets-test--org-macro-element-detected ()
  "Test that org-macro elements are detected in the AST.
This verifies that macros like {{{my-macro}}} are parsed as macro elements
rather than plain text."
  (let ((content "Text before {{{test-macro}}} text after."))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (let ((ast (org-element-parse-buffer)))
        ;; Should find a macro element
        (let ((macros (org-element-map ast 'macro #'identity)))
          (should macros)
          (should (= 1 (length macros)))
          (let ((macro (car macros)))
            (should (string= (org-element-property :key macro) "test-macro"))))))))


(ert-deftest org-tickets-test--undefined-macro-not-kept-as-literal-in-adf ()
  "Test that undefined macros don't appear in ADF output.
This is a regression test - macros without templates were being passed
through as literal text in ADF format."
  (let ((content "Before {{{unknown-macro}}} after."))
    (with-temp-buffer
      (insert content)
      (org-mode)
      (let ((adf (org-tickets--build-adf-description content)))
        (should adf)
        ;; Convert to JSON string to check content
        (let ((json-str (json-encode adf)))
          ;; Should NOT contain literal macro syntax
          (should-not (string-match-p "{{{unknown-macro}}}" json-str))
          ;; Should contain surrounding text
          (should (string-match-p "Before" json-str))
          (should (string-match-p "after" json-str))
          ;; And no empty text node may remain (Jira rejects them).
          (should-not (string-match-p "\"text\":\"\"" json-str)))))))

(provide 'org-tickets-test-macro)
;;; org-tickets-test-macro.el ends here