;;; org-tickets-test-ordered-start.el --- Ordered list start numbers  -*- lexical-binding: t; -*-

;;; Commentary:

;; An org ordered list keeps its start number through Jira: the first
;; item's [@N] counter, else its bullet number, pushes as the ADF
;; orderedList "order" attribute, and pulls back as the first marker.

;;; Code:

(require 'ert)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; Helpers

(defun org-tickets-test--list-orders (org-text)
  "Return (TYPE . ORDER) for every list pushed for ORG-TEXT, outermost first.
ORDER is the \"order\" attribute, or nil when absent."
  (let ((found nil))
    (named-let walk ((nodes (cdr (assoc "content"
                                        (org-tickets--build-adf-description org-text)))))
      (dolist (node nodes)
        (let ((type (cdr (assoc "type" node))))
          (when (member type '("orderedList" "bulletList"))
            (push (cons type (cdr (assoc "order" (cdr (assoc "attrs" node))))) found)))
        (walk (cdr (assoc "content" node)))))
    (nreverse found)))

;;;; Push

(ert-deftest org-tickets-test--ordered-start-from-bullet ()
  (should (equal (org-tickets-test--list-orders "4. a\n5. b")
                 '(("orderedList" . 4)))))

(ert-deftest org-tickets-test--ordered-start-one-has-no-attr ()
  "A list starting at 1 pushes exactly as before, with no attrs."
  (let ((list-node (car (cdr (assoc "content" (org-tickets--build-adf-description "1. a\n2. b"))))))
    (should (equal (cdr (assoc "type" list-node)) "orderedList"))
    (should-not (assoc "attrs" list-node))))

(ert-deftest org-tickets-test--ordered-start-paren-bullet ()
  (should (equal (org-tickets-test--list-orders "3) a\n4) b")
                 '(("orderedList" . 3)))))

(ert-deftest org-tickets-test--ordered-start-zero ()
  (should (equal (org-tickets-test--list-orders "0. a\n1. b")
                 '(("orderedList" . 0)))))

(ert-deftest org-tickets-test--ordered-start-multi-digit ()
  (should (equal (org-tickets-test--list-orders "100. a\n101. b")
                 '(("orderedList" . 100)))))

(ert-deftest org-tickets-test--ordered-start-counter-cookie ()
  "A [@N] cookie on the first item sets the start."
  (should (equal (org-tickets-test--list-orders "1. [@7] a\n2. b")
                 '(("orderedList" . 7)))))

(ert-deftest org-tickets-test--ordered-start-counter-beats-bullet ()
  (should (equal (org-tickets-test--list-orders "4. [@9] a")
                 '(("orderedList" . 9)))))

(ert-deftest org-tickets-test--ordered-start-cookie-not-in-text ()
  "The [@N] cookie is not pushed as item text."
  (should (equal (org-tickets-test--inline-summary "1. [@7] a") '("a"))))

(ert-deftest org-tickets-test--ordered-start-only-first-item-counts ()
  "Bullets after the first do not change the start."
  (should (equal (org-tickets-test--list-orders "2. a\n9. b")
                 '(("orderedList" . 2)))))

(ert-deftest org-tickets-test--ordered-start-bullet-list-has-no-order ()
  (should (equal (org-tickets-test--list-orders "- a\n- b")
                 '(("bulletList")))))

(ert-deftest org-tickets-test--ordered-start-alphabetical-list ()
  "An alphabetical list without a cookie has no numeric start."
  (let ((org-list-allow-alphabetical t))
    (should (equal (org-tickets-test--list-orders "c. a\nd. b")
                   '(("orderedList"))))))

(ert-deftest org-tickets-test--ordered-start-nested-in-bullet ()
  (should (equal (org-tickets-test--list-orders "- outer\n  3. in\n  4. in2")
                 '(("bulletList") ("orderedList" . 3)))))

(ert-deftest org-tickets-test--ordered-start-nested-in-ordered ()
  (should (equal (org-tickets-test--list-orders "4. outer\n   7. in\n   8. in2")
                 '(("orderedList" . 4) ("orderedList" . 7)))))

(ert-deftest org-tickets-test--ordered-start-reported-item ()
  "The reported item, numbered 4, keeps its number."
  (should (equal (org-tickets-test--list-orders
                  (concat "4" (substring org-tickets-test--reported-item 1)))
                 '(("orderedList" . 4)))))

(ert-deftest org-tickets-test--ordered-start-under-description-heading ()
  (should (equal (org-tickets-test--list-orders "*** Steps\n5. a\n6. b")
                 '(("orderedList" . 5)))))

;;;; Pull

(ert-deftest org-tickets-test--ordered-start-pull-order ()
  (should (equal (org-tickets-test--pull
                  "{\"type\":\"doc\",\"content\":[{\"type\":\"orderedList\",\"attrs\":{\"order\":4},
                    \"content\":[
                     {\"type\":\"listItem\",\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"a\"}]}]},
                     {\"type\":\"listItem\",\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"b\"}]}]}]}]}")
                 "4. a\n5. b")))

(ert-deftest org-tickets-test--ordered-start-pull-no-attrs-is-one ()
  (should (equal (org-tickets-test--pull
                  "{\"type\":\"doc\",\"content\":[{\"type\":\"orderedList\",\"content\":[
                     {\"type\":\"listItem\",\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"a\"}]}]}]}]}")
                 "1. a")))

(ert-deftest org-tickets-test--ordered-start-pull-zero ()
  (should (equal (org-tickets-test--pull
                  "{\"type\":\"doc\",\"content\":[{\"type\":\"orderedList\",\"attrs\":{\"order\":0},\"content\":[
                     {\"type\":\"listItem\",\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"a\"}]}]}]}]}")
                 "0. a")))

(ert-deftest org-tickets-test--ordered-start-pull-wide-marker-continuation ()
  "Continuations align under a wide marker's text."
  (should (equal (org-tickets-test--pull
                  "{\"type\":\"doc\",\"content\":[{\"type\":\"orderedList\",\"attrs\":{\"order\":10},\"content\":[
                     {\"type\":\"listItem\",\"content\":[{\"type\":\"paragraph\",\"content\":[
                       {\"type\":\"text\",\"text\":\"a\"},{\"type\":\"hardBreak\"},{\"type\":\"text\",\"text\":\"b\"}]}]}]}]}")
                 "10. a\n    b")))

(ert-deftest org-tickets-test--ordered-start-pull-bullet-list-ignores-order ()
  "An order attribute on a bulletList does not produce numbers."
  (should (equal (org-tickets-test--pull
                  "{\"type\":\"doc\",\"content\":[{\"type\":\"bulletList\",\"attrs\":{\"order\":4},\"content\":[
                     {\"type\":\"listItem\",\"content\":[{\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"a\"}]}]}]}]}")
                 "- a")))

;;;; Round trips

(ert-deftest org-tickets-test--ordered-start-roundtrips ()
  "Start numbers survive repeated pull/push cycles."
  (dolist (text '("4. a\n5. b"
                  "0. a\n1. b"
                  "100. a\n101. b"
                  "10. a\n    b\n11. c"
                  "- outer\n  3. in\n  4. in2"
                  "4. outer\n   7. in\n   8. in2"
                  "*** Steps\n\n5. a\n6. b"))
    (should (equal (org-tickets-test--roundtrip-n text 3) text))))

(ert-deftest org-tickets-test--ordered-start-roundtrip-reported-item ()
  (let ((text (concat "4" (substring org-tickets-test--reported-item 1))))
    (should (equal (org-tickets-test--roundtrip-n text 3) text))))

(ert-deftest org-tickets-test--ordered-start-cookie-normalizes ()
  "A [@N] cookie comes back as plain numbering, then stays fixed."
  (let ((once (org-tickets-test--roundtrip "1. [@7] a\n2. b")))
    (should (equal once "7. a\n8. b"))
    (should (equal (org-tickets-test--roundtrip once) once))))

(ert-deftest org-tickets-test--ordered-start-paren-normalizes ()
  "Paren bullets come back as dot bullets with the same numbers."
  (should (equal (org-tickets-test--roundtrip "3) a\n4) b") "3. a\n4. b")))

(ert-deftest org-tickets-test--ordered-start-mid-list-counter-is-lost ()
  "Known limitation: ADF has one start per list, so a [@N] cookie after
the first item is dropped and numbering continues."
  (should (equal (org-tickets-test--roundtrip "1. a\n2. [@5] b") "1. a\n2. b")))

(provide 'org-tickets-test-ordered-start)
;;; org-tickets-test-ordered-start.el ends here
