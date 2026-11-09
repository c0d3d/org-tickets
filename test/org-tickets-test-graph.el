;;; org-tickets-test-graph.el --- Tests for the ticket dependency graph  -*- lexical-binding: t; -*-

(require 'ert)
(require 'seq)
(require 'org)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

(defun org-tickets-test--graph-of (&rest texts)
  "Return the graph model of an org buffer holding TEXTS concatenated."
  (with-temp-buffer
    (insert (apply #'concat texts))
    (org-mode)
    (org-tickets--graph-model)))

(defun org-tickets-test--graph-node (model id)
  "Return the node plist with ID in graph MODEL."
  (seq-find (lambda (node) (equal (plist-get node :id) id))
            (plist-get model :nodes)))

(defun org-tickets-test--props (&rest pairs)
  "Return a property drawer body line for each (NAME . VALUE) in PAIRS."
  (mapconcat (lambda (pair) (format ":%s: %s\n" (car pair) (cdr pair)))
             pairs ""))

(defun org-tickets-test--keyed-ticket (stars type title key &rest pairs)
  "Return org text for a TYPE ticket TITLE at STARS with KEY and PAIRS props."
  (concat stars " " title "\n:PROPERTIES:\n:JIRA_TYPE: " type "\n"
          ":JIRA_KEY: " key "\n"
          (apply #'org-tickets-test--props pairs)
          ":END:\n"))

(defun org-tickets-test--same-set-p (a b)
  "Non-nil when lists A and B hold the same elements, ignoring order."
  (and (= (length a) (length b))
       (seq-every-p (lambda (x) (member x b)) a)))

;;;; Model

(ert-deftest org-tickets-test--graph-model-nodes-in-document-order ()
  "Nodes come in document order; unkeyed tickets get new-N ids."
  (let* ((model (org-tickets-test--graph-of
                 (org-tickets-test--keyed-ticket
                  "*" "Feature" "Checkout" "PROJ-100"
                  '("DUE_DATE" . "2026-12-01"))
                 (org-tickets-test--ticket-text "**" "Story" "Cart" "" "PROJ-101")
                 (org-tickets-test--ticket-text "**" "Story" "Pay" "")))
         (feature (org-tickets-test--graph-node model "PROJ-100"))
         (story (org-tickets-test--graph-node model "PROJ-101"))
         (new (org-tickets-test--graph-node model "new-1")))
    (should (equal (mapcar (lambda (n) (plist-get n :id))
                           (plist-get model :nodes))
                   '("PROJ-100" "PROJ-101" "new-1")))
    (should (plist-get feature :parent-p))
    (should (equal (plist-get feature :due) "2026-12-01"))
    (should (equal (plist-get feature :type) "Feature"))
    (should-not (plist-get feature :new-p))
    (should-not (plist-get story :parent-p))
    (should (plist-get new :new-p))
    (should-not (plist-get new :key))
    (should-not (plist-get new :external-p))))

(ert-deftest org-tickets-test--graph-model-strips-type-prefix ()
  "A \"Type: \" prefix on the heading is dropped from the node title."
  (let ((model (org-tickets-test--graph-of
                (org-tickets-test--ticket-text
                 "*" "Story" "Story: Login form" "" "PROJ-101"))))
    (should (equal (plist-get (org-tickets-test--graph-node model "PROJ-101")
                              :title)
                   "Login form"))))

(ert-deftest org-tickets-test--graph-model-edges-from-blocks-blocked-by-and-parent ()
  "Edges come from BLOCKS, BLOCKED-BY and the outline parent."
  (let ((edges (plist-get
                (org-tickets-test--graph-of
                 (org-tickets-test--keyed-ticket "*" "Feature" "F" "PROJ-100")
                 (org-tickets-test--keyed-ticket "**" "Story" "A" "PROJ-101"
                                                 '("BLOCKS" . "PROJ-102"))
                 (org-tickets-test--keyed-ticket "*" "Story" "B" "PROJ-102")
                 (org-tickets-test--keyed-ticket "*" "Feature" "G" "PROJ-110")
                 (org-tickets-test--keyed-ticket "**" "Story" "C" "PROJ-103"
                                                 '("BLOCKED-BY" . "PROJ-102")
                                                 '("PARENT" . "PROJ-100")))
                :edges)))
    (should (org-tickets-test--same-set-p
             edges '(("PROJ-101" . "PROJ-102") ("PROJ-102" . "PROJ-103")
                     ("PROJ-101" . "PROJ-100") ("PROJ-103" . "PROJ-100"))))))

(ert-deftest org-tickets-test--graph-model-parent-type-gets-no-parent-edge ()
  "A Feature carrying a PARENT pointer draws no arrow; a story still does."
  (let ((edges (plist-get
                (org-tickets-test--graph-of
                 (org-tickets-test--keyed-ticket "*" "Feature" "F" "PROJ-100"
                                                 '("PARENT" . "PROJ-1"))
                 (org-tickets-test--keyed-ticket "**" "Story" "S" "PROJ-101"))
                :edges)))
    (should (equal edges '(("PROJ-101" . "PROJ-100"))))))

(ert-deftest org-tickets-test--graph-model-ignores-narrowing ()
  "A narrowed buffer still yields the whole file's graph; narrowing is kept."
  (with-temp-buffer
    (insert (org-tickets-test--keyed-ticket "*" "Feature" "F1" "PROJ-100")
            (org-tickets-test--keyed-ticket "**" "Story" "A" "PROJ-101"
                                            '("BLOCKS" . "PROJ-102"))
            (org-tickets-test--keyed-ticket "*" "Feature" "F2" "PROJ-200")
            (org-tickets-test--keyed-ticket "**" "Story" "B" "PROJ-102"
                                            '("BLOCKS" . "PROJ-103"))
            (org-tickets-test--keyed-ticket "**" "Story" "C" "PROJ-103"
                                            '("BLOCKS" . "PROJ-101")))
    (org-mode)
    (goto-char (point-min))
    (org-narrow-to-subtree)
    (let ((start (point-min)) (end (point-max))
          (model (org-tickets--graph-model)))
      (should (= start (point-min)))
      (should (= end (point-max)))
      (should (seq-every-p (lambda (n) (not (plist-get n :external-p)))
                           (plist-get model :nodes)))
      (should (org-tickets--graph-cycles (plist-get model :edges))))))

(ert-deftest org-tickets-test--graph-model-deduplicates-edges ()
  "A link stated from both ends yields a single edge."
  (let ((edges (plist-get
                (org-tickets-test--graph-of
                 (org-tickets-test--keyed-ticket "*" "Story" "A" "PROJ-101"
                                                 '("BLOCKS" . "PROJ-102"))
                 (org-tickets-test--keyed-ticket "*" "Story" "B" "PROJ-102"
                                                 '("BLOCKED-BY" . "PROJ-101")))
                :edges)))
    (should (equal edges '(("PROJ-101" . "PROJ-102"))))))

(ert-deftest org-tickets-test--graph-model-unsynced-parent-gets-edge ()
  "A story under an unkeyed feature points at the feature's new-N id."
  (let ((edges (plist-get
                (org-tickets-test--graph-of
                 (org-tickets-test--ticket-text "*" "Feature" "F" "")
                 (org-tickets-test--ticket-text "**" "Story" "S" "" "PROJ-201"))
                :edges)))
    (should (equal edges '(("PROJ-201" . "new-1"))))))

(ert-deftest org-tickets-test--graph-model-external-keys-become-external-nodes ()
  "A key not in the buffer becomes an external node with an edge to it."
  (let* ((model (org-tickets-test--graph-of
                 (org-tickets-test--keyed-ticket "*" "Story" "A" "PROJ-101"
                                                 '("BLOCKS" . "PROJ-999"))))
         (external (org-tickets-test--graph-node model "PROJ-999")))
    (should (equal (mapcar (lambda (n) (plist-get n :id))
                           (plist-get model :nodes))
                   '("PROJ-101" "PROJ-999")))
    (should (plist-get external :external-p))
    (should (equal (plist-get external :key) "PROJ-999"))
    (should-not (plist-get external :type))
    (should (equal (plist-get model :edges) '(("PROJ-101" . "PROJ-999"))))))

;;;; Cycles

(ert-deftest org-tickets-test--graph-cycles-finds-two-node-loop ()
  "Two tickets blocking each other form one cycle."
  (let ((cycles (org-tickets--graph-cycles '(("A" . "B") ("B" . "A") ("C" . "A")))))
    (should (= (length cycles) 1))
    (should (org-tickets-test--same-set-p (car cycles) '("A" "B")))))

(ert-deftest org-tickets-test--graph-cycles-finds-self-loop ()
  "A ticket blocking itself is a one-node cycle."
  (should (equal (org-tickets--graph-cycles '(("A" . "A") ("A" . "B")))
                 '(("A")))))

(ert-deftest org-tickets-test--graph-cycles-none-for-dag ()
  "An acyclic graph has no cycles."
  (should-not (org-tickets--graph-cycles
               '(("A" . "B") ("B" . "C") ("A" . "C") ("D" . "C")))))

(ert-deftest org-tickets-test--graph-cycles-in-loop-order ()
  "A cycle's ids follow the edges around the loop."
  (let ((cycle (car (org-tickets--graph-cycles
                     '(("A" . "B") ("B" . "C") ("C" . "A"))))))
    (should (= (length cycle) 3))
    (let ((pairs (seq-mapn #'cons cycle (append (cdr cycle) (list (car cycle))))))
      (should (seq-every-p
               (lambda (p) (member p '(("A" . "B") ("B" . "C") ("C" . "A"))))
               pairs)))))

(ert-deftest org-tickets-test--graph-cycle-edges-only-loop-members ()
  "Only edges inside a loop count as cycle edges."
  (should (org-tickets-test--same-set-p
           (org-tickets--graph-cycle-edges '(("A" . "B") ("B" . "A") ("C" . "A")))
           '(("A" . "B") ("B" . "A")))))

(ert-deftest org-tickets-test--graph-cycle-edges-include-self-edges ()
  "A self-edge is a cycle edge."
  (should (equal (org-tickets--graph-cycle-edges '(("A" . "A") ("A" . "B")))
                 '(("A" . "A")))))

(ert-deftest org-tickets-test--graph-cycles-two-disjoint-loops ()
  "Two separate loops are two cycles, and every loop edge is a cycle edge."
  (let ((edges '(("A" . "B") ("B" . "A") ("C" . "D") ("D" . "C") ("A" . "C"))))
    (should (= (length (org-tickets--graph-cycles edges)) 2))
    (should (org-tickets-test--same-set-p
             (org-tickets--graph-cycle-edges edges)
             '(("A" . "B") ("B" . "A") ("C" . "D") ("D" . "C"))))))

;;;; DOT

(defun org-tickets-test--dot-node (&rest args)
  "Return a node plist for DOT tests: ARGS override a plain keyed story."
  (append args (list :id "PROJ-100" :key "PROJ-100" :type "Story"
                     :title "Login" :due nil :parent-p nil
                     :new-p nil :external-p nil)))

(defun org-tickets-test--dot-of (nodes &optional edges)
  "Return the DOT text for NODES and EDGES."
  (org-tickets--graph-dot (list :nodes nodes :edges edges)))

(ert-deftest org-tickets-test--graph-dot-parent-node-style-and-rank ()
  "Parent nodes are gold, double-outlined, larger and ranked to the top."
  (let ((dot (org-tickets-test--dot-of
              (list (org-tickets-test--dot-node
                     :type "Feature" :parent-p t :title "Auth")))))
    (should (string-match-p "digraph tickets {" dot))
    (should (string-match-p "rankdir=TB; nodesep=0.4; ranksep=0.6;" dot))
    (should (string-match-p "{ rank=min; \"PROJ-100\"" dot))
    (should (string-match-p "fillcolor=\"#fff2cc\"" dot))
    (should (string-match-p "color=\"#bf9000\", penwidth=2.5, peripheries=2" dot))
    (should (string-match-p "fontsize=15, margin=\"0.3,0.15\"" dot))
    (should (string-match-p "<B>FEATURE · PROJ-100</B><BR/>Auth" dot))))

(ert-deftest org-tickets-test--graph-dot-label-key-title-due ()
  "A node label holds bold key, title and a due line."
  (let ((dot (org-tickets-test--dot-of
              (list (org-tickets-test--dot-node :due "2026-12-01")))))
    (should (string-match-p
             (regexp-quote "<<B>PROJ-100</B><BR/>Login<BR/><FONT POINT-SIZE=\"10\">due 2026-12-01</FONT>>")
             dot))))

(ert-deftest org-tickets-test--graph-dot-label-omits-due-when-absent ()
  "Without a due date there is no due line."
  (let ((dot (org-tickets-test--dot-of (list (org-tickets-test--dot-node)))))
    (should (string-match-p (regexp-quote "<<B>PROJ-100</B><BR/>Login>") dot))
    (should-not (string-match-p "due " dot))))

(ert-deftest org-tickets-test--graph-dot-truncates-long-title ()
  "Titles over the width are cut to exactly the width, ending in an ellipsis."
  (let* ((org-tickets-graph-title-width 10)
         (dot (org-tickets-test--dot-of
               (list (org-tickets-test--dot-node
                     :title "A very long ticket title")))))
    (should (string-match-p (regexp-quote "<BR/>A very lo…>") dot))
    (should-not (string-match-p "A very long" dot))))

(ert-deftest org-tickets-test--graph-dot-keeps-title-at-width ()
  "A title exactly at the width is left alone."
  (let ((org-tickets-graph-title-width 5))
    (should (string-match-p "<BR/>Login>"
                            (org-tickets-test--dot-of
                             (list (org-tickets-test--dot-node)))))))

(ert-deftest org-tickets-test--graph-dot-new-node-dashed-labelled-new ()
  "A new node shows (new) for its key and has a dashed border."
  (let ((dot (org-tickets-test--dot-of
              (list (org-tickets-test--dot-node
                     :id "new-1" :key nil :new-p t)))))
    (should (string-match-p "\"new-1\" \\[.*style=\"rounded,filled,dashed\"" dot))
    (should (string-match-p (regexp-quote "<B>(new)</B>") dot))))

(ert-deftest org-tickets-test--graph-dot-external-node-style ()
  "An external node is a small grey dashed box labelled with its key only."
  (let ((dot (org-tickets-test--dot-of
              (list (org-tickets-test--dot-node
                     :external-p t :title nil :type nil)))))
    (should (string-match-p
             "style=\"rounded,dashed\", fillcolor=\"#ffffff\", color=\"#aaaaaa\", fontcolor=\"#888888\", fontsize=10"
             dot))
    (should (string-match-p "label=\"PROJ-100\"" dot))))

(ert-deftest org-tickets-test--graph-dot-edge-points-blocker-to-blocked ()
  "An edge (FROM . TO) is written TO -> FROM."
  (let ((dot (org-tickets-test--dot-of nil '(("PROJ-101" . "PROJ-100")))))
    (should (string-match-p (regexp-quote "\"PROJ-100\" -> \"PROJ-101\"") dot))
    (should (string-match-p "arrowsize=0.8, color=\"#666666\", dir=back" dot))))

(ert-deftest org-tickets-test--graph-dot-cycle-edges-red ()
  "Edges in a loop are thick red; others are not."
  (let ((dot (org-tickets-test--dot-of
              nil '(("A" . "B") ("B" . "A") ("C" . "A")))))
    (should (string-match-p
             "\"B\" -> \"A\" \\[color=\"#d62728\", penwidth=2.5\\]" dot))
    (should (string-match-p
             "\"A\" -> \"B\" \\[color=\"#d62728\", penwidth=2.5\\]" dot))
    (let ((line (seq-find (lambda (l) (string-match-p "\"A\" -> \"C\"" l))
                          (split-string dot "\n"))))
      (should line)
      (should-not (string-match-p "d62728" line)))))

(ert-deftest org-tickets-test--graph-dot-escapes-html ()
  "Special characters in a title are HTML-escaped."
  (let ((dot (org-tickets-test--dot-of
              (list (org-tickets-test--dot-node :title "A & <B> \"c\"")))))
    (should (string-match-p (regexp-quote "A &amp; &lt;B&gt; &quot;c&quot;") dot))))

(ert-deftest org-tickets-test--graph-dot-empty-model-is-valid ()
  "An empty model yields a digraph with no nodes."
  (let ((dot (org-tickets-test--dot-of nil)))
    (should (string-prefix-p "digraph tickets {" dot))
    (should (string-suffix-p "}" (string-trim dot)))
    (should-not (string-match-p "->" dot))
    (should-not (string-match-p "label=" dot))))

(ert-deftest org-tickets-test--graph-dot-accepted-by-graphviz ()
  "Graphviz renders the DOT for a mixed model to SVG."
  (unless (executable-find "dot") (ert-skip "dot not installed"))
  (let ((dot (org-tickets-test--dot-of
              (list (org-tickets-test--dot-node
                     :type "Feature" :parent-p t :due "2026-12-01")
                    (org-tickets-test--dot-node
                     :id "new-1" :key nil :new-p t :title "A & <B>")
                    (org-tickets-test--dot-node
                     :id "PROJ-200" :key "PROJ-200" :external-p t :title nil))
              '(("new-1" . "PROJ-100") ("PROJ-200" . "new-1")
                ("new-1" . "PROJ-200")))))
    (with-temp-buffer
      (insert dot)
      (should (= 0 (call-process-region (point-min) (point-max) "dot"
                                        t t nil "-Tsvg")))
      (should (string-match-p "<svg" (buffer-string))))))

(ert-deftest org-tickets-test--graph-dot-quotes-in-ids-stay-valid ()
  "Quotes and backslashes in ticket and external keys are escaped in DOT."
  (let ((dot (org-tickets-test--dot-of
              (list (org-tickets-test--dot-node :id "P\"1\\x" :key "P\"1\\x")
                    (org-tickets-test--dot-node
                     :id "E\"2" :key "E\"2" :external-p t :title nil))
              '(("E\"2" . "P\"1\\x")))))
    (should (string-match-p (regexp-quote "\"P\\\"1\\\\x\" [label=") dot))
    (should (string-match-p (regexp-quote "\"E\\\"2\" [label=\"E\\\"2\"") dot))
    (should (string-match-p
             (regexp-quote "\"P\\\"1\\\\x\" -> \"E\\\"2\"") dot))
    (when (executable-find "dot")
      (with-temp-buffer
        (insert dot)
        (should (= 0 (call-process-region (point-min) (point-max) "dot"
                                          t t nil "-Tsvg")))))))

(ert-deftest org-tickets-test--graph-dot-title-width-below-one-keeps-one-char ()
  "A title width of zero or less is treated as one character."
  (let ((org-tickets-graph-title-width 0))
    (should (string-match-p "<BR/>…>"
                            (org-tickets-test--dot-of
                             (list (org-tickets-test--dot-node)))))))

;;;; Command

(defconst org-tickets-test--graph-loop-text
  (concat (org-tickets-test--keyed-ticket "*" "Feature" "Checkout" "PROJ-100")
          (org-tickets-test--keyed-ticket "**" "Story" "Cart" "PROJ-101")
          (org-tickets-test--keyed-ticket "**" "Story" "Pay" "PROJ-102"
                                          '("BLOCKS" . "PROJ-103"))
          (org-tickets-test--keyed-ticket "**" "Story" "Ship" "PROJ-103"
                                          '("BLOCKS" . "PROJ-102")))
  "Org text with a feature, stories and a two-ticket loop.")

(defmacro org-tickets-test--with-graph-file (text &rest body)
  "Run BODY visiting org file \"tickets.org\" holding TEXT, in a spaced temp dir.
Binds `file' to the file name and `messages' (a list, newest first) to
what the command echoes.  Windows are not opened; the directory and
every buffer visiting files in it are removed afterwards."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "org tickets graph" t))
          (file (expand-file-name "tickets.org" dir))
          (messages nil))
     (unwind-protect
         (progn
           (with-temp-file file (insert ,text))
           (org-tickets-test--with-stubs
               ((find-file-other-window
                 (lambda (f &rest _) (find-file-noselect f)))
                (message (lambda (fmt &rest args)
                           (push (apply #'format fmt args) messages))))
             (with-current-buffer (find-file-noselect file)
               (unwind-protect (progn ,@body)
                 (kill-buffer (current-buffer))))))
       (dolist (buf (buffer-list))
         (when (and (buffer-file-name buf)
                    (string-prefix-p dir (buffer-file-name buf)))
           (with-current-buffer buf (set-buffer-modified-p nil))
           (kill-buffer buf)))
       (delete-directory dir t))))

(ert-deftest org-tickets-test--graph-command-requires-file ()
  "An org buffer that visits no file asks to be saved first."
  (with-temp-buffer
    (org-mode)
    (let ((err (should-error (org-tickets-graph) :type 'user-error)))
      (should (string-match-p "Save the buffer" (cadr err))))))

(ert-deftest org-tickets-test--graph-command-requires-org-mode ()
  "Outside org-mode the command refuses."
  (with-temp-buffer
    (fundamental-mode)
    (should-error (org-tickets-graph) :type 'user-error)))

(ert-deftest org-tickets-test--graph-command-missing-dot ()
  "A missing dot program is reported with the variable to set."
  (org-tickets-test--with-graph-file ""
    (let* ((org-tickets-graph-dot-program "no-such-dot-program-xyz")
           (err (should-error (org-tickets-graph) :type 'user-error)))
      (should (string-match-p "org-tickets-graph-dot-program" (cadr err)))
      (should (string-match-p "no-such-dot-program-xyz" (cadr err))))))

(ert-deftest org-tickets-test--graph-command-writes-svg-beside-file ()
  "The command writes tickets.svg beside the org file and reports the loop."
  (unless (executable-find "dot") (ert-skip "dot not installed"))
  (org-tickets-test--with-graph-file org-tickets-test--graph-loop-text
    (let* ((out (org-tickets-graph))
           (svg (expand-file-name "tickets.svg" (file-name-directory file))))
      (should (equal out svg))
      (should (file-exists-p svg))
      (with-temp-buffer
        (insert-file-contents svg)
        (should (string-match-p "<svg" (buffer-string)))
        (should (string-match-p "#d62728" (buffer-string))))
      (should (string-match-p
               (regexp-quote "1 cycle: PROJ-102 → PROJ-103 → PROJ-102")
               (car messages)))
      (should (string-match-p (regexp-quote svg) (car messages))))))

(ert-deftest org-tickets-test--graph-command-rerun-refreshes-open-svg ()
  "Running again updates an already-open SVG buffer without prompting."
  (unless (executable-find "dot") (ert-skip "dot not installed"))
  (org-tickets-test--with-graph-file org-tickets-test--graph-loop-text
    (let ((svg (org-tickets-graph)))
      (with-current-buffer (find-file-noselect svg)
        (should-not (string-match-p "Brand New Title" (buffer-string))))
      (goto-char (point-max))
      (insert (org-tickets-test--keyed-ticket "*" "Story" "Brand New Title"
                                              "PROJ-200"))
      (org-tickets-graph)
      (with-current-buffer (find-file-noselect svg)
        (should (string-match-p "Brand New Title" (buffer-string)))))))

(ert-deftest org-tickets-test--graph-command-empty-file ()
  "A file without tickets still produces an SVG and reports no cycles."
  (unless (executable-find "dot") (ert-skip "dot not installed"))
  (org-tickets-test--with-graph-file "* Notes\n"
    (let ((svg (org-tickets-graph)))
      (should (file-exists-p svg))
      (should (string-match-p "no cycles" (car messages))))))

(ert-deftest org-tickets-test--graph-command-dot-failure-reports-stderr ()
  "A failing dot run signals a user-error carrying its output."
  (unless (executable-find "false") (ert-skip "false not installed"))
  (org-tickets-test--with-graph-file org-tickets-test--graph-loop-text
    (let ((org-tickets-graph-dot-program "false"))
      (should-error (org-tickets-graph) :type 'user-error))))

(defmacro org-tickets-test--with-stub-dot (script &rest body)
  "Run BODY with `org-tickets-graph-dot-program' a temp executable running SCRIPT."
  (declare (indent 1))
  `(let ((stub (make-temp-file "stub-dot" nil ".sh"))
         (org-tickets-graph-dot-program nil))
     (unwind-protect
         (progn
           (with-temp-file stub (insert "#!/bin/sh\n" ,script "\n"))
           (set-file-modes stub #o755)
           (setq org-tickets-graph-dot-program stub)
           ,@body)
       (delete-file stub))))

(ert-deftest org-tickets-test--graph-command-dot-failure-includes-stderr ()
  "A dot that writes to stderr and exits 1 yields its text in the error."
  (unless (executable-find "sh") (ert-skip "no sh"))
  (org-tickets-test--with-graph-file org-tickets-test--graph-loop-text
    (org-tickets-test--with-stub-dot "echo 'bad graph syntax' >&2; exit 1"
      (let ((err (should-error (org-tickets-graph) :type 'user-error)))
        (should (string-match-p "bad graph syntax" (cadr err)))))))

(ert-deftest org-tickets-test--graph-command-silent-failure-includes-exit-code ()
  "A dot that fails without output still reports its exit code."
  (unless (executable-find "sh") (ert-skip "no sh"))
  (org-tickets-test--with-graph-file org-tickets-test--graph-loop-text
    (org-tickets-test--with-stub-dot "exit 3"
      (let ((err (should-error (org-tickets-graph) :type 'user-error)))
        (should (string-match-p "exit.*3" (cadr err)))))))

(ert-deftest org-tickets-test--graph-command-unrunnable-dot-is-user-error ()
  "A dot program that exists but cannot be executed gives a helpful error."
  (org-tickets-test--with-graph-file org-tickets-test--graph-loop-text
    (let ((prog (make-temp-file "not-exec")))
      (unwind-protect
          (let* ((org-tickets-graph-dot-program prog)
                 (err (should-error (org-tickets-graph) :type 'user-error)))
            (should (string-match-p "org-tickets-graph-dot-program" (cadr err)))
            (should (string-match-p (regexp-quote prog) (cadr err))))
        (delete-file prog)))))

(ert-deftest org-tickets-test--graph-cycle-text-formats ()
  "Simple loops repeat their first id; other groups list members; self-loops."
  (should (equal (org-tickets--graph-cycle-text
                  '("A" "B") '(("A" . "B") ("B" . "A")))
                 "A → B → A"))
  (should (equal (org-tickets--graph-cycle-text '("A") '(("A" . "A")))
                 "A → A"))
  (should (equal (org-tickets--graph-cycle-text
                  '("A" "B" "C")
                  '(("A" . "B") ("B" . "A") ("A" . "C") ("C" . "A")))
                 "loop among: A, B, C"))
  (should (equal (org-tickets--graph-cycle-text
                  '("A" "B" "C")
                  '(("A" . "B") ("B" . "C") ("C" . "A") ("C" . "B")))
                 "loop among: A, B, C")))

(provide 'org-tickets-test-graph)

;;; org-tickets-test-graph.el ends here
