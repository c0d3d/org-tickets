;;; org-tickets-test-graph-render.el --- Tests for graph styling and rendering  -*- lexical-binding: t; -*-

;;; Commentary:

;; Node styling, the echo-area summary, and running Graphviz.  Graphviz
;; is never run here: `call-process-region' and `executable-find' are
;; stubbed, so these pass without `dot' installed.

;;; Code:

(require 'ert)
(require 'seq)
(require 'org)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; Styling

(ert-deftest org-tickets-test--graph-new-parent-node-is-gold-and-dashed ()
  "A new Feature keeps the parent styling, is dashed and labelled (new)."
  (let* ((node (list :id "new-1" :key nil :type "Feature" :title "Auth"
                     :due nil :parent-p t :new-p t :external-p nil))
         (dot (org-tickets--graph-dot (list :nodes (list node) :edges nil) nil)))
    (should (string-match-p "fillcolor=\"#fff2cc\", color=\"#bf9000\"" dot))
    (should (string-match-p (regexp-quote "style=\"rounded,filled,dashed\"") dot))
    (should (string-match-p (regexp-quote "<B>FEATURE · (new)</B>") dot))))

;;;; Summary

(ert-deftest org-tickets-test--graph-summary-two-cycles-in-appearance-order ()
  "Two loops are reported in the plural, in order of first appearance."
  (let* ((edges '(("C" . "D") ("D" . "C") ("A" . "B") ("B" . "A")))
         (cycles (org-tickets--graph-cycles edges)))
    (should (equal (org-tickets--graph-summary "t.svg" cycles edges)
                   (concat "org-tickets: wrote t.svg — 2 cycles: "
                           "C → D → C; A → B → A")))))

(ert-deftest org-tickets-test--graph-summary-one-cycle-is-singular ()
  "A single loop is reported as \"1 cycle\"."
  (let ((edges '(("A" . "B") ("B" . "A"))))
    (should (equal (org-tickets--graph-summary
                    "t.svg" (org-tickets--graph-cycles edges) edges)
                   "org-tickets: wrote t.svg — 1 cycle: A → B → A"))))

;;;; Running dot

(defmacro org-tickets-test--with-fake-dot (status output calls &rest body)
  "Run BODY with `call-process-region' faking a dot run.
The fake replaces the region with OUTPUT and returns STATUS.  Each call
is pushed onto CALLS as (INPUT PROGRAM ARGS)."
  (declare (indent 3))
  `(org-tickets-test--with-stubs
       ((call-process-region
         (lambda (start end program _delete _buffer _display &rest args)
           (push (list (buffer-substring start end) program args) ,calls)
           (delete-region start end)
           (insert ,output)
           ,status)))
     ,@body))

(ert-deftest org-tickets-test--graph-run-dot-passes-buffer-and-output-file ()
  "dot reads the buffer text and is told to write SVG to OUT."
  (let ((calls nil) (org-tickets-graph-dot-program "my-dot"))
    (org-tickets-test--with-fake-dot 0 "" calls
      (with-temp-buffer
        (insert "digraph {}")
        (should (eq 0 (org-tickets--graph-run-dot "/x/out.svg")))))
    (should (equal calls '(("digraph {}" "my-dot" ("-Tsvg" "-o" "/x/out.svg")))))))

(ert-deftest org-tickets-test--graph-run-dot-unstartable-is-user-error ()
  "A dot that cannot be started names the program and the variable."
  (let ((org-tickets-graph-dot-program "my-dot"))
    (org-tickets-test--with-stubs
        ((call-process-region
          (lambda (&rest _)
            (signal 'file-error '("Searching for program" "No such file" "my-dot")))))
      (with-temp-buffer
        (let ((err (should-error (org-tickets--graph-run-dot "/x/out.svg")
                                 :type 'user-error)))
          (should (string-match-p "my-dot" (cadr err)))
          (should (string-match-p "org-tickets-graph-dot-program" (cadr err))))))))

(ert-deftest org-tickets-test--graph-render-nonzero-exit-is-user-error ()
  "A dot failure reports the exit status and dot's output."
  (let ((calls nil) (org-tickets-graph-dot-program "my-dot"))
    (org-tickets-test--with-fake-dot 2 "syntax error in line 1\n" calls
      (let ((err (should-error (org-tickets--graph-render "digraph {" "/x/o.svg")
                               :type 'user-error)))
        (should (equal (cadr err)
                       "my-dot failed (exit 2): syntax error in line 1"))))))

(ert-deftest org-tickets-test--graph-render-success-sends-dot-text ()
  "A successful render sends the DOT text to dot and signals nothing."
  (let ((calls nil))
    (org-tickets-test--with-fake-dot 0 "" calls
      (org-tickets--graph-render "digraph { a }" "/x/o.svg"))
    (should (equal (car (car calls)) "digraph { a }"))))

(defmacro org-tickets-test--in-fake-org-file (&rest body)
  "Run BODY in an org buffer pretending to visit /fake/dir/tickets.org."
  (declare (indent 0))
  `(with-temp-buffer
     (org-mode)
     (setq buffer-file-name "/fake/dir/tickets.org")
     (unwind-protect (progn ,@body)
       (set-buffer-modified-p nil)
       (setq buffer-file-name nil))))

(ert-deftest org-tickets-test--graph-command-dot-not-found-stubbed ()
  "When dot is not on the path, the command stops before running anything."
  (let ((calls nil))
    (org-tickets-test--in-fake-org-file
      (org-tickets-test--with-fake-dot 0 "" calls
        (org-tickets-test--with-stubs ((executable-find (lambda (&rest _) nil)))
          (let ((err (should-error (org-tickets-graph) :type 'user-error)))
            (should (string-match-p "Cannot find" (cadr err)))))))
    (should-not calls)))

(ert-deftest org-tickets-test--graph-command-dot-failure-stubbed ()
  "A non-zero dot exit fails the command before anything is shown."
  (let ((calls nil) (shown nil))
    (org-tickets-test--in-fake-org-file
      (insert "* S\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: PROJ-1\n:END:\n")
      (org-tickets-test--with-fake-dot 1 "boom" calls
        (org-tickets-test--with-stubs
            ((executable-find (lambda (&rest _) "/usr/bin/dot"))
             (org-tickets--graph-show (lambda (file) (setq shown file))))
          (let ((err (should-error (org-tickets-graph) :type 'user-error)))
            (should (string-match-p "exit 1.*boom" (cadr err)))))))
    (should-not shown)))

(ert-deftest org-tickets-test--graph-command-success-stubbed ()
  "The command renders the buffer's graph beside its file and shows it."
  (let ((calls nil) (shown nil) (messages nil))
    (org-tickets-test--in-fake-org-file
      (insert "* S\n:PROPERTIES:\n:JIRA_TYPE: Story\n:JIRA_KEY: PROJ-1\n:END:\n")
      (org-tickets-test--with-fake-dot 0 "" calls
        (org-tickets-test--with-stubs
            ((executable-find (lambda (&rest _) "/usr/bin/dot"))
             (org-tickets--graph-show (lambda (file) (setq shown file)))
             (message (lambda (fmt &rest args)
                        (push (apply #'format fmt args) messages))))
          (should (equal (org-tickets-graph) "/fake/dir/tickets.svg")))))
    (should (equal shown "/fake/dir/tickets.svg"))
    (should (string-match-p "\"PROJ-1\" \\[label=" (car (car calls))))
    (should (equal (car messages)
                   "org-tickets: wrote /fake/dir/tickets.svg — no cycles"))))

;;;; Showing the SVG

(ert-deftest org-tickets-test--graph-show-refreshes-visiting-buffer ()
  "A buffer already visiting the SVG is reverted before it is shown."
  (let* ((dir (make-temp-file "graph-show" t))
         (file (expand-file-name "t.svg" dir))
         (shown nil))
    (unwind-protect
        (progn
          (with-temp-file file (insert "old"))
          (let ((buf (find-file-noselect file)))
            (with-temp-file file (insert "new"))
            (org-tickets-test--with-stubs
                ((find-file-other-window (lambda (f &rest _) (setq shown f))))
              (org-tickets--graph-show file))
            (should (equal (with-current-buffer buf (buffer-string)) "new"))
            (kill-buffer buf)))
      (delete-directory dir t))
    (should (equal shown file))))

(ert-deftest org-tickets-test--graph-show-opens-unvisited-file ()
  "A file no buffer visits is simply opened in another window."
  (let ((shown nil))
    (org-tickets-test--with-stubs
        ((find-file-other-window (lambda (f &rest _) (setq shown f))))
      (org-tickets--graph-show "/nonexistent/dir/t.svg"))
    (should (equal shown "/nonexistent/dir/t.svg"))))

(provide 'org-tickets-test-graph-render)

;;; org-tickets-test-graph-render.el ends here
