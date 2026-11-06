;;; org-tickets-test-roundtrip.el --- org<->ADF round-trip tests  -*- lexical-binding: t; -*-

;;; Commentary:
;; Round-trip guarantees: pushing what import produced must preserve the
;; text (org -> ADF -> org fixpoint after one cycle), so a pull+push
;; cycle can never destroy Jira content.

;;; Code:

(require 'ert)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

(ert-deftest org-tickets-test--roundtrip-paragraphs ()
  "Two paragraphs survive push then pull unchanged."
  (should (equal (org-tickets-test--roundtrip "one\n\ntwo") "one\n\ntwo")))

(ert-deftest org-tickets-test--roundtrip-multiline-paragraph ()
  "A paragraph with a soft line break survives push then pull unchanged."
  (should (equal (org-tickets-test--roundtrip "line1\nline2") "line1\nline2")))

(ert-deftest org-tickets-test--roundtrip-sub-superscript ()
  "Braced subscripts and superscripts survive push then pull unchanged."
  (should (equal (org-tickets-test--roundtrip "H_{2}O and x^{2}")
                 "H_{2}O and x^{2}")))

(ert-deftest org-tickets-test--roundtrip-unbraced-underscore-literal ()
  "An unbraced underscore stays literal through push then pull."
  (should (equal (org-tickets-test--roundtrip "release/26_02 works")
                 "release/26_02 works")))

(ert-deftest org-tickets-test--roundtrip-bullet-list ()
  "A bullet list survives push then pull unchanged."
  (should (equal (org-tickets-test--roundtrip "- alpha\n- beta")
                 "- alpha\n- beta")))

(ert-deftest org-tickets-test--roundtrip-nested-bullet-list ()
  "A nested bullet list survives push then pull unchanged."
  (should (equal (org-tickets-test--roundtrip "- first\n  - nested")
                 "- first\n  - nested")))

(ert-deftest org-tickets-test--roundtrip-ordered-list ()
  "An ordered list survives push then pull unchanged."
  (should (equal (org-tickets-test--roundtrip "1. one\n2. two")
                 "1. one\n2. two")))

(ert-deftest org-tickets-test--roundtrip-code-block ()
  "A src block with a language survives push then pull unchanged."
  (should (equal (org-tickets-test--roundtrip
                  "#+BEGIN_SRC python\nx = 1\n#+END_SRC")
                 "#+BEGIN_SRC python\nx = 1\n#+END_SRC")))

(ert-deftest org-tickets-test--roundtrip-quote-block ()
  "A quote block survives push then pull unchanged."
  (should (equal (org-tickets-test--roundtrip
                  "#+BEGIN_QUOTE\nquoted text\n#+END_QUOTE")
                 "#+BEGIN_QUOTE\nquoted text\n#+END_QUOTE")))

(ert-deftest org-tickets-test--roundtrip-horizontal-rule ()
  "A horizontal rule between paragraphs survives push then pull unchanged."
  (should (equal (org-tickets-test--roundtrip "before\n\n-----\n\nafter")
                 "before\n\n-----\n\nafter")))

(ert-deftest org-tickets-test--roundtrip-inline-marks ()
  "Bold, italic and code marks survive push then pull unchanged."
  (should (equal (org-tickets-test--roundtrip "*bold* and /italic/ and ~code~")
                 "*bold* and /italic/ and ~code~")))

(ert-deftest org-tickets-test--roundtrip-header-table ()
  "A header table (rule row after row 0) survives pull+push: the
tableHeader cells import back as an org rule row rather than being
demoted to a plain data table."
  (should (equal (org-tickets-test--roundtrip
                  "| Name | Age |\n|---+---|\n| Ann | 4 |")
                 "| Name | Age |\n|---+---|\n| Ann | 4 |")))

(ert-deftest org-tickets-test--roundtrip-headings-with-body ()
  "Org headlines survive push+pull with their levels and bodies."
  (should (equal (org-tickets-test--roundtrip
                  "Intro.\n\n*** Top\n\nBody.\n\n**** Nested")
                 "Intro.\n\n*** Top\n\nBody.\n\n**** Nested")))

(provide 'org-tickets-test-roundtrip)
;;; org-tickets-test-roundtrip.el ends here
