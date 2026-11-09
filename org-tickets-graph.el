;;; org-tickets-graph.el --- Ticket dependency graph for org-tickets  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Neil Locketz

;; Author: Neil Locketz <neil@nlocketz.com>
;; Keywords: outlines, comm, tools

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Ticket dependency graph for org-tickets: a node/edge model of the
;; tickets in an org buffer (edges point from blocker to blocked, from
;; BLOCKS, BLOCKED-BY and each ticket's parent) and detection of the
;; dependency loops in it.

;;; Code:

(require 'seq)
(require 'org)
(require 'org-tickets-core)
(require 'org-tickets-parse)
(require 'org-tickets-import)

;;;; Model

(defun org-tickets--graph-vertices (edges)
  "Return the node ids at either end of EDGES, unique, in order of appearance."
  (seq-uniq (mapcan (lambda (edge) (list (car edge) (cdr edge))) edges)))

(defun org-tickets--graph-ticket-ids (tickets)
  "Return a node id for each of TICKETS, in order.
A ticket's id is its key, or \"new-N\" (N counting from 1) when unkeyed."
  (let ((n 0))
    (mapcar (lambda (ticket)
              (or (org-tickets--non-empty-string (org-tickets--ticket-key ticket))
                  (format "new-%d" (setq n (1+ n)))))
            tickets)))

(defun org-tickets--graph-ticket-node (ticket id)
  "Return the node plist for TICKET with node ID."
  (let ((key (org-tickets--non-empty-string (org-tickets--ticket-key ticket)))
        (type (org-tickets--ticket-type ticket)))
    (list :id id :key key :type type
          :title (org-tickets--strip-type-prefix
                  type (org-tickets--ticket-summary ticket))
          :due (org-tickets--ticket-due-date ticket)
          :parent-p (org-tickets--parent-type-p type)
          :new-p (null key)
          :external-p nil)))

(defun org-tickets--graph-external-node (key)
  "Return the node plist for KEY, a ticket not in the buffer."
  (list :id key :key key :type nil :title nil :due nil
        :parent-p nil :new-p nil :external-p t))

(defun org-tickets--graph-parent-heading-id (headings)
  "Return the id of the parent-type ticket heading at point, or nil.
HEADINGS maps each ticket heading position to (ID . TYPE)."
  (let ((heading (assoc (point) headings)))
    (when (and heading (org-tickets--parent-type-p (cddr heading)))
      (cadr heading))))

(defun org-tickets--graph-ancestor-id (ticket headings)
  "Return the id of the nearest parent-type ticket above TICKET, or nil.
HEADINGS maps each ticket heading position to (ID . TYPE)."
  (save-excursion
    (goto-char (org-tickets--ticket-marker ticket))
    (let ((found nil))
      (while (and (not found) (org-up-heading-safe))
        (setq found (org-tickets--graph-parent-heading-id headings)))
      found)))

(defun org-tickets--graph-ticket-edges (ticket id headings)
  "Return the (FROM . TO) edges stated by TICKET, whose node id is ID.
HEADINGS is as for `org-tickets--graph-ancestor-id'."
  (let ((parent (or (org-tickets--ticket-parent ticket)
                    (org-tickets--graph-ancestor-id ticket headings))))
    (append (mapcar (lambda (key) (cons id key))
                    (org-tickets--ticket-blocks ticket))
            (mapcar (lambda (key) (cons key id))
                    (org-tickets--ticket-blocked-by ticket))
            (when (and parent (org-tickets--child-type-p
                               (org-tickets--ticket-type ticket)))
              (list (cons id parent))))))

(defun org-tickets--graph-external-keys (edges ids)
  "Return the ends of EDGES not in IDS, unique, in order of appearance."
  (seq-remove (lambda (end) (member end ids))
              (org-tickets--graph-vertices edges)))

(defun org-tickets--graph-build (tickets)
  "Return the graph model plist (:nodes :edges) for parsed TICKETS."
  (let* ((ids (org-tickets--graph-ticket-ids tickets))
         (headings (seq-mapn (lambda (ticket id)
                               (cons (marker-position
                                      (org-tickets--ticket-marker ticket))
                                     (cons id (org-tickets--ticket-type ticket))))
                             tickets ids))
         (edges (seq-uniq
                 (mapcan (lambda (pair)
                           (org-tickets--graph-ticket-edges
                            (car pair) (cdr pair) headings))
                         (seq-mapn #'cons tickets ids)))))
    (list :nodes (append (seq-mapn #'org-tickets--graph-ticket-node tickets ids)
                         (mapcar #'org-tickets--graph-external-node
                                 (org-tickets--graph-external-keys edges ids)))
          :edges edges)))

(defun org-tickets--graph-model ()
  "Return the dependency graph of the tickets in the current org buffer.
The result is a plist (:nodes NODES :edges EDGES).  NODES lists one
plist per ticket in document order, then one per key referenced but
not in the buffer (:external-p t).  EDGES lists unique (FROM . TO)
node-id pairs meaning FROM blocks TO, from each ticket's BLOCKS,
BLOCKED-BY and, for child-type tickets, parent (its PARENT key, else
the nearest ancestor parent-type ticket heading).  Narrowing is ignored."
  (let ((tickets (save-excursion
                   (save-restriction
                     (widen)
                     (org-tickets--doc-tickets (org-tickets--parse-document))))))
    (unwind-protect
        (org-tickets--graph-build tickets)
      (dolist (ticket tickets)
        (set-marker (org-tickets--ticket-marker ticket) nil)))))

;;;; Loops

(defun org-tickets--graph-adjacency (edges &optional reverse)
  "Return a hash table mapping each node id to its successors along EDGES.
Successors keep edge order.  With REVERSE, follow EDGES backwards."
  (let ((adjacency (make-hash-table :test #'equal)))
    (dolist (edge (reverse edges))
      (let ((from (if reverse (cdr edge) (car edge)))
            (to (if reverse (car edge) (cdr edge))))
        (push to (gethash from adjacency))))
    adjacency))

(defun org-tickets--graph-dfs (node adjacency seen acc)
  "Visit NODE and its unseen descendants in ADJACENCY depth-first.
Marks each visited id in the hash table SEEN.  Returns ACC with the
newly visited ids consed on, each ahead of every id it reached."
  (puthash node t seen)
  (dolist (next (gethash node adjacency))
    (unless (gethash next seen)
      (setq acc (org-tickets--graph-dfs next adjacency seen acc))))
  (cons node acc))

(defun org-tickets--graph-components (edges)
  "Return the strongly connected components of the graph of EDGES.
Each component is a list of node ids (Kosaraju's algorithm)."
  (let ((forward (org-tickets--graph-adjacency edges))
        (backward (org-tickets--graph-adjacency edges t))
        (seen (make-hash-table :test #'equal))
        (order nil)
        (components nil))
    (dolist (vertex (org-tickets--graph-vertices edges))
      (unless (gethash vertex seen)
        (setq order (org-tickets--graph-dfs vertex forward seen order))))
    (setq seen (make-hash-table :test #'equal))
    (dolist (vertex order)
      (unless (gethash vertex seen)
        (push (org-tickets--graph-dfs vertex backward seen nil) components)))
    components))

(defun org-tickets--graph-cyclic-p (component edges)
  "Non-nil when COMPONENT of the graph of EDGES contains a loop."
  (or (cdr component)
      (member (cons (car component) (car component)) edges)))

(defun org-tickets--graph-loop-order (component edges vertices)
  "Return COMPONENT's ids in loop order along EDGES.
Starts from the member appearing first in VERTICES and follows the
edges inside COMPONENT depth-first."
  (let ((inner (seq-filter (lambda (edge)
                             (and (member (car edge) component)
                                  (member (cdr edge) component)))
                           edges))
        (start (seq-find (lambda (vertex) (member vertex component)) vertices)))
    (org-tickets--graph-dfs start (org-tickets--graph-adjacency inner)
                            (make-hash-table :test #'equal) nil)))

(defun org-tickets--graph-cycles (edges)
  "Return the dependency loops in the graph of EDGES.
Each loop is a strongly connected component of two or more nodes, or
a single node with an edge to itself.  A simple loop comes back in
loop order; a larger loop group (several loops sharing nodes) comes
back in depth-first walk order.  Loops are ordered by where their
first id appears in EDGES."
  (let* ((vertices (org-tickets--graph-vertices edges))
         (cycles (mapcar (lambda (component)
                           (org-tickets--graph-loop-order component edges vertices))
                         (seq-filter (lambda (component)
                                       (org-tickets--graph-cyclic-p component edges))
                                     (org-tickets--graph-components edges)))))
    (sort cycles (lambda (a b)
                   (< (seq-position vertices (car a))
                      (seq-position vertices (car b)))))))

(defun org-tickets--graph-cycle-edges (edges)
  "Return the EDGES whose ends both lie in the same dependency loop."
  (let ((cycles (org-tickets--graph-cycles edges)))
    (seq-filter (lambda (edge)
                  (seq-some (lambda (cycle)
                              (and (member (car edge) cycle)
                                   (member (cdr edge) cycle)))
                            cycles))
                edges)))

;;;; DOT

(defcustom org-tickets-graph-title-width 28
  "Maximum number of characters of a ticket title shown in the graph."
  :type 'natnum
  :group 'org-tickets)

(defcustom org-tickets-graph-type-colors
  '(("Story" "#deebf7" "#2e75b6")
    ("Task" "#e2f0d9" "#548235")
    ("Bug" "#fbe3e0" "#c0392b")
    ("Spike" "#ede4f5" "#7030a0")
    ("Merge" "#e0f2f1" "#00897b"))
  "Fill and border colors of non-parent ticket boxes, by issue type.
Each entry is (TYPE FILL BORDER).  Unlisted types use a white box."
  :type '(repeat (list (string :tag "Issue type")
                       (color :tag "Fill")
                       (color :tag "Border")))
  :group 'org-tickets)

(defun org-tickets--graph-html-escape (text)
  "Return TEXT with `&', `<', `>' and `\"' escaped for a Graphviz HTML label."
  (replace-regexp-in-string
   "[&<>\"]"
   (lambda (char)
     (pcase char
       ("&" "&amp;") ("<" "&lt;") (">" "&gt;") (_ "&quot;")))
   text t t))

(defun org-tickets--graph-truncate (title)
  "Return TITLE cut to `org-tickets-graph-title-width' characters with an ellipsis."
  (let ((width (max 1 org-tickets-graph-title-width)))
    (if (> (length title) width)
        (concat (substring title 0 (1- width)) "…")
      title)))

(defun org-tickets--graph-quote (text)
  "Return TEXT as a double-quoted DOT string."
  (concat "\"" (replace-regexp-in-string "[\"\\\\]" "\\\\\\&" text) "\""))

(defun org-tickets--graph-heading-text (node)
  "Return the bold first label line for NODE, as HTML."
  (let ((key (if (plist-get node :new-p) "(new)" (plist-get node :key))))
    (format "<B>%s</B>"
            (org-tickets--graph-html-escape
             (if (plist-get node :parent-p)
                 (format "%s · %s" (upcase (plist-get node :type)) key)
               key)))))

(defun org-tickets--graph-node-label (node)
  "Return the DOT label attribute value for NODE."
  (if (plist-get node :external-p)
      (org-tickets--graph-quote (plist-get node :key))
    (concat "<" (mapconcat
                 #'identity
                 (delq nil
                       (list (org-tickets--graph-heading-text node)
                             (org-tickets--graph-html-escape
                              (org-tickets--graph-truncate
                               (or (plist-get node :title) "")))
                             (when (plist-get node :due)
                               (format "<FONT POINT-SIZE=\"10\" COLOR=\"#555555\">Due %s</FONT>"
                                       (org-tickets--graph-html-escape
                                        (plist-get node :due))))))
                 "<BR/>")
            ">")))

(defun org-tickets--graph-node-style (node)
  "Return the DOT style attributes (a string) for NODE, or nil for the default."
  (cond
   ((plist-get node :external-p)
    (concat "style=\"rounded,dashed\", fillcolor=\"#ffffff\", "
            "color=\"#aaaaaa\", fontcolor=\"#888888\", fontsize=10"))
   ((plist-get node :parent-p)
    (concat "fillcolor=\"#fff2cc\", color=\"#bf9000\", penwidth=2.5, "
            "peripheries=2, fontsize=15, margin=\"0.3,0.15\""
            (when (plist-get node :new-p)
              ", style=\"rounded,filled,dashed\"")))
   (t (org-tickets--graph-type-style node))))

(defun org-tickets--graph-type-style (node)
  "Return the type-colored DOT style for a plain ticket NODE, or nil."
  (let ((colors (cdr (assoc (plist-get node :type)
                            org-tickets-graph-type-colors))))
    (when (or colors (plist-get node :new-p))
      (mapconcat #'identity
                 (delq nil
                       (list (when colors
                               (format "fillcolor=\"%s\", color=\"%s\", penwidth=1.5"
                                       (car colors) (cadr colors)))
                             (when (plist-get node :new-p)
                               "style=\"rounded,filled,dashed\"")))
                 ", "))))

(defun org-tickets--graph-node-line (node)
  "Return the DOT statement declaring NODE."
  (format "%s [label=%s%s];"
          (org-tickets--graph-quote (plist-get node :id))
          (org-tickets--graph-node-label node)
          (let ((style (org-tickets--graph-node-style node)))
            (if style (concat ", " style) ""))))

(defun org-tickets--graph-edge-line (edge cycle-edges)
  "Return the DOT statement for EDGE, in red when it is in CYCLE-EDGES.
EDGE is (FROM . TO); the arrow runs down from the blocker FROM to the
blocked TO."
  (format "%s -> %s%s;"
          (org-tickets--graph-quote (car edge))
          (org-tickets--graph-quote (cdr edge))
          (if (member edge cycle-edges)
              " [color=\"#d62728\", penwidth=2.5]"
            "")))

(defun org-tickets--graph-dot (model)
  "Return the Graphviz DOT text for graph MODEL (see `org-tickets--graph-model')."
  (let* ((nodes (plist-get model :nodes))
         (edges (plist-get model :edges))
         (cycle-edges (org-tickets--graph-cycle-edges edges))
         (parents (seq-filter (lambda (node) (plist-get node :parent-p)) nodes))
         (others (seq-remove (lambda (node) (plist-get node :parent-p)) nodes)))
    (concat
     "digraph tickets {\n"
     "  rankdir=TB; nodesep=0.4; ranksep=0.6;\n"
     "  labelloc=t; labeljust=l; fontname=\"Helvetica\"; fontsize=11; "
     "label=\"Key: A → B means A blocks B (finish A first); "
     "work flows down to its feature\";\n"
     "  node [shape=box, style=\"rounded,filled\", fillcolor=\"#ffffff\", "
     "color=\"#888888\", fontname=\"Helvetica\", fontsize=12];\n"
     "  edge [arrowsize=0.8, color=\"#666666\"];\n"
     (when parents
       (format "  { rank=max; %s }\n"
               (mapconcat #'org-tickets--graph-node-line parents " ")))
     (mapconcat (lambda (node) (concat "  " (org-tickets--graph-node-line node) "\n"))
                others "")
     (mapconcat (lambda (edge)
                  (concat "  " (org-tickets--graph-edge-line edge cycle-edges) "\n"))
                edges "")
     "}\n")))

;;;; Command

(defcustom org-tickets-graph-dot-program "dot"
  "Graphviz program used by `org-tickets-graph' to render the graph."
  :type 'string
  :group 'org-tickets)

(defun org-tickets--graph-simple-loop-p (cycle edges)
  "Non-nil when CYCLE, taken in order and closed, is all the EDGES among it."
  (and (seq-every-p (lambda (pair) (member pair edges))
                    (seq-mapn #'cons cycle
                              (append (cdr cycle) (list (car cycle)))))
       (= (length cycle)
          (seq-count (lambda (edge)
                       (and (member (car edge) cycle) (member (cdr edge) cycle)))
                     edges))))

(defun org-tickets--graph-cycle-text (cycle edges)
  "Return a one-line description of CYCLE, a loop in the graph of EDGES."
  (if (org-tickets--graph-simple-loop-p cycle edges)
      (mapconcat #'identity (append cycle (list (car cycle))) " → ")
    (concat "loop among: " (mapconcat #'identity cycle ", "))))

(defun org-tickets--graph-summary (file edges)
  "Return the echo-area text for graph FILE with EDGES."
  (let ((cycles (org-tickets--graph-cycles edges)))
    (if (null cycles)
        (format "org-tickets: wrote %s — no cycles" file)
      (format "org-tickets: wrote %s — %d %s: %s" file (length cycles)
              (if (cdr cycles) "cycles" "cycle")
              (mapconcat (lambda (cycle)
                           (org-tickets--graph-cycle-text cycle edges))
                         cycles "; ")))))

(defun org-tickets--graph-run-dot (out)
  "Run `org-tickets-graph-dot-program' on the buffer, writing SVG to OUT.
Return its exit status; a program that cannot be started is a `user-error'."
  (condition-case err
      (call-process-region (point-min) (point-max)
                           org-tickets-graph-dot-program t t nil
                           "-Tsvg" "-o" out)
    (file-error
     (user-error (concat "Could not run `%s': %s; install Graphviz or set "
                         "`org-tickets-graph-dot-program'")
                 org-tickets-graph-dot-program
                 (mapconcat #'identity (cdr (cdr err)) ", ")))))

(defun org-tickets--graph-render (dot out)
  "Render DOT text to the SVG file OUT with `org-tickets-graph-dot-program'."
  (with-temp-buffer
    (insert dot)
    (let ((status (org-tickets--graph-run-dot out)))
      (unless (eq status 0)
        (user-error "%s failed (exit %s): %s" org-tickets-graph-dot-program
                    status (string-trim (buffer-string)))))))

(defun org-tickets--graph-show (file)
  "Display FILE in another window, refreshing any buffer already visiting it."
  (let ((open (find-buffer-visiting file)))
    (when open
      (with-current-buffer open (revert-buffer t t)))
    (find-file-other-window file)))

;;;###autoload
(defun org-tickets-graph ()
  "Draw the ticket dependency graph of this buffer beside its file.
Writes an SVG next to the org file, shows it in another window, and
reports any dependency loops.  Needs Graphviz; see
`org-tickets-graph-dot-program'.  Returns the SVG file name."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Not in an org-mode buffer"))
  (unless buffer-file-name
    (user-error "Save the buffer to a file first"))
  (unless (executable-find org-tickets-graph-dot-program)
    (user-error "Cannot find `%s'; install Graphviz or set `org-tickets-graph-dot-program'"
                org-tickets-graph-dot-program))
  (let* ((model (org-tickets--graph-model))
         (out (concat (file-name-sans-extension buffer-file-name) ".svg")))
    (org-tickets--graph-render (org-tickets--graph-dot model) out)
    (org-tickets--graph-show out)
    (message "%s" (org-tickets--graph-summary out (plist-get model :edges)))
    out))

(provide 'org-tickets-graph)

;;; org-tickets-graph.el ends here
