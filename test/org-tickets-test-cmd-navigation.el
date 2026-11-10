;;; org-tickets-test-cmd-navigation.el --- Next/previous ticket commands  -*- lexical-binding: t; -*-

;;; Commentary:

;; `org-tickets-next-ticket' and `org-tickets-previous-ticket' move
;; between ticket headings (JIRA_TYPE or JIRA_KEY), skipping description
;; headings and unrelated headings.  The expected destination for every
;; position in a buffer is computed from the ticket heading positions.

;;; Code:

(require 'ert)
(require 'seq)
(require 'org)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; Helpers

(defun org-tickets-test--nav-text ()
  "Return a buffer with a preamble, tickets, description and plain headings."
  (concat "preamble\n"
          (org-tickets-test--ticket-text
           "*" "Feature" "F" "F intro.\n*** F-Goals\ng-body\n**** F-Deep\nd-body\n" "P-1")
          "** Plain\nplain body\n"
          (org-tickets-test--ticket-text
           "**" "Story" "S" "*** S-Req\nr-body\n" "P-2")
          (org-tickets-test--ticket-text "**" "Task" "K" "" "P-3")
          "*** Legacy\n:PROPERTIES:\n:JIRA_KEY: P-9\n:END:\nl-body\n"
          (org-tickets-test--ticket-text "*" "Bug" "T" "**** T-Step\ns-body\n" "P-4")
          "* Trailing\nend\n"))

(defun org-tickets-test--ticket-positions ()
  "Return the start positions of all ticket headings in the buffer."
  (let (found)
    (org-with-wide-buffer
     (goto-char (point-min))
     (while (re-search-forward org-heading-regexp nil t)
       (beginning-of-line)
       (when (org-tickets--ticket-heading-p) (push (point) found))
       (end-of-line)))
    (nreverse found)))

(defun org-tickets-test--expected-target (step)
  "Return where STEP (1 or -1) should go from point, or nil if nowhere."
  (let ((positions (org-tickets-test--ticket-positions)))
    (if (> step 0)
        (seq-find (lambda (pos) (> pos (point))) positions)
      (car (last (seq-filter (lambda (pos) (< pos (line-beginning-position)))
                             positions))))))

(defun org-tickets-test--title-at (pos)
  "Return the title of the heading starting at POS."
  (save-excursion (goto-char pos) (org-get-heading t t t t)))

;;;; Every position

(ert-deftest org-tickets-test--next-ticket-from-every-position ()
  "From any point, next goes to the first ticket heading after it."
  (with-temp-buffer
    (insert (org-tickets-test--nav-text))
    (org-mode)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((expected (org-tickets-test--expected-target 1))
              (origin (point)))
          (if expected
              (progn (org-tickets-next-ticket)
                     (should (equal (list origin (point)) (list origin expected))))
            (should-error (org-tickets-next-ticket) :type 'user-error)
            (should (= (point) origin)))
          (goto-char origin))
        (forward-char 1)))))

(ert-deftest org-tickets-test--previous-ticket-from-every-position ()
  "From any point, previous goes to the last ticket heading before its line."
  (with-temp-buffer
    (insert (org-tickets-test--nav-text))
    (org-mode)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((expected (org-tickets-test--expected-target -1))
              (origin (point)))
          (if expected
              (progn (org-tickets-previous-ticket)
                     (should (equal (list origin (point)) (list origin expected))))
            (should-error (org-tickets-previous-ticket) :type 'user-error)
            (should (= (point) origin)))
          (goto-char origin))
        (forward-char 1)))))

;;;; Concrete scenarios

(ert-deftest org-tickets-test--walk-forward-visits-tickets-in-order ()
  (with-temp-buffer
    (insert (org-tickets-test--nav-text))
    (org-mode)
    (goto-char (point-min))
    (let (visited)
      (condition-case nil
          (while t (org-tickets-next-ticket)
                 (push (org-get-heading t t t t) visited))
        (user-error nil))
      (should (equal (nreverse visited) '("F" "S" "K" "Legacy" "T"))))))

(ert-deftest org-tickets-test--walk-backward-visits-tickets-in-reverse ()
  (with-temp-buffer
    (insert (org-tickets-test--nav-text))
    (org-mode)
    (goto-char (point-max))
    (let (visited)
      (condition-case nil
          (while t (org-tickets-previous-ticket)
                 (push (org-get-heading t t t t) visited))
        (user-error nil))
      (should (equal (nreverse visited) '("T" "Legacy" "K" "S" "F"))))))

(ert-deftest org-tickets-test--next-then-previous-returns-to-ticket ()
  (org-tickets-test--with-org-buffer-at (org-tickets-test--nav-text) "** S"
    (let ((start (point)))
      (org-tickets-next-ticket)
      (org-tickets-previous-ticket)
      (should (= (point) start)))))

(ert-deftest org-tickets-test--navigation-skips-plain-and-description-headings ()
  (org-tickets-test--with-org-buffer-at (org-tickets-test--nav-text) "** Plain"
    (org-tickets-next-ticket)
    (should (equal (org-get-heading t t t t) "S")))
  (org-tickets-test--with-org-buffer-at (org-tickets-test--nav-text) "** Plain"
    (org-tickets-previous-ticket)
    (should (equal (org-get-heading t t t t) "F"))))

(ert-deftest org-tickets-test--navigation-treats-key-only-heading-as-ticket ()
  (org-tickets-test--with-org-buffer-at (org-tickets-test--nav-text) "** K"
    (org-tickets-next-ticket)
    (should (equal (org-get-heading t t t t) "Legacy"))))

(ert-deftest org-tickets-test--navigation-with-no-tickets-errors ()
  (with-temp-buffer
    (insert "* A\nbody\n** B\n")
    (org-mode)
    (goto-char (point-min))
    (should-error (org-tickets-next-ticket) :type 'user-error)
    (should-error (org-tickets-previous-ticket) :type 'user-error)
    (should (= (point) (point-min)))))

(ert-deftest org-tickets-test--navigation-in-empty-buffer-errors ()
  (with-temp-buffer
    (org-mode)
    (should-error (org-tickets-next-ticket) :type 'user-error)
    (should-error (org-tickets-previous-ticket) :type 'user-error)))

(ert-deftest org-tickets-test--navigation-with-single-ticket-errors ()
  (with-temp-buffer
    (insert (org-tickets-test--ticket-text "*" "Task" "Only" "body\n" "P-1"))
    (org-mode)
    (goto-char (point-min))
    (should-error (org-tickets-next-ticket) :type 'user-error)
    (should-error (org-tickets-previous-ticket) :type 'user-error)))

(ert-deftest org-tickets-test--navigation-error-messages-name-direction ()
  (with-temp-buffer
    (insert (org-tickets-test--ticket-text "*" "Task" "Only" "" "P-1"))
    (org-mode)
    (goto-char (point-min))
    (should (equal (cadr (should-error (org-tickets-next-ticket) :type 'user-error))
                   "No next ticket heading"))
    (should (equal (cadr (should-error (org-tickets-previous-ticket) :type 'user-error))
                   "No previous ticket heading"))))

(ert-deftest org-tickets-test--navigation-respects-narrowing ()
  (org-tickets-test--with-org-buffer-at (org-tickets-test--nav-text) "** S"
    (org-narrow-to-subtree)
    (should-error (org-tickets-next-ticket) :type 'user-error)
    (should (equal (org-get-heading t t t t) "S"))
    (should-error (org-tickets-previous-ticket) :type 'user-error)))

(ert-deftest org-tickets-test--navigation-commands-are-interactive ()
  (should (commandp #'org-tickets-next-ticket))
  (should (commandp #'org-tickets-previous-ticket)))

(ert-deftest org-tickets-test--navigation-is-bound-to-super-arrows ()
  (should (eq (lookup-key org-mode-map (kbd "s-<up>")) #'org-tickets-previous-ticket))
  (should (eq (lookup-key org-mode-map (kbd "s-<down>")) #'org-tickets-next-ticket)))

(provide 'org-tickets-test-cmd-navigation)
;;; org-tickets-test-cmd-navigation.el ends here
