;;; org-tickets-test-headings-pull.el --- Description headings, ADF -> org  -*- lexical-binding: t; -*-

;;; Commentary:

;; ADF headings import as org headlines two levels deeper (h1 is `***')
;; so they nest under the `*' parent and `**' Story headings the
;; importer writes.  Pulling replaces those headlines along with the
;; rest of the description, never touching child tickets, and a
;; push/pull cycle is a fixpoint.  Other blocks must still never emit
;; a headline.

;;; Code:

(require 'ert)
(require 'seq)
(require 'json)
(require 'org)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)
(require 'org-tickets-test-headings-push)
(require 'org-tickets-test-roundtrip)

;;;; Helpers

(defun org-tickets-test--adf-doc (&rest blocks)
  "Return a JSON-decoded ADF doc of BLOCKS, shaped like an API response."
  (org-tickets-test--json
   (json-encode `(("type" . "doc") ("version" . 1)
                  ("content" . ,(vconcat blocks))))))

(defun org-tickets-test--adf-heading (level text &optional marks)
  "Return an ADF heading block at LEVEL holding TEXT with MARKS."
  (let ((node (list (cons "type" "text") (cons "text" text))))
    (when marks
      (setq node (append node (list (cons "marks" (vconcat marks))))))
    (list (cons "type" "heading")
          (cons "attrs" (list (cons "level" level)))
          (cons "content" (vector node)))))

(defun org-tickets-test--adf-para (text)
  "Return an ADF paragraph block holding TEXT."
  `(("type" . "paragraph") ("content" . [(("type" . "text") ("text" . ,text))])))

(defun org-tickets-test--import (&rest blocks)
  "Import an ADF doc of BLOCKS to org description text."
  (org-tickets--parse-adf-description (apply #'org-tickets-test--adf-doc blocks)))

(defun org-tickets-test--ticket-record (type title description &optional key)
  "Return a ticket record of TYPE, TITLE, DESCRIPTION and KEY."
  (org-tickets--ticket-create :key (or key "P-1") :type type :summary title
                              :description description :labels nil))

(defun org-tickets-test--imported-buffer (tickets)
  "Return the org text `org-tickets--issue-to-org' writes for TICKETS."
  (with-temp-buffer
    (org-mode)
    (dolist (ticket tickets)
      (org-tickets--issue-to-org ticket))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun org-tickets-test--pull-into (text key type description)
  "Pull DESCRIPTION for ticket KEY of TYPE into org TEXT; return new text."
  (with-temp-buffer
    (insert text)
    (org-mode)
    (goto-char (org-tickets--find-ticket-by-key key))
    (org-tickets--update-org-heading-from-ticket
     (org-tickets-test--ticket-record type (org-get-heading t t t t) description key))
    (buffer-substring-no-properties (point-min) (point-max))))

(defun org-tickets-test--normalized-adf (org-text)
  "Push ORG-TEXT and decode the JSON the API would receive."
  (org-tickets-test--json (json-encode (org-tickets--build-adf-description org-text))))

;;;; ADF -> org text

(ert-deftest org-tickets-test--headings-pull-each-level ()
  "h1..h6 import as three to eight stars."
  (should (equal (apply #'org-tickets-test--import
                        (mapcar (lambda (n) (org-tickets-test--adf-heading n (format "H%d" n)))
                                '(1 2 3 4 5 6)))
                 (concat "*** H1\n\n**** H2\n\n***** H3\n\n"
                         "****** H4\n\n******* H5\n\n******** H6"))))

(ert-deftest org-tickets-test--headings-pull-missing-level-is-h1 ()
  "A heading with no attrs imports as ***."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"content\":[{\"type\":\"heading\",
                     \"content\":[{\"type\":\"text\",\"text\":\"T\"}]}]}"))
                 "*** T")))

(ert-deftest org-tickets-test--headings-pull-marks-in-title ()
  "Marks inside a heading become org markup in the headline."
  (should (equal (org-tickets-test--import
                  (org-tickets-test--adf-heading 1 "bold" '((("type" . "strong")))))
                 "*** *bold*")))

(ert-deftest org-tickets-test--headings-pull-with-bodies ()
  "Paragraphs between headings land in the right sections."
  (should (equal (org-tickets-test--import
                  (org-tickets-test--adf-para "Intro.")
                  (org-tickets-test--adf-heading 1 "A")
                  (org-tickets-test--adf-para "a")
                  (org-tickets-test--adf-heading 2 "B")
                  (org-tickets-test--adf-para "b"))
                 "Intro.\n\n*** A\n\na\n\n**** B\n\nb")))

(ert-deftest org-tickets-test--headings-pull-paragraph-star-line-escaped ()
  "A paragraph starting with \"* \" is escaped, not made a headline."
  (should (equal (org-tickets-test--import (org-tickets-test--adf-para "*** fake"))
                 " *** fake")))

(ert-deftest org-tickets-test--headings-pull-code-block-star-line-escaped ()
  "A code block line starting with stars is escaped."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"content\":[{\"type\":\"codeBlock\",
                     \"content\":[{\"type\":\"text\",\"text\":\"* x\"}]}]}"))
                 "#+BEGIN_SRC\n * x\n#+END_SRC")))

(ert-deftest org-tickets-test--headings-pull-heading-inside-panel-is-escaped ()
  "Only top-level headings become headlines; a nested one is escaped text."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"content\":[{\"type\":\"panel\",\"content\":[
                     {\"type\":\"heading\",\"attrs\":{\"level\":1},
                      \"content\":[{\"type\":\"text\",\"text\":\"In\"}]}]}]}"))
                 " *** In")))

(ert-deftest org-tickets-test--headings-pull-heading-text-with-newline-free-title ()
  "A heading title with leading stars still yields exactly one headline."
  (let ((text (org-tickets-test--import (org-tickets-test--adf-heading 1 "* odd"))))
    (with-temp-buffer
      (insert text)
      (org-mode)
      (goto-char (point-min))
      (should (equal (org-get-heading t t t t) "* odd"))
      (should (= (org-current-level) 3)))))

(ert-deftest org-tickets-test--headings-pull-hard-break-in-heading-stays-one-line ()
  "A hardBreak inside a heading becomes a space so the title stays whole."
  (let ((text (org-tickets--parse-adf-description
               (org-tickets-test--json
                "{\"type\":\"doc\",\"content\":[{\"type\":\"heading\",\"attrs\":{\"level\":1},
                  \"content\":[{\"type\":\"text\",\"text\":\"a\"},{\"type\":\"hardBreak\"},
                                {\"type\":\"text\",\"text\":\"b\"}]}]}"))))
    (should (equal text "*** a b"))
    (should (equal (org-tickets-test--roundtrip text) text))))

(ert-deftest org-tickets-test--headings-pull-empty-heading-is-dropped ()
  "Empty headings import as nothing, wherever they sit."
  (should (equal (org-tickets--parse-adf-description
                  (org-tickets-test--json
                   "{\"type\":\"doc\",\"content\":[{\"type\":\"heading\",\"attrs\":{\"level\":1}},
                     {\"type\":\"paragraph\",\"content\":[{\"type\":\"text\",\"text\":\"x\"}]},
                     {\"type\":\"heading\",\"attrs\":{\"level\":2},\"content\":[]}]}"))
                 "x")))

(ert-deftest org-tickets-test--headings-pull-only-empty-headings-is-no-description ()
  "A description of only empty headings imports as no description."
  (should (null (org-tickets--parse-adf-description
                 (org-tickets-test--json
                  "{\"type\":\"doc\",\"content\":[{\"type\":\"heading\",\"attrs\":{\"level\":1}}]}")))))

(ert-deftest org-tickets-test--headings-pull-attachments-after-heading-description ()
  "Imported attachment lines after a heading description keep the ticket
whole and do not create extra tickets."
  (let* ((ticket (org-tickets-test--ticket-record "Story" "S" "*** H\n\nbody"))
         (text (progn (setf (org-tickets--ticket-attachments ticket)
                            (list (list (cons 'filename "a.png")
                                        (cons 'url "https://x.example/a.png"))))
                      (org-tickets-test--imported-buffer (list ticket)))))
    (should (equal (mapcar #'car (org-tickets-test--parse-tickets text)) '("S")))
    (should (string-prefix-p "*** H\n\nbody"
                             (org-tickets-test--description-of text "S")))))

;;;; Fresh import into a buffer

(defun org-tickets-test--assert-imported-headings (type title)
  "Assert an imported ticket of TYPE titled TITLE keeps its headings."
  (let* ((desc (org-tickets-test--import
                (org-tickets-test--adf-para "Intro.")
                (org-tickets-test--adf-heading 1 "Top")
                (org-tickets-test--adf-para "Body.")
                (org-tickets-test--adf-heading 2 "Sub")))
         (text (org-tickets-test--imported-buffer
                (list (org-tickets-test--ticket-record type title desc)))))
    (should (equal (org-tickets-test--parse-tickets text) (list (cons title desc))))
    (should (equal (org-tickets-test--pushed-outline text title)
                   '(("paragraph" . "Intro.") (1 . "Top") ("paragraph" . "Body.")
                     (2 . "Sub"))))))

(ert-deftest org-tickets-test--headings-import-story ()
  (org-tickets-test--assert-imported-headings "Story" "S"))

(ert-deftest org-tickets-test--headings-import-feature ()
  (org-tickets-test--assert-imported-headings "Feature" "F"))

(ert-deftest org-tickets-test--headings-import-new-feature ()
  (org-tickets-test--assert-imported-headings "New Feature" "N"))

(ert-deftest org-tickets-test--headings-import-improvement ()
  (org-tickets-test--assert-imported-headings "Improvement" "I"))

(ert-deftest org-tickets-test--headings-import-bug ()
  (org-tickets-test--assert-imported-headings "Bug" "B"))

(ert-deftest org-tickets-test--headings-import-feature-then-story ()
  "Imported parent headings stay with the parent, not the next Story."
  (dolist (type '("Feature" "New Feature" "Improvement"))
    (let ((text (org-tickets-test--imported-buffer
                 (list (org-tickets-test--ticket-record
                        type "P" (org-tickets-test--import
                                  (org-tickets-test--adf-heading 1 "P-H"))
                        "P-1")
                       (org-tickets-test--ticket-record
                        "Story" "S" (org-tickets-test--import
                                     (org-tickets-test--adf-heading 1 "S-H"))
                        "P-2")))))
      (should (equal (org-tickets-test--parse-tickets text)
                     '(("P" . "*** P-H") ("S" . "*** S-H")))))))

;;;; Pull into an existing buffer

(ert-deftest org-tickets-test--headings-pull-story-replaces-old-headings ()
  "Pulling a Story swaps its old headlines for the new ones."
  (let* ((text (concat (org-tickets-test--ticket-text "*" "Feature" "F" "" "P-1")
                       (org-tickets-test--ticket-text
                        "**" "Story" "S" "Old.\n*** Old H\nold\n" "P-2")
                       (org-tickets-test--ticket-text "**" "Story" "S2" "*** Keep\n" "P-3")))
         (pulled (org-tickets-test--pull-into text "P-2" "Story" "*** New H\n\nnew")))
    (should (equal (org-tickets-test--parse-tickets pulled)
                   '(("F" . nil) ("S" . "*** New H\n\nnew") ("S2" . "*** Keep"))))))

(ert-deftest org-tickets-test--headings-pull-parent-keeps-children ()
  "Pulling a parent replaces its headings and leaves child tickets intact."
  (dolist (type org-tickets-test--parent-types)
    (let* ((text (concat (org-tickets-test--ticket-text
                          "*" type "P" "*** Old\nold\n" "P-1")
                         (org-tickets-test--ticket-text
                          "**" "Story" "C" "*** C-H\nc\n" "P-2")))
           (pulled (org-tickets-test--pull-into text "P-1" type "*** New\n\nnew")))
      (should (equal (org-tickets-test--parse-tickets pulled)
                     '(("P" . "*** New\n\nnew") ("C" . "*** C-H\nc")))))))

(ert-deftest org-tickets-test--headings-pull-parent-heading-before-shallower-child ()
  "Old *** headings directly above a ** child are fully replaced."
  (let* ((text (concat (org-tickets-test--ticket-text
                        "*" "Improvement" "P" "*** A\n**** B\n" "P-1")
                       (org-tickets-test--ticket-text "**" "Story" "C" "c\n" "P-2")))
         (pulled (org-tickets-test--pull-into text "P-1" "Improvement" "plain")))
    (should (equal (org-tickets-test--parse-tickets pulled)
                   '(("P" . "plain") ("C" . "c"))))))

(ert-deftest org-tickets-test--headings-pull-nil-description-removes-headings ()
  "An empty Jira description clears description headlines too."
  (dolist (type '("Story" "Feature" "Improvement"))
    (let* ((text (concat (org-tickets-test--ticket-text "*" type "T" "*** H\nh\n" "P-1")
                         (org-tickets-test--ticket-text "**" "Story" "C" "c\n" "P-2")))
           (pulled (org-tickets-test--pull-into text "P-1" type nil)))
      (should (equal (org-tickets-test--parse-tickets pulled)
                     '(("T" . nil) ("C" . "c")))))))

(ert-deftest org-tickets-test--headings-pull-story-boundary-is-next-story ()
  "Pulling a Story stops at the next Story and leaves it alone."
  (let* ((text (concat (org-tickets-test--ticket-text "*" "Feature" "F" "" "P-0")
                       (org-tickets-test--ticket-text "**" "Story" "S" "*** Old\n" "P-1")
                       (org-tickets-test--ticket-text "**" "Story" "T" "*** Step\n" "P-2")))
         (pulled (org-tickets-test--pull-into text "P-1" "Story" "*** New")))
    (should (equal (org-tickets-test--parse-tickets pulled)
                   '(("F" . nil) ("S" . "*** New") ("T" . "*** Step"))))))

(ert-deftest org-tickets-test--headings-pull-rejects-too-deep-ticket ()
  "Pulling into a ticket below level 2 errors before touching the buffer."
  (let ((text (concat "* Group\n** Sub\n"
                      (org-tickets-test--ticket-text "***" "Story" "S" "old\n" "P-1"))))
    (should-error (org-tickets-test--pull-into text "P-1" "Story" "*** New")
                  :type 'user-error)))

(ert-deftest org-tickets-test--headings-pull-is-idempotent ()
  "Pulling the same description twice gives the same buffer."
  (dolist (type '("Story" "Feature" "New Feature" "Improvement"))
    (let* ((stars (if (equal type "Story") "**" "*"))
           (text (concat (org-tickets-test--ticket-text stars type "T" "x\n" "P-1")
                         (org-tickets-test--ticket-text "**" "Story" "C" "c\n" "P-2")))
           (desc "Intro.\n\n*** H\n\nh\n\n**** S")
           (once (org-tickets-test--pull-into text "P-1" type desc)))
      (should (equal (org-tickets-test--pull-into once "P-1" type desc) once)))))

;;;; Full round trips

(defun org-tickets-test--assert-fixpoint (type stars org-desc)
  "Assert ORG-DESC on a TYPE ticket at STARS survives push then pull.
A following Story must keep its own description.
The ADF pushed from the original and from the pulled buffer must match,
and the pulled description must parse back unchanged."
  (let* ((adf (org-tickets-test--normalized-adf org-desc))
         (pulled-desc (org-tickets--parse-adf-description adf))
         (text (concat (org-tickets-test--ticket-text stars type "T" "old\n" "P-1")
                       (org-tickets-test--ticket-text "**" "Story" "C" "c\n" "P-2")))
         (pulled (org-tickets-test--pull-into text "P-1" type pulled-desc))
         (reparsed (org-tickets-test--description-of pulled "T")))
    (should (equal reparsed pulled-desc))
    (should (equal (org-tickets-test--normalized-adf reparsed) adf))
    (should (equal (org-tickets-test--description-of pulled "C") "c"))))

(defconst org-tickets-test--rich-heading-description
  (concat "Intro *bold*.\n\n*** Goals\n\n- one\n- two\n\n"
          "**** Detail /it/\n\n#+BEGIN_SRC sh\nls\n#+END_SRC\n\n"
          "******** Deepest\n\ndeep\n\n*** Wrap\n\n| a | b |")
  "A description exercising every heading level transition kind.")

(ert-deftest org-tickets-test--headings-roundtrip-story ()
  (org-tickets-test--assert-fixpoint "Story" "**" org-tickets-test--rich-heading-description))

(ert-deftest org-tickets-test--headings-roundtrip-feature ()
  (org-tickets-test--assert-fixpoint "Feature" "*" org-tickets-test--rich-heading-description))

(ert-deftest org-tickets-test--headings-roundtrip-new-feature ()
  (org-tickets-test--assert-fixpoint "New Feature" "*" org-tickets-test--rich-heading-description))

(ert-deftest org-tickets-test--headings-roundtrip-improvement ()
  (org-tickets-test--assert-fixpoint "Improvement" "*" org-tickets-test--rich-heading-description))

(ert-deftest org-tickets-test--headings-roundtrip-epic ()
  (org-tickets-test--assert-fixpoint "Epic" "*" org-tickets-test--rich-heading-description))

(ert-deftest org-tickets-test--headings-roundtrip-every-level-pair ()
  "Every h(i) followed by h(j) for i, j in 1..6 round-trips."
  (dolist (i '(1 2 3 4 5 6))
    (dolist (j '(1 2 3 4 5 6))
      (let ((desc (format "%s A\n\na\n\n%s B\n\nb"
                          (make-string (+ i 2) ?*) (make-string (+ j 2) ?*))))
        (should (equal (org-tickets-test--roundtrip desc) desc))))))

(ert-deftest org-tickets-test--headings-roundtrip-clamped-levels-normalize ()
  "Out-of-range levels normalize once, then stay fixed."
  (let ((once (org-tickets-test--roundtrip "** Shallow\n\n********** Deep")))
    (should (equal once "*** Shallow\n\n******** Deep"))
    (should (equal (org-tickets-test--roundtrip once) once))))

(provide 'org-tickets-test-headings-pull)
;;; org-tickets-test-headings-pull.el ends here
