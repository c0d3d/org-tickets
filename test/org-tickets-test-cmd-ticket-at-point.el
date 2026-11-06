;;; org-tickets-test-cmd-ticket-at-point.el --- Commands from inside a ticket  -*- lexical-binding: t; -*-

;;; Commentary:

;; Interactive commands act on the ticket that owns point: the nearest
;; heading at or above point with JIRA_TYPE or JIRA_KEY.  So running a
;; command from a description headline (`*** Requirements') or its body
;; reaches the ticket, never the description heading and never an
;; enclosing parent ticket.

;;; Code:

(require 'ert)
(require 'seq)
(require 'org)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)
(require 'org-tickets-test-headings-push)

;;;; Helpers

(defun org-tickets-test--ticket-buffer-text ()
  "Return a Feature with a Story, then a Bug, each with description headings."
  (concat (org-tickets-test--ticket-text
           "*" "Feature" "F" "F intro.\n*** F-Goals\ng-body\n**** F-Deep\nd-body\n" "P-1")
          (org-tickets-test--ticket-text
           "**" "Story" "S" "S intro.\n*** S-Req\nr-body\n**** S-Edge\ne-body\n" "P-2")
          (org-tickets-test--ticket-text
           "*" "Bug" "T" "**** T-Step\ns-body\n" "P-3")))

(defmacro org-tickets-test--at (text target &rest body)
  "Run BODY in an org buffer of TEXT with point at the start of TARGET."
  (declare (indent 2))
  `(with-temp-buffer
     (insert ,text)
     (org-mode)
     (goto-char (point-min))
     (search-forward ,target)
     (goto-char (match-beginning 0))
     ,@body))

(defun org-tickets-test--owner-title (text target)
  "Return the title of the ticket heading owning TARGET in TEXT."
  (org-tickets-test--at text target
    (let ((pos (org-tickets--ticket-heading-position)))
      (when pos
        (goto-char pos)
        (org-get-heading t t t t)))))

(defun org-tickets-test--heading-title-at-point ()
  "Return the title of the heading at or above point."
  (save-excursion (org-back-to-heading t) (org-get-heading t t t t)))

;;;; Finding the owning ticket

(ert-deftest org-tickets-test--owner-from-each-position ()
  "Every position inside a ticket resolves to that ticket."
  (let ((text (org-tickets-test--ticket-buffer-text)))
    (dolist (case '(("* F" . "F") ("F intro." . "F") ("*** F-Goals" . "F")
                    ("g-body" . "F") ("**** F-Deep" . "F") ("d-body" . "F")
                    ("** S" . "S") ("S intro." . "S") ("*** S-Req" . "S")
                    ("r-body" . "S") ("**** S-Edge" . "S") ("e-body" . "S")
                    ("* T" . "T") ("**** T-Step" . "T") ("s-body" . "T")
                    (":JIRA_KEY: P-2" . "S")))
      (should (equal (cons (car case) (org-tickets-test--owner-title text (car case)))
                     case)))))

(ert-deftest org-tickets-test--owner-for-every-parent-type ()
  "Description headings under any parent type resolve to the parent."
  (dolist (type org-tickets-test--parent-types)
    (let ((text (org-tickets-test--ticket-text "*" type "P" "*** H\n**** HH\nx\n")))
      (should (equal (org-tickets-test--owner-title text "**** HH") "P"))
      (should (equal (org-tickets-test--owner-title text "x\n") "P")))))

(ert-deftest org-tickets-test--owner-heading-with-only-a-key ()
  "A heading with JIRA_KEY but no JIRA_TYPE still owns its own point."
  (let ((text (concat (org-tickets-test--ticket-text "*" "Feature" "F" "" "P-1")
                      "** Legacy\n:PROPERTIES:\n:JIRA_KEY: P-9\n:END:\n*** Notes\nn\n")))
    (should (equal (org-tickets-test--owner-title text "** Legacy") "Legacy"))
    (should (equal (org-tickets-test--owner-title text "*** Notes") "Legacy"))))

(ert-deftest org-tickets-test--owner-falls-back-to-heading-at-point ()
  "With no ticket above, the heading at point is used (old behavior)."
  (let ((text "* Plain\n** Child\nbody\n"))
    (should (equal (org-tickets-test--owner-title text "** Child") "Child"))
    (should (equal (org-tickets-test--owner-title text "body") "Child"))))

(ert-deftest org-tickets-test--owner-before-first-heading-is-nil ()
  "Text before any heading has no owner."
  (should (null (org-tickets-test--owner-title
                 (concat "Preamble.\n" (org-tickets-test--ticket-text "*" "Feature" "F" ""))
                 "Preamble."))))

(ert-deftest org-tickets-test--owner-lookup-keeps-point ()
  "Finding the owner, and running BODY there, leaves point alone."
  (org-tickets-test--at (org-tickets-test--ticket-buffer-text) "e-body"
    (let ((start (point)))
      (org-tickets--ticket-heading-position)
      (should (= (point) start))
      (should (equal (org-tickets--at-ticket-heading (org-get-heading t t t t)) "S"))
      (should (= (point) start)))))

(ert-deftest org-tickets-test--owner-of-folded-description-heading ()
  "Invisible (folded) description headings still resolve."
  (org-tickets-test--at (org-tickets-test--ticket-buffer-text) "**** S-Edge"
    (let ((start (point)))
      (goto-char (point-min))
      (org-cycle-overview)
      (goto-char start)
      (should (equal (org-tickets--at-ticket-heading (org-get-heading t t t t)) "S")))))

;;;; copy-link

(defun org-tickets-test--copied-link (text target)
  "Run `org-tickets-copy-link' at TARGET in TEXT; return the copied URL."
  (let ((copied nil)
        (org-tickets-base-url "https://x.test"))
    (org-tickets-test--with-stubs ((kill-new (lambda (url) (setq copied url)))
                                   (message #'ignore))
      (org-tickets-test--at text target
        (org-tickets-copy-link)))
    copied))

(ert-deftest org-tickets-test--copy-link-from-description-headings ()
  "copy-link from any description position copies the owning ticket."
  (let ((text (org-tickets-test--ticket-buffer-text)))
    (should (equal (org-tickets-test--copied-link text "*** F-Goals")
                   "https://x.test/browse/P-1"))
    (should (equal (org-tickets-test--copied-link text "d-body")
                   "https://x.test/browse/P-1"))
    (should (equal (org-tickets-test--copied-link text "**** S-Edge")
                   "https://x.test/browse/P-2"))
    (should (equal (org-tickets-test--copied-link text "**** T-Step")
                   "https://x.test/browse/P-3"))))

(ert-deftest org-tickets-test--copy-link-for-every-parent-type ()
  (dolist (type org-tickets-test--parent-types)
    (should (equal (org-tickets-test--copied-link
                    (org-tickets-test--ticket-text "*" type "P" "*** H\n" "K-7")
                    "*** H")
                   "https://x.test/browse/K-7"))))

(ert-deftest org-tickets-test--copy-link-unkeyed-ticket-does-not-climb-further ()
  "An unsynced Story's description must not copy its parent's link."
  (let ((text (concat (org-tickets-test--ticket-text "*" "Feature" "F" "" "P-1")
                      (org-tickets-test--ticket-text "**" "Story" "S" "*** H\n"))))
    (org-tickets-test--at text "*** H"
      (let ((org-tickets-base-url "https://x.test"))
        (should-error (org-tickets-copy-link) :type 'user-error)))))

(ert-deftest org-tickets-test--copy-link-keeps-point ()
  (org-tickets-test--with-stubs ((kill-new #'ignore) (message #'ignore))
    (org-tickets-test--at (org-tickets-test--ticket-buffer-text) "r-body"
      (let ((start (point))
            (org-tickets-base-url "https://x.test"))
        (org-tickets-copy-link)
        (should (= (point) start))))))

;;;; Attachment commands

(defmacro org-tickets-test--with-attach-spy (calls &rest body)
  "Run BODY with attachment I/O stubbed, pushing (FN . HEADING) onto CALLS.
HEADING is the title of the heading at point when FN ran."
  (declare (indent 1))
  `(org-tickets-test--with-stubs
       ((org-tickets--get-attachments
         (lambda (key) (push (cons 'get key) ,calls)
           '(((id . "9") (filename . "a.png")))))
        (org-tickets--get-ticket-attach-dir
         (lambda (_create)
           (push (cons 'dir (org-tickets-test--heading-title-at-point)) ,calls) nil))
        (org-tickets--delete-attachment
         (lambda (key id) (push (cons 'delete (cons key id)) ,calls) t))
        (org-attach-attach
         (lambda (&rest _)
           (push (cons 'attach (org-tickets-test--heading-title-at-point)) ,calls)))
        (org-attach-reveal
         (lambda (&rest _)
           (push (cons 'reveal (org-tickets-test--heading-title-at-point)) ,calls)))
        (org-id-get-create
         (lambda (&rest _) (org-entry-put (point) "ID" "fake-id") "fake-id"))
        (completing-read (lambda (&rest _) "a.png"))
        (message #'ignore))
     ,@body))

(ert-deftest org-tickets-test--attach-add-from-description-heading ()
  "attach-add attaches to the Story, and its ID lands on the Story."
  (let ((calls nil))
    (org-tickets-test--with-attach-spy calls
      (org-tickets-test--at (org-tickets-test--ticket-buffer-text) "**** S-Edge"
        (org-tickets-attach-add "/tmp/a.png")
        (should (equal (alist-get 'attach calls) "S"))
        (should (equal (org-entry-get (point) "ID") nil))
        (goto-char (org-tickets--find-ticket-by-key "P-2"))
        (should (equal (org-entry-get (point) "ID") "fake-id"))))))

(ert-deftest org-tickets-test--attach-add-unsynced-ticket-from-description ()
  "An unkeyed ticket still owns attachments added from its description."
  (let ((calls nil))
    (org-tickets-test--with-attach-spy calls
      (org-tickets-test--at (org-tickets-test--ticket-text "**" "Story" "New" "*** H\nx\n")
          "x\n"
        (org-tickets-attach-add "/tmp/a.png")
        (should (equal (alist-get 'attach calls) "New"))))))

(ert-deftest org-tickets-test--attach-open-from-description-heading ()
  (let ((calls nil))
    (org-tickets-test--with-attach-spy calls
      (org-tickets-test--at (org-tickets-test--ticket-buffer-text) "*** F-Goals"
        (org-tickets-attach-open)
        (should (equal (alist-get 'reveal calls) "F"))
        (should-not (org-entry-get (point) "ID"))))))

(ert-deftest org-tickets-test--attach-list-from-description-heading ()
  (let ((calls nil))
    (org-tickets-test--with-attach-spy calls
      (org-tickets-test--at (org-tickets-test--ticket-buffer-text) "**** T-Step"
        (org-tickets-attach-list)
        (should (equal (alist-get 'get calls) "P-3"))
        (should (equal (alist-get 'dir calls) "T"))))))

(ert-deftest org-tickets-test--attach-remove-from-description-heading ()
  (let ((calls nil))
    (org-tickets-test--with-attach-spy calls
      (org-tickets-test--at (org-tickets-test--ticket-buffer-text) "**** F-Deep"
        (org-tickets-attach-remove "a.png")
        (should (equal (alist-get 'delete calls) '("P-1" . "9")))
        (should (equal (alist-get 'dir calls) "F"))))))

(ert-deftest org-tickets-test--attach-remove-interactive-from-description ()
  "The interactive prompt completes over the owning ticket's files."
  (let ((calls nil))
    (org-tickets-test--with-attach-spy calls
      (org-tickets-test--at (org-tickets-test--ticket-buffer-text) "*** S-Req"
        (call-interactively #'org-tickets-attach-remove)
        (should (equal (seq-uniq (mapcar #'cdr (seq-filter (lambda (c) (eq (car c) 'get))
                                                           calls)))
                       '("P-2")))
        (should (equal (alist-get 'delete calls) '("P-2" . "9")))))))

(ert-deftest org-tickets-test--attach-commands-for-every-parent-type ()
  (dolist (type org-tickets-test--parent-types)
    (let ((calls nil))
      (org-tickets-test--with-attach-spy calls
        (org-tickets-test--at (org-tickets-test--ticket-text "*" type "P" "*** H\n" "K-1")
            "*** H"
          (org-tickets-attach-list)
          (org-tickets-attach-remove "a.png")
          (should (equal (alist-get 'get calls) "K-1"))
          (should (equal (alist-get 'delete calls) '("K-1" . "9"))))))))

;;;; Pull remote changes

(defun org-tickets-test--pull-at (text target type description)
  "Pull at TARGET in TEXT, Jira returning DESCRIPTION for a TYPE ticket.
Return (FETCHED-KEY . NEW-BUFFER-TEXT)."
  (let ((fetched nil))
    (org-tickets-test--with-stubs
        ((org-tickets--resolve-config #'ignore)
         (org-tickets--get-ticket (lambda (key) (setq fetched key) key))
         (org-tickets--parse-jira-issue
          (lambda (key)
            (org-tickets--ticket-create :key key :type type :summary "Pulled"
                                        :description description :labels nil)))
         (message #'ignore))
      (org-tickets-test--at text target
        (org-tickets-pull-remote-changes)
        (cons fetched (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest org-tickets-test--pull-from-story-description-heading ()
  "Pulling from inside a Story's headings updates that Story only."
  (let ((result (org-tickets-test--pull-at (org-tickets-test--ticket-buffer-text)
                                           "**** S-Edge" "Story" "*** New\n\nn")))
    (should (equal (car result) "P-2"))
    (should (equal (org-tickets-test--parse-tickets (cdr result))
                   '(("F" . "F intro.\n*** F-Goals\ng-body\n**** F-Deep\nd-body")
                     ("Pulled" . "*** New\n\nn")
                     ("T" . "**** T-Step\ns-body"))))))

(ert-deftest org-tickets-test--pull-from-parent-description-heading ()
  "Pulling from inside a parent's headings keeps its children."
  (dolist (type org-tickets-test--parent-types)
    (let* ((text (concat (org-tickets-test--ticket-text "*" type "P" "*** Old\no\n" "P-1")
                         (org-tickets-test--ticket-text "**" "Story" "S" "s\n" "P-2")))
           (result (org-tickets-test--pull-at text "o\n" type "fresh")))
      (should (equal (car result) "P-1"))
      (should (equal (org-tickets-test--parse-tickets (cdr result))
                     '(("Pulled" . "fresh") ("S" . "s")))))))

(ert-deftest org-tickets-test--pull-from-bug-description-heading ()
  (let ((result (org-tickets-test--pull-at (org-tickets-test--ticket-buffer-text)
                                           "s-body" "Bug" "**** Redo")))
    (should (equal (car result) "P-3"))
    (should (equal (cdr (assoc "Pulled" (org-tickets-test--parse-tickets (cdr result))))
                   "**** Redo"))))

(ert-deftest org-tickets-test--pull-unkeyed-ticket-errors-from-description ()
  "An unsynced ticket errors instead of pulling its parent."
  (let ((text (concat (org-tickets-test--ticket-text "*" "Feature" "F" "" "P-1")
                      (org-tickets-test--ticket-text "**" "Story" "S" "*** H\n"))))
    (should-error (org-tickets-test--pull-at text "*** H" "Story" "x")
                  :type 'user-error)))

(provide 'org-tickets-test-cmd-ticket-at-point)
;;; org-tickets-test-cmd-ticket-at-point.el ends here
