;;; org-tickets-test-roundtrip.el --- org<->ADF round-trip tests  -*- lexical-binding: t; -*-

;;; Commentary:
;; Round-trip guarantees: pushing what import produced must preserve the
;; text (org -> ADF -> org fixpoint after one cycle), so a pull+push
;; cycle can never destroy Jira content.

;;; Code:

(require 'ert)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

(defun org-tickets-test--roundtrip (org-text)
  "Push ORG-TEXT to ADF, encode/decode as the API would, pull it back."
  (let ((adf (org-tickets--build-adf-description org-text)))
    (should adf)
    ;; Serialize through JSON so the pull side sees symbol keys,
    ;; exactly like a real GET response.
    (org-tickets--parse-adf-description
     (org-tickets-test--json (json-encode adf)))))

(ert-deftest org-tickets-test--roundtrip-paragraphs ()
  (should (equal (org-tickets-test--roundtrip "one\n\ntwo") "one\n\ntwo")))

(ert-deftest org-tickets-test--roundtrip-multiline-paragraph ()
  (should (equal (org-tickets-test--roundtrip "line1\nline2") "line1\nline2")))

(ert-deftest org-tickets-test--roundtrip-sub-superscript ()
  (should (equal (org-tickets-test--roundtrip "H_{2}O and x^{2}")
                 "H_{2}O and x^{2}")))

(ert-deftest org-tickets-test--roundtrip-unbraced-underscore-literal ()
  (should (equal (org-tickets-test--roundtrip "release/26_02 works")
                 "release/26_02 works")))

(ert-deftest org-tickets-test--roundtrip-bullet-list ()
  (should (equal (org-tickets-test--roundtrip "- alpha\n- beta")
                 "- alpha\n- beta")))

(ert-deftest org-tickets-test--roundtrip-nested-bullet-list ()
  (should (equal (org-tickets-test--roundtrip "- first\n  - nested")
                 "- first\n  - nested")))

(ert-deftest org-tickets-test--roundtrip-ordered-list ()
  (should (equal (org-tickets-test--roundtrip "1. one\n2. two")
                 "1. one\n2. two")))

(ert-deftest org-tickets-test--roundtrip-code-block ()
  (should (equal (org-tickets-test--roundtrip
                  "#+BEGIN_SRC python\nx = 1\n#+END_SRC")
                 "#+BEGIN_SRC python\nx = 1\n#+END_SRC")))

(ert-deftest org-tickets-test--roundtrip-quote-block ()
  (should (equal (org-tickets-test--roundtrip
                  "#+BEGIN_QUOTE\nquoted text\n#+END_QUOTE")
                 "#+BEGIN_QUOTE\nquoted text\n#+END_QUOTE")))

(ert-deftest org-tickets-test--roundtrip-horizontal-rule ()
  (should (equal (org-tickets-test--roundtrip "before\n\n-----\n\nafter")
                 "before\n\n-----\n\nafter")))

(ert-deftest org-tickets-test--roundtrip-inline-marks ()
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
