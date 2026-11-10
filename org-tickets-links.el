;;; org-tickets-links.el --- Jira issue links for org-tickets  -*- lexical-binding: t; -*-

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

;; Jira issue links for org-tickets: the "Blocks" links a ticket needs
;; (child to parent, BLOCKS and BLOCKED-BY entries), created
;; asynchronously in sync phase 2, plus the ticket-marker helpers used to
;; resolve keys assigned earlier in the same sync run.

;;; Code:

(require 'org-tickets-core)
(require 'org-tickets-async)
(require 'org-tickets-parse)

;;;; Ticket Markers

(defmacro org-tickets--at-ticket-marker (ticket &rest body)
  "Run BODY at TICKET's heading marker, inside `save-excursion'.
BODY runs in the marker's buffer.  Returns nil without running BODY when
the ticket has no marker, or the marker is unset or its buffer killed."
  (declare (indent 1) (debug (form body)))
  (let ((m (make-symbol "marker")))
    `(let ((,m (org-tickets--ticket-marker ,ticket)))
       (when (and (markerp ,m) (marker-position ,m)
                  (buffer-live-p (marker-buffer ,m)))
         (with-current-buffer (marker-buffer ,m)
           (save-excursion
             (goto-char ,m)
             ,@body))))))

(defun org-tickets--ticket-parent-key (ticket)
  "Return the key of TICKET's parent, or nil.
That is TICKET's explicit PARENT property, else the key of the nearest
outline ancestor ticket found from its heading marker."
  (or (org-tickets--ticket-parent ticket)
      (org-tickets--at-ticket-marker ticket
        (org-tickets--find-parent-ticket-key))))

(defun org-tickets--ticket-buffer-key (ticket)
  "Read TICKET's current JIRA_KEY from the buffer via its marker.
Picks up keys assigned earlier in the same sync run for tickets that
were parsed without one.  Returns nil when unavailable."
  (org-tickets--at-ticket-marker ticket
    (org-tickets--heading-property "JIRA_KEY")))

;;;; Link Creation

(defun org-tickets--async-create-link (from-key to-key link-type callback)
  "Asynchronously create a link between two tickets.
FROM-KEY blocks TO-KEY via LINK-TYPE (typically \"Blocks\").
CALLBACK is (lambda (response err) ...) called on completion.
Goes through the rate-limit state machine via `org-tickets--async-request'."
  (org-tickets--async-request
   "POST" "/rest/api/3/issueLink"
   callback
   (list (cons 'type (list (cons "name" link-type)))
         (cons "inwardIssue" (list (cons "key" from-key)))
         (cons "outwardIssue" (list (cons "key" to-key))))))

(defun org-tickets--link-done-callback (from-key to-key done)
  "Return a callback for the FROM-KEY -> TO-KEY link that logs failures.
The callback then calls DONE."
  (lambda (_response err)
    (when err
      (message "org-tickets: failed to create link %s -> %s: %s"
               from-key to-key err))
    (funcall done nil nil)))

(defun org-tickets--link-thunk (from-key to-key)
  "Return a batch thunk that creates a \"Blocks\" link FROM-KEY -> TO-KEY.
Failures are logged; the thunk always completes."
  (lambda (done)
    (org-tickets--async-create-link
     from-key to-key "Blocks"
     (org-tickets--link-done-callback from-key to-key done))))

(defvar org-tickets--links-requested nil
  "Hash table of the (FROM . TO) links already requested this sync, or nil.
Phase 2 binds it so a link two tickets both name (one in BLOCKS, the
other in BLOCKED-BY) is POSTed once.")

(defun org-tickets--ticket-link-pairs (ticket key)
  "Return the distinct (FROM . TO) \"Blocks\" links TICKET (key KEY) needs.
Child tickets block their parent; BLOCKS entries are blocked by KEY and
BLOCKED-BY entries block KEY.  Links from a ticket to itself are dropped."
  (let ((parent-key (and (org-tickets--child-type-p (org-tickets--ticket-type ticket))
                         (org-tickets--ticket-parent-key ticket))))
    (seq-remove
     (lambda (pair) (string= (car pair) (cdr pair)))
     (delete-dups
      (append (mapcar (lambda (to) (cons key to))
                      (append (and (org-tickets--non-empty-string parent-key)
                                   (list parent-key))
                              (org-tickets--ticket-blocks ticket)))
              (mapcar (lambda (from) (cons from key))
                      (org-tickets--ticket-blocked-by ticket)))))))

(defun org-tickets--claim-link-p (pair)
  "Return non-nil if link PAIR still needs requesting, and record it.
Always non-nil when `org-tickets--links-requested' is unbound."
  (let ((requested org-tickets--links-requested))
    (or (null requested)
        (unless (gethash pair requested)
          (puthash pair t requested)))))

(defun org-tickets--ticket-link-thunks (ticket key)
  "Return the link thunks TICKET (whose key is KEY) needs.
See `org-tickets--ticket-link-pairs'; a link already requested this
sync (`org-tickets--links-requested') is skipped."
  (mapcar (lambda (pair) (org-tickets--link-thunk (car pair) (cdr pair)))
          (seq-filter #'org-tickets--claim-link-p
                      (org-tickets--ticket-link-pairs ticket key))))

(defun org-tickets--async-sync-ticket-links (ticket callback)
  "Asynchronously sync block relationships for TICKET.
Collects all needed links (parent, blocks, blocked-by) and fires them
concurrently via `org-tickets--async-batch'.  TICKET's marker locates its
heading.  CALLBACK is called when all complete."
  (let* ((key (or (org-tickets--ticket-key ticket)
                  (org-tickets--ticket-buffer-key ticket)))
         (thunks (and (org-tickets--non-empty-string key)
                      (org-tickets--ticket-link-thunks ticket key))))
    (if thunks
        (org-tickets--async-batch thunks (lambda (_results) (funcall callback)))
      (funcall callback))))

(provide 'org-tickets-links)

;;; org-tickets-links.el ends here
