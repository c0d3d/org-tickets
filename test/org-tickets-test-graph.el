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

(provide 'org-tickets-test-graph)

;;; org-tickets-test-graph.el ends here
