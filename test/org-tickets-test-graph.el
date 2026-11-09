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
    (should (string-match-p "\"A\" -> \"C\"[^[]*$" dot))))

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

(provide 'org-tickets-test-graph)

;;; org-tickets-test-graph.el ends here
