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

(defun org-tickets--graph-ancestor-id (ticket headings)
  "Return the id of the nearest parent-type ticket above TICKET, or nil.
HEADINGS maps each ticket heading position to (ID . TYPE)."
  (save-excursion
    (goto-char (org-tickets--ticket-marker ticket))
    (let ((found nil))
      (while (and (not found) (org-up-heading-safe))
        (let ((heading (assoc (point) headings)))
          (when (and heading (org-tickets--parent-type-p (cddr heading)))
            (setq found (cadr heading)))))
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
            (when parent (list (cons id parent))))))

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
BLOCKED-BY and parent (its PARENT key, else the nearest ancestor
parent-type ticket heading)."
  (let ((tickets (save-excursion
                   (org-tickets--doc-tickets (org-tickets--parse-document)))))
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
Each loop is a list of node ids in loop order: a strongly connected
component of two or more nodes, or a single node with an edge to
itself.  Loops are ordered by where their first id appears in EDGES."
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

(provide 'org-tickets-graph)

;;; org-tickets-graph.el ends here
