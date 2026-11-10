;;; org-tickets-test-graph-edges.el --- Tests for graph ids and edges  -*- lexical-binding: t; -*-

;;; Commentary:

;; Node ids and edges of the ticket dependency graph: parent edges
;; climbing through nested headings, new-N numbering, typeless tickets,
;; and what `org-tickets--graph-model' leaves behind when parsing fails.

;;; Code:

(require 'ert)
(require 'seq)
(require 'org)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

(defun org-tickets-test--edges-heading (stars type title &optional key parent)
  "Return org text for a TYPE heading TITLE at STARS with KEY and PARENT."
  (concat stars " " title "\n:PROPERTIES:\n:JIRA_TYPE: " type "\n"
          (if key (concat ":JIRA_KEY: " key "\n") "")
          (if parent (concat ":PARENT: " parent "\n") "")
          ":END:\n"))

(defun org-tickets-test--edges-of (&rest texts)
  "Return the graph edges of an org buffer holding TEXTS concatenated."
  (with-temp-buffer
    (insert (apply #'concat texts))
    (org-mode)
    (plist-get (org-tickets--graph-model) :edges)))

(defun org-tickets-test--unchecked-graph (&rest texts)
  "Return the graph model built from TEXTS without the outline-level check.
Every heading with a JIRA_TYPE becomes a ticket, so tickets may nest
deeper than `org-tickets--parse-document' accepts."
  (with-temp-buffer
    (insert (apply #'concat texts))
    (org-mode)
    (org-tickets--graph-build
     (delq nil
           (org-map-entries
            (lambda ()
              (let ((type (org-entry-get (point) "JIRA_TYPE")))
                (when type
                  (org-tickets--ticket-create
                   :key (org-entry-get (point) "JIRA_KEY")
                   :type type
                   :summary (org-get-heading t t t t)
                   :parent (org-entry-get (point) "PARENT")
                   :marker (point-marker))))))))))

;;;; Parent edges through nesting

(ert-deftest org-tickets-test--graph-subtask-points-at-nearest-parent-type ()
  "A Sub-task under a Story under a Feature points at the Feature.
Parent edges go to the nearest parent-type ancestor; a Story is not a
parent type, so it is climbed past."
  (should (equal (plist-get
                  (org-tickets-test--unchecked-graph
                   (org-tickets-test--edges-heading "*" "Feature" "F" "P-1")
                   (org-tickets-test--edges-heading "**" "Story" "S" "P-2")
                   (org-tickets-test--edges-heading "***" "Sub-task" "T" "P-3"))
                  :edges)
                 '(("P-2" . "P-1") ("P-3" . "P-1")))))

(ert-deftest org-tickets-test--graph-story-under-plain-heading-points-at-feature ()
  "A plain heading between a Story and its Feature does not break the edge."
  (should (equal (plist-get
                  (org-tickets-test--unchecked-graph
                   (org-tickets-test--edges-heading "*" "Feature" "F" "P-1")
                   "** Notes\n"
                   (org-tickets-test--edges-heading "***" "Story" "S" "P-2"))
                  :edges)
                 '(("P-2" . "P-1")))))

;;;; Ids

(ert-deftest org-tickets-test--graph-new-ids-count-only-unkeyed-tickets ()
  "Unkeyed tickets are numbered new-1, new-2 around a keyed one."
  (with-temp-buffer
    (insert (org-tickets-test--edges-heading "*" "Feature" "F")
            (org-tickets-test--edges-heading "**" "Story" "A" "PROJ-7")
            (org-tickets-test--edges-heading "**" "Story" "B"))
    (org-mode)
    (let ((model (org-tickets--graph-model)))
      (should (equal (mapcar (lambda (node) (plist-get node :id))
                             (plist-get model :nodes))
                     '("new-1" "PROJ-7" "new-2")))
      (should (member '("new-2" . "new-1") (plist-get model :edges))))))

;;;; Typeless tickets

(ert-deftest org-tickets-test--graph-empty-type-gets-no-parent-edge ()
  "A ticket with an empty JIRA_TYPE and a PARENT draws no parent edge."
  (should-not (org-tickets-test--edges-of
               (org-tickets-test--edges-heading "*" "Feature" "F" "PROJ-1")
               (org-tickets-test--edges-heading "**" "" "S" "PROJ-2" "PROJ-1"))))

(ert-deftest org-tickets-test--graph-missing-type-gets-no-parent-edge ()
  "A ticket with no type but a PARENT key states no edge."
  (with-temp-buffer
    (insert "* S\n")
    (let ((ticket (org-tickets--ticket-create
                   :key "PROJ-2" :type nil :parent "PROJ-1"
                   :marker (copy-marker (point-min)))))
      (should-not (org-tickets--graph-ticket-edges ticket "PROJ-2" nil)))))

;;;; Parse failures

(defconst org-tickets-test--graph-bad-level-text
  (concat (org-tickets-test--edges-heading "*" "Feature" "F" "PROJ-1")
          (org-tickets-test--edges-heading "**" "Story" "S" "PROJ-2")
          (org-tickets-test--edges-heading "***" "Story" "Too deep" "PROJ-3"))
  "Org text whose last ticket is nested too deep to parse.")

(ert-deftest org-tickets-test--graph-model-parse-error-leaves-buffer-alone ()
  "A ticket at an invalid level signals, leaving text, point and narrowing."
  (with-temp-buffer
    (insert org-tickets-test--graph-bad-level-text)
    (org-mode)
    (set-buffer-modified-p nil)
    (goto-char (point-min))
    (forward-line 2)
    (narrow-to-region (point) (point-max))
    (let ((text (buffer-string)) (pt (point))
          (beg (point-min)) (end (point-max)))
      (should-error (org-tickets--graph-model) :type 'user-error)
      (should (equal text (buffer-string)))
      (should (= pt (point)))
      (should (= beg (point-min)))
      (should (= end (point-max)))
      (should-not (buffer-modified-p)))))

(ert-deftest org-tickets-test--graph-model-releases-markers ()
  "Every ticket marker made while building the graph points nowhere after."
  (with-temp-buffer
    (insert (org-tickets-test--edges-heading "*" "Feature" "F" "PROJ-1")
            (org-tickets-test--edges-heading "**" "Story" "S" "PROJ-2"))
    (org-mode)
    (let ((markers nil))
      (org-tickets-test--recording-markers markers
        (org-tickets--graph-model))
      (should (= (length markers) 2))
      (should-not (seq-some #'marker-buffer markers)))))

(provide 'org-tickets-test-graph-edges)

;;; org-tickets-test-graph-edges.el ends here
