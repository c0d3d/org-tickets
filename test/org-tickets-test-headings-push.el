;;; org-tickets-test-headings-push.el --- Description headings, org -> ADF  -*- lexical-binding: t; -*-

;;; Commentary:

;; Org headlines inside a ticket's description push as ADF headings:
;; `***' is h1 and each extra star one level deeper, clamped to h1..h6.
;; A ticket's description runs up to the first heading below it that is
;; itself a ticket (has JIRA_TYPE); every other heading is description.
;;
;; Covered for every ticket shape the importer produces: parents
;; (Feature, New Feature, Improvement, Epic) at `*', Stories at `**',
;; other children (Bug) at `*'.  Tickets deeper than that are rejected.

;;; Code:

(require 'ert)
(require 'seq)
(require 'org)
(require 'org-element)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; Helpers

;;;; Converter: level mapping

(ert-deftest org-tickets-test--headings-each-level-maps-to-h1-through-h6 ()
  "Stars 3..8 push as h1..h6."
  (should (equal (org-tickets-test--adf-outline
                  "*** A\n**** B\n***** C\n****** D\n******* E\n******** F")
                 '((1 . "A") (2 . "B") (3 . "C") (4 . "D") (5 . "E") (6 . "F")))))

(ert-deftest org-tickets-test--headings-deeper-than-h6-clamp ()
  "Anything below eight stars is still h6."
  (should (equal (org-tickets-test--adf-outline "********* Nine\n************ Twelve")
                 '((6 . "Nine") (6 . "Twelve")))))

(ert-deftest org-tickets-test--headings-shallower-than-three-stars-clamp-to-h1 ()
  "One- and two-star headlines in a description push as h1."
  (should (equal (org-tickets-test--adf-outline "* One\n** Two\n*** Three")
                 '((1 . "One") (1 . "Two") (1 . "Three")))))

(ert-deftest org-tickets-test--headings-skipped-levels-keep-their-own-level ()
  "Skipping from *** to ****** is h1 then h4; nothing is renumbered."
  (should (equal (org-tickets-test--adf-outline "*** Top\n****** Deep\n**** Mid")
                 '((1 . "Top") (4 . "Deep") (2 . "Mid")))))

(ert-deftest org-tickets-test--headings-siblings-at-same-level ()
  "Consecutive same-level headlines each become their own heading."
  (should (equal (org-tickets-test--adf-outline "*** A\n*** B\n*** C")
                 '((1 . "A") (1 . "B") (1 . "C")))))

(ert-deftest org-tickets-test--headings-going-back-up-a-level ()
  "Returning to a shallower level after nesting keeps document order."
  (should (equal (org-tickets-test--adf-outline
                  "*** A\n**** A.1\n***** A.1.a\n*** B\n**** B.1")
                 '((1 . "A") (2 . "A.1") (3 . "A.1.a") (1 . "B") (2 . "B.1")))))

;;;; Converter: bodies and ordering

(ert-deftest org-tickets-test--headings-intro-before-first-heading ()
  "Text before the first headline stays before the first heading."
  (should (equal (org-tickets-test--adf-outline "Intro.\n*** H\nBody.")
                 '(("paragraph" . "Intro.") (1 . "H") ("paragraph" . "Body.")))))

(ert-deftest org-tickets-test--headings-each-body-follows-its-heading ()
  "Every headline's section lands directly after its heading."
  (should (equal (org-tickets-test--adf-outline
                  "*** A\nA body.\n**** B\nB body.\n*** C\nC body.")
                 '((1 . "A") ("paragraph" . "A body.")
                   (2 . "B") ("paragraph" . "B body.")
                   (1 . "C") ("paragraph" . "C body.")))))

(ert-deftest org-tickets-test--headings-multiple-paragraphs-in-a-section ()
  "Blank-line separated paragraphs under a heading stay separate."
  (should (equal (org-tickets-test--adf-outline "*** H\none\n\ntwo")
                 '((1 . "H") ("paragraph" . "one") ("paragraph" . "two")))))

(ert-deftest org-tickets-test--headings-with-no-body ()
  "A headline with no section yields only the heading."
  (should (equal (org-tickets-test--adf-outline "*** Only")
                 '((1 . "Only")))))

(ert-deftest org-tickets-test--headings-body-block-types-are-preserved ()
  "Lists, src blocks, tables, quotes and rules convert under a heading."
  (should (equal (mapcar #'car
                         (org-tickets-test--adf-outline
                          (concat "*** H\n- item\n\n"
                                  "#+BEGIN_SRC sh\nls\n#+END_SRC\n\n"
                                  "| a | b |\n\n"
                                  "#+BEGIN_QUOTE\nq\n#+END_QUOTE\n\n"
                                  "-----")))
                 '(1 "bulletList" "codeBlock" "table" "blockquote" "rule"))))

(ert-deftest org-tickets-test--headings-blank-lines-around-headings ()
  "Blank lines around headlines do not add empty paragraphs."
  (should (equal (org-tickets-test--adf-outline "Intro.\n\n*** H\n\nBody.\n\n**** S\n\n")
                 '(("paragraph" . "Intro.") (1 . "H") ("paragraph" . "Body.")
                   (2 . "S")))))

;;;; Converter: headline decorations

(ert-deftest org-tickets-test--headings-todo-priority-and-tags-are-dropped ()
  "Only the title text is pushed, not TODO keyword, priority or tags."
  (should (equal (org-tickets-test--adf-outline "*** TODO [#A] Plan it   :work:urgent:")
                 '((1 . "Plan it")))))

(ert-deftest org-tickets-test--headings-done-keyword-is-dropped ()
  "A DONE keyword is not part of the heading text."
  (should (equal (org-tickets-test--adf-outline "*** DONE Finished")
                 '((1 . "Finished")))))

(ert-deftest org-tickets-test--headings-title-inline-marks ()
  "Bold, italic and code in a title carry the same marks as in a paragraph."
  (let* ((heading (car (org-tickets-test--adf-blocks "*** a *b* /c/ ~d~")))
         (para (car (org-tickets-test--adf-blocks "a *b* /c/ ~d~"))))
    (should (equal (cdr (assoc "content" heading))
                   (cdr (assoc "content" para))))))

(ert-deftest org-tickets-test--headings-title-link ()
  "A link in a title pushes as a link-marked text node."
  (let* ((heading (car (org-tickets-test--adf-blocks "*** See [[https://x.example][docs]]")))
         (link (seq-find (lambda (n) (equal (cdr (assoc "text" n)) "docs"))
                         (cdr (assoc "content" heading)))))
    (should (equal (org-tickets-test--adf-heading-level heading) 1))
    (should (equal (cdr (assoc "type" (car (cdr (assoc "marks" link))))) "link"))))

(ert-deftest org-tickets-test--headings-drawer-in-section-is-not-text ()
  "A property drawer under a description headline is not pushed as text."
  (should (equal (org-tickets-test--adf-outline
                  "*** H\n:PROPERTIES:\n:ID: abc\n:END:\nBody.")
                 '((1 . "H") ("paragraph" . "Body.")))))

(ert-deftest org-tickets-test--headings-star-lines-that-are-not-headlines ()
  "Bold text at line start and an escaped star line stay paragraphs."
  (should (equal (mapcar #'car (org-tickets-test--adf-outline "*bold* start\n\n ** not a heading"))
                 '("paragraph" "paragraph"))))

;;;; Converter: edge cases

(ert-deftest org-tickets-test--headings-commented-subtree-is-not-pushed ()
  "A COMMENT headline and everything under it stay out of Jira, like
comment blocks; the next sibling headline is still pushed."
  (should (equal (org-tickets-test--adf-outline
                  "Intro.\n*** COMMENT Draft\nsecret\n**** Deeper\nalso secret\n*** Kept\nk")
                 '(("paragraph" . "Intro.") (1 . "Kept") ("paragraph" . "k")))))

(ert-deftest org-tickets-test--headings-commented-only-description-is-empty ()
  "A description holding only a commented subtree pushes no content."
  (should (null (org-tickets-test--adf-blocks "*** COMMENT Draft\nsecret"))))

(ert-deftest org-tickets-test--headings-planning-line-is-not-text ()
  "SCHEDULED/DEADLINE lines under a description headline are dropped."
  (should (equal (org-tickets-test--adf-outline
                  "*** H\nSCHEDULED: <2026-11-06 Fri> DEADLINE: <2026-11-07 Sat>\nBody.")
                 '((1 . "H") ("paragraph" . "Body.")))))

(ert-deftest org-tickets-test--headings-comment-block-in-section-dropped ()
  "A comment block under a headline is not pushed."
  (should (equal (org-tickets-test--adf-outline
                  "*** H\n#+begin_comment\nx\n#+end_comment\nBody.")
                 '((1 . "H") ("paragraph" . "Body.")))))

(ert-deftest org-tickets-test--headings-statistics-cookie-in-title ()
  "A statistics cookie in a title is kept as text."
  (should (equal (org-tickets-test--adf-outline "*** Tasks [1/2]")
                 '((1 . "Tasks [1/2]")))))

(ert-deftest org-tickets-test--headings-empty-title ()
  "A headline with no title pushes a heading with no content."
  (let ((heading (car (org-tickets-test--adf-blocks "*** \nBody."))))
    (should (equal (org-tickets-test--adf-heading-level heading) 1))
    (should (null (assoc "content" heading)))))

(ert-deftest org-tickets-test--headings-attachment-under-heading-is-media ()
  "A standalone attachment link in a heading's section becomes media."
  (let* ((attachments (org-tickets-test--json "[{\"id\": \"1\", \"filename\": \"a.png\", \"mediaApiFileId\": \"uuid-a\"}]"))
         (blocks (cdr (assoc "content"
                             (org-tickets--build-adf-description
                              "*** Shot\n[[attachment:a.png]]" attachments)))))
    (should (equal (mapcar #'org-tickets-test--block-type blocks)
                   '("heading" "mediaSingle")))))

(ert-deftest org-tickets-test--headings-attachment-under-heading-is-uploaded ()
  "Attachment links under description headings are seen by the uploader."
  (let ((text (org-tickets-test--ticket-text
               "**" "Story" "S" "*** Shot\n[[attachment:a.png]]\n**** More\n[[attachment:b.png]]\n")))
    (should (equal (sort (org-tickets--description-attachment-filenames
                          (org-tickets-test--description-of text "S"))
                         #'string<)
                   '("a.png" "b.png")))))

(ert-deftest org-tickets-test--attachment-links-in-src-blocks-ignored ()
  "Attachment link syntax inside a source block is code, not a link."
  (should (null (org-tickets--description-attachment-filenames
                 "#+BEGIN_SRC org\n[[attachment:a.png]]\n#+END_SRC"))))

(ert-deftest org-tickets-test--headings-key-mentioned-in-heading-still-finds-ticket ()
  "A ticket key written in a description headline does not confuse lookup."
  (with-temp-buffer
    (insert (org-tickets-test--ticket-text "*" "Feature" "F" "*** See PROJ-2\n" "PROJ-1")
            (org-tickets-test--ticket-text "**" "Story" "S" "*** Back to PROJ-1\n" "PROJ-2"))
    (org-mode)
    (goto-char (org-tickets--find-ticket-by-key "PROJ-2"))
    (should (equal (org-get-heading t t t t) "S"))
    (goto-char (org-tickets--find-ticket-by-key "PROJ-1"))
    (should (equal (org-get-heading t t t t) "F"))))

;;;; Description boundary: Stories

(ert-deftest org-tickets-test--headings-story-description-includes-headings ()
  "A Story's description includes its *** and deeper headlines."
  (let ((text (org-tickets-test--ticket-text
               "**" "Story" "S" "Intro.\n*** H1\nOne.\n**** H2\nTwo.\n")))
    (should (equal (org-tickets-test--description-of text "S")
                   "Intro.\n*** H1\nOne.\n**** H2\nTwo."))
    (should (equal (org-tickets-test--pushed-outline text "S")
                   '(("paragraph" . "Intro.") (1 . "H1") ("paragraph" . "One.")
                     (2 . "H2") ("paragraph" . "Two."))))))

(ert-deftest org-tickets-test--headings-story-description-only-headings ()
  "A Story whose description starts with a headline keeps it."
  (let ((text (org-tickets-test--ticket-text "**" "Story" "S" "*** H\nBody.\n")))
    (should (equal (org-tickets-test--description-of text "S") "*** H\nBody."))))

(ert-deftest org-tickets-test--headings-story-under-feature ()
  "A Story under a Feature keeps its headings; the next Story is separate."
  (let ((text (concat (org-tickets-test--ticket-text "*" "Feature" "F" "F body.\n")
                      (org-tickets-test--ticket-text "**" "Story" "S1" "*** One\nA.\n")
                      (org-tickets-test--ticket-text "**" "Story" "S2" "*** Two\nB.\n"))))
    (should (equal (org-tickets-test--parse-tickets text)
                   '(("F" . "F body.")
                     ("S1" . "*** One\nA.")
                     ("S2" . "*** Two\nB."))))))

(defun org-tickets-test--parse-error (text)
  "Return the `user-error' message from parsing org TEXT, or nil."
  (condition-case err
      (progn (org-tickets-test--parse-tickets text) nil)
    (user-error (cadr err))))

(ert-deftest org-tickets-test--headings-ticket-below-level-two-is-rejected ()
  "A ticket at level 3 or deeper is rejected, naming the ticket, since
its description headings could not nest inside it."
  (dolist (stars '("***" "****"))
    (let ((msg (org-tickets-test--parse-error
                (concat (org-tickets-test--ticket-text "*" "Feature" "F" "")
                        (org-tickets-test--ticket-text "**" "Story" "S" "")
                        (org-tickets-test--ticket-text stars "Sub-task" "Deep" "")))))
      (should (string-match-p "Sub-task \"Deep\" is at outline level" msg)))))

(ert-deftest org-tickets-test--headings-parent-type-below-level-one-is-rejected ()
  "Every parent type must be level 1."
  (dolist (type org-tickets-test--parent-types)
    (should (org-tickets-test--parse-error
             (concat "* Group\n" (org-tickets-test--ticket-text "**" type "P" ""))))))

(ert-deftest org-tickets-test--headings-story-under-grouping-heading-is-rejected ()
  "A Story pushed to level 3 by a grouping heading is rejected."
  (should (org-tickets-test--parse-error
           (concat (org-tickets-test--ticket-text "*" "Feature" "F" "")
                   "** Group\n"
                   (org-tickets-test--ticket-text "***" "Story" "S" "")))))

(ert-deftest org-tickets-test--headings-allowed-levels-parse ()
  "Parents at 1, Stories at 2, and other children at 1 or 2 are accepted."
  (should (equal (mapcar #'car (org-tickets-test--parse-tickets
                                (concat (org-tickets-test--ticket-text "*" "Feature" "F" "")
                                        (org-tickets-test--ticket-text "**" "Story" "S" "")
                                        (org-tickets-test--ticket-text "**" "Bug" "B2" "")
                                        (org-tickets-test--ticket-text "*" "Bug" "B1" ""))))
                 '("F" "S" "B2" "B1"))))

;;;; Description boundary: parent types

(defun org-tickets-test--assert-parent-type-headings (type)
  "Assert headline boundaries for a parent ticket of TYPE with children."
  (let ((text (concat (org-tickets-test--ticket-text
                       "*" type "P" "Intro.\n*** Goals\nG.\n**** Detail\nD.\n")
                      (org-tickets-test--ticket-text "**" "Story" "C" "*** Plan\nP.\n"))))
    (should (equal (org-tickets-test--parse-tickets text)
                   '(("P" . "Intro.\n*** Goals\nG.\n**** Detail\nD.")
                     ("C" . "*** Plan\nP."))))
    (should (equal (org-tickets-test--pushed-outline text "P")
                   '(("paragraph" . "Intro.") (1 . "Goals") ("paragraph" . "G.")
                     (2 . "Detail") ("paragraph" . "D."))))
    (should (equal (org-tickets-test--pushed-outline text "C")
                   '((1 . "Plan") ("paragraph" . "P."))))))

(ert-deftest org-tickets-test--headings-feature-with-child-story ()
  (org-tickets-test--assert-parent-type-headings "Feature"))

(ert-deftest org-tickets-test--headings-new-feature-with-child-story ()
  (org-tickets-test--assert-parent-type-headings "New Feature"))

(ert-deftest org-tickets-test--headings-improvement-with-child-story ()
  (org-tickets-test--assert-parent-type-headings "Improvement"))

(ert-deftest org-tickets-test--headings-epic-with-child-story ()
  (org-tickets-test--assert-parent-type-headings "Epic"))

(ert-deftest org-tickets-test--headings-parent-heading-directly-before-shallower-child ()
  "A *** headline right before a ** child ticket: the headline is not
the child's sibling in org terms, yet the child still ends the parent's
description and keeps its own."
  (dolist (type org-tickets-test--parent-types)
    (let ((text (concat (org-tickets-test--ticket-text "*" type "P" "*** Deep\nX.\n")
                        (org-tickets-test--ticket-text "**" "Story" "C" "C body.\n"))))
      (should (equal (org-tickets-test--parse-tickets text)
                     '(("P" . "*** Deep\nX.") ("C" . "C body.")))))))

(ert-deftest org-tickets-test--headings-parent-two-star-non-ticket-heading ()
  "A ** headline without JIRA_TYPE under a parent is description (h1)."
  (dolist (type org-tickets-test--parent-types)
    (let ((text (org-tickets-test--ticket-text "*" type "P" "** Notes\nN.\n")))
      (should (equal (org-tickets-test--description-of text "P") "** Notes\nN."))
      (should (equal (org-tickets-test--pushed-outline text "P")
                     '((1 . "Notes") ("paragraph" . "N.")))))))

(ert-deftest org-tickets-test--headings-parent-without-children ()
  "A parent with only description headings keeps all of them."
  (dolist (type org-tickets-test--parent-types)
    (let ((text (org-tickets-test--ticket-text
                 "*" type "P" "*** A\na\n*** B\nb\n**** B.1\nb1\n")))
      (should (equal (org-tickets-test--pushed-outline text "P")
                     '((1 . "A") ("paragraph" . "a") (1 . "B") ("paragraph" . "b")
                       (2 . "B.1") ("paragraph" . "b1")))))))

(ert-deftest org-tickets-test--headings-parent-multiple-children-with-headings ()
  "Each child Story keeps only its own headings."
  (let ((text (concat (org-tickets-test--ticket-text "*" "Improvement" "P" "*** P-H\n")
                      (org-tickets-test--ticket-text "**" "Story" "C1" "*** C1-H\n")
                      (org-tickets-test--ticket-text "**" "Story" "C2" "*** C2-H\n**** C2-S\n"))))
    (should (equal (org-tickets-test--parse-tickets text)
                   '(("P" . "*** P-H") ("C1" . "*** C1-H")
                     ("C2" . "*** C2-H\n**** C2-S"))))))

(ert-deftest org-tickets-test--headings-sibling-parents-stay-separate ()
  "Headings never leak across top-level ticket boundaries."
  (let ((text (concat (org-tickets-test--ticket-text "*" "Feature" "F1" "*** One\n")
                      (org-tickets-test--ticket-text "*" "Improvement" "F2" "*** Two\n"))))
    (should (equal (org-tickets-test--parse-tickets text)
                   '(("F1" . "*** One") ("F2" . "*** Two"))))))

(ert-deftest org-tickets-test--headings-bug-at-top-level ()
  "A top-level non-parent ticket (Bug) keeps its headings."
  (let ((text (org-tickets-test--ticket-text "*" "Bug" "B" "*** Repro\nSteps.\n")))
    (should (equal (org-tickets-test--pushed-outline text "B")
                   '((1 . "Repro") ("paragraph" . "Steps."))))))

;;;; Description boundary: what counts as a ticket

(ert-deftest org-tickets-test--headings-ticket-nested-in-a-description-heading ()
  "A ticket nested inside a description headline is too deep and rejected."
  (should (org-tickets-test--parse-error
           (concat (org-tickets-test--ticket-text "*" "Feature" "F" "*** Group\nG.\n")
                   (org-tickets-test--ticket-text "****" "Story" "S" "S body.\n")))))

(ert-deftest org-tickets-test--headings-jira-key-without-type-is-description ()
  "Only JIRA_TYPE marks a ticket; a headline with just JIRA_KEY is text."
  (let ((text (org-tickets-test--ticket-text
               "**" "Story" "S" "*** Ref\n:PROPERTIES:\n:JIRA_KEY: P-9\n:END:\nR.\n")))
    (should (equal (mapcar #'car (org-tickets-test--parse-tickets text)) '("S")))
    (should (equal (org-tickets-test--pushed-outline text "S")
                   '((1 . "Ref") ("paragraph" . "R."))))))

(ert-deftest org-tickets-test--headings-are-not-parsed-as-tickets ()
  "Description headlines add no tickets and do not change classification."
  (with-temp-buffer
    (insert (org-tickets-test--ticket-text "*" "Feature" "F" "*** A\n**** B\n")
            (org-tickets-test--ticket-text "**" "Story" "S" "*** C\n"))
    (org-mode)
    (let ((doc (org-tickets--parse-document)))
      (should (equal (mapcar #'org-tickets--ticket-summary (org-tickets--doc-features doc))
                     '("F")))
      (should (equal (mapcar #'org-tickets--ticket-summary (org-tickets--doc-children doc))
                     '("S"))))))

(ert-deftest org-tickets-test--headings-keyed-tickets-with-drawers ()
  "Keyed tickets with full drawers still split at child tickets only."
  (let ((text (concat (org-tickets-test--ticket-text
                       "*" "Feature" "F" "*** H\nx\n" "P-1")
                      (org-tickets-test--ticket-text
                       "**" "Story" "S" "*** H2\ny\n" "P-2"))))
    (should (equal (org-tickets-test--parse-tickets text)
                   '(("F" . "*** H\nx") ("S" . "*** H2\ny"))))))

(ert-deftest org-tickets-test--headings-description-end-leaves-point ()
  "Finding the description end does not move point."
  (with-temp-buffer
    (insert (org-tickets-test--ticket-text "*" "Feature" "F" "*** H\n")
            (org-tickets-test--ticket-text "**" "Story" "S" ""))
    (org-mode)
    (goto-char (point-min))
    (org-tickets--description-end (point-max))
    (should (= (point) (point-min)))))

;;;; Sync: the description handed to the ADF builder

(defun org-tickets-test--synced-descriptions (setup)
  "Sync a buffer prepared by SETUP; return descriptions sent to Jira."
  (let ((descs nil))
    (org-tickets-test--with-sync-mocks nil
      (org-tickets-test--with-stubs
          ((org-tickets--build-adf-description
            (lambda (desc _atts) (push desc descs) nil)))
        (with-temp-buffer
          (org-mode)
          (funcall setup)
          (org-tickets-test--run-sync))))
    (sort (delq nil descs) #'string<)))

(ert-deftest org-tickets-test--headings-sync-sends-headings-for-feature-and-story ()
  "A sync pushes each ticket's headings, and only its own."
  (should (equal (org-tickets-test--synced-descriptions
                  (lambda ()
                    (insert (org-tickets-test--ticket-text
                             "*" "Feature" "F" "*** F-H\nf\n" "PROJ-1")
                            (org-tickets-test--ticket-text
                             "**" "Story" "S" "*** S-H\ns\n" "PROJ-2"))))
                 '("*** F-H\nf" "*** S-H\ns"))))

(ert-deftest org-tickets-test--headings-sync-sends-headings-for-improvement ()
  "Improvements push their headings like Features."
  (should (equal (org-tickets-test--synced-descriptions
                  (lambda ()
                    (insert (org-tickets-test--ticket-text
                             "*" "Improvement" "I" "*** I-H\n**** Sub\n" "PROJ-3"))))
                 '("*** I-H\n**** Sub"))))

(provide 'org-tickets-test-headings-push)
;;; org-tickets-test-headings-push.el ends here
