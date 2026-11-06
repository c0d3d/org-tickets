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

(provide 'org-tickets-test-macro)

;;; org-tickets-test-macro.el ends here
