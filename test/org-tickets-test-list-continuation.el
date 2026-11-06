;;; org-tickets-test-list-continuation.el --- Continuation-line indentation  -*- lexical-binding: t; -*-

;;; Commentary:

;; A paragraph line that continues the previous one (a list item's
;; second line, or an indented line in a plain paragraph) is indented
;; only for org layout.  That indentation must not be pushed as text
;; after the hardBreak: Jira would show it, and every pull would add
;; the item indent on top so it grew each round trip.

;;; Code:

(require 'ert)
(require 'seq)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; Push: no indentation after a line break

(ert-deftest org-tickets-test--continuation-reported-item ()
  "The reported item's second line pushes without its indentation."
  (let ((nodes (org-tickets-test--inline-summary org-tickets-test--reported-item)))
    (should (equal (car (last nodes 2)) 'br))
    (should (equal (car (last nodes))
                   "That signature should be done with ECDSA using SHA-384 and a Nist P-384 key."))))

(ert-deftest org-tickets-test--continuation-bullet-item ()
  "Check: continuation bullet item."
  (should (equal (org-tickets-test--inline-summary "- a\n  b")
                 '("a" br "b"))))

(ert-deftest org-tickets-test--continuation-ordered-item-wide-marker ()
  "A two-digit marker indents continuations by four; none of it is text."
  (should (equal (org-tickets-test--inline-summary
                  "1. x\n2. x\n3. x\n4. x\n5. x\n6. x\n7. x\n8. x\n9. x\n10. a\n    b")
                 '("x"))))

(ert-deftest org-tickets-test--continuation-wide-marker-item-text ()
  "The tenth item's continuation pushes as plain \"b\"."
  (let* ((adf (org-tickets--build-adf-description "10. a\n    b"))
         (item (car (cdr (assoc "content" (car (cdr (assoc "content" adf)))))))
         (para (car (cdr (assoc "content" item)))))
    (should (equal (mapcar (lambda (n) (or (cdr (assoc "text" n)) 'br))
                           (cdr (assoc "content" para)))
                   '("a" br "b")))))

(ert-deftest org-tickets-test--continuation-several-lines ()
  "Check: continuation several lines."
  (should (equal (org-tickets-test--inline-summary "- a\n  b\n  c\n  d")
                 '("a" br "b" br "c" br "d"))))

(ert-deftest org-tickets-test--continuation-nested-item ()
  "A nested item's continuation (deeper indent) is stripped too."
  (let* ((adf (org-tickets--build-adf-description "- outer\n  - inner\n    more"))
         (texts nil))
    (named-let walk ((nodes (cdr (assoc "content" adf))))
      (dolist (node nodes)
        (let ((text (cdr (assoc "text" node))))
          (when text (push text texts)))
        (walk (cdr (assoc "content" node)))))
    (should (equal (nreverse texts) '("outer" "inner" "more")))))

(ert-deftest org-tickets-test--continuation-starting-with-inline-code ()
  "A continuation that opens with markup loses only its indentation."
  (should (equal (org-tickets-test--inline-summary "- a\n  ~code~ after")
                 '("a" br "code" " " "after"))))

(ert-deftest org-tickets-test--continuation-tab-indent ()
  "Check: continuation tab indent."
  (should (equal (org-tickets-test--inline-summary "- a\n\tb")
                 '("a" br "b"))))

(ert-deftest org-tickets-test--continuation-plain-paragraph ()
  "An indented line inside a top-level paragraph is not pushed indented."
  (should (equal (org-tickets-test--inline-summary "first\n    second")
                 '("first" br "second"))))

(ert-deftest org-tickets-test--continuation-heading-section ()
  "Continuations in an item under a description heading are stripped."
  (let* ((adf (org-tickets--build-adf-description "*** H\n- a\n  b"))
         (list-node (cadr (cdr (assoc "content" adf))))
         (para (car (cdr (assoc "content" (car (cdr (assoc "content" list-node))))))))
    (should (equal (mapcar (lambda (n) (or (cdr (assoc "text" n)) 'br))
                           (cdr (assoc "content" para)))
                   '("a" br "b")))))

;;;; List items: block order and paragraph breaks

(defun org-tickets-test--first-item-blocks (org-text)
  "Return the block nodes of the first listItem pushed for ORG-TEXT."
  (let* ((adf (org-tickets--build-adf-description org-text))
         (list-node (car (cdr (assoc "content" adf))))
         (item (car (cdr (assoc "content" list-node)))))
    (cdr (assoc "content" item))))

(ert-deftest org-tickets-test--list-item-content-after-nested-list-keeps-order ()
  "Check: list item content after nested list keeps order."
  (let ((blocks (org-tickets-test--first-item-blocks
                 "- a\n  - nested\n\n  after nested\n- b")))
    (should (equal (mapcar (lambda (b) (cdr (assoc "type" b))) blocks)
                   '("paragraph" "bulletList" "paragraph")))
    (should (equal (org-tickets-test--block-text (car (last blocks)))
                   "after nested"))))

(ert-deftest org-tickets-test--list-item-second-paragraph-not-indented ()
  "Check: list item second paragraph not indented."
  (let ((blocks (org-tickets-test--first-item-blocks "- a\n\n  second para")))
    (should (equal (org-tickets-test--block-text (cadr blocks))
                   "second para"))))

(ert-deftest org-tickets-test--list-item-blocks-roundtrip-fixpoint ()
  "Check: list item blocks roundtrip fixpoint."
  (dolist (text '("- a\n\n  second para"
                  "- a\n  - nested\n\n  after nested\n- b"))
    (should (equal (org-tickets-test--roundtrip-n text 3) text))))

;;;; Push: spacing that is content is kept

(ert-deftest org-tickets-test--continuation-space-after-markup-kept ()
  "Spaces after an inline object on the same line are content."
  (should (equal (org-tickets-test--inline-summary "~a~ (b)")
                 '("a" " " "(b)"))))

(ert-deftest org-tickets-test--continuation-interior-spaces-kept ()
  "Runs of spaces inside a line are untouched."
  (should (equal (org-tickets-test--inline-summary "- a  b\n  c   d")
                 '("a  b" br "c   d"))))

;;;; Round trips are fixpoints

(ert-deftest org-tickets-test--continuation-roundtrip-reported-item ()
  "Check: continuation roundtrip reported item."
  (should (equal (org-tickets-test--roundtrip org-tickets-test--reported-item)
                 org-tickets-test--reported-item)))

(ert-deftest org-tickets-test--continuation-roundtrip-stable-over-cycles ()
  "Repeated pull/push cycles never grow indentation."
  (dolist (text '("- a\n  b"
                  "1. a\n   b\n   c"
                  "- outer\n  - inner\n    more"
                  "- a\n  ~code~ after"
                  "*** H\n\n- a\n  b"))
    (should (equal (org-tickets-test--roundtrip-n text 3) text))))

(ert-deftest org-tickets-test--continuation-legacy-indented-adf-heals ()
  "Jira text already carrying pushed indentation is fixed by one cycle."
  (let ((pulled (org-tickets--parse-adf-description
                 (org-tickets-test--json
                  "{\"type\":\"doc\",\"content\":[{\"type\":\"bulletList\",\"content\":[
                     {\"type\":\"listItem\",\"content\":[{\"type\":\"paragraph\",\"content\":[
                       {\"type\":\"text\",\"text\":\"a\"},{\"type\":\"hardBreak\"},
                       {\"type\":\"text\",\"text\":\"   b\"}]}]}]}]}"))))
    (should (equal (org-tickets-test--roundtrip pulled) "- a\n  b"))))

(provide 'org-tickets-test-list-continuation)
;;; org-tickets-test-list-continuation.el ends here
