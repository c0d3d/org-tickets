;;; org-tickets-parse.el --- Parsing functions for org-tickets  -*- lexical-binding: t; -*-

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

;; Parsing functions for org-tickets.
;; Contains document and ticket parsing.

;;; Code:

(require 'org-tickets-core)
(require 'org-tickets-convert)

(defmacro org-tickets--with-ticket-at-key (key &rest body)
  "Move point to the heading whose JIRA_KEY is KEY and evaluate BODY there.
BODY runs with point on the matching heading; when no ticket matches the
form evaluates to nil and BODY is skipped.  Point is restored afterwards
\(`save-excursion')."
  (declare (indent 1) (debug (form body)))
  (let ((pos (make-symbol "pos")))
    `(let ((,pos (org-tickets--find-ticket-by-key ,key)))
       (when ,pos
         (save-excursion
           (goto-char ,pos)
           ,@body)))))

(defun org-tickets--ticket-heading-p ()
  "Non-nil when the heading at point is a ticket (has JIRA_TYPE or JIRA_KEY)."
  (or (org-entry-get (point) "JIRA_TYPE")
      (org-entry-get (point) "JIRA_KEY")))

(defun org-tickets--ticket-heading-position ()
  "Return the position of the ticket heading that owns point.
That is the nearest heading at or above point that is a ticket, so
commands work from inside description headings.  Falls back to the
heading at point when no ticket owns it, and to nil before the first
heading."
  (save-excursion
    (unless (org-before-first-heading-p)
      (org-back-to-heading t)
      (let ((own (point)))
        (while (and (not (org-tickets--ticket-heading-p))
                    (org-up-heading-safe)))
        (if (org-tickets--ticket-heading-p) (point) own)))))

(defmacro org-tickets--at-ticket-heading (&rest body)
  "Evaluate BODY with point on the ticket heading that owns point.
See `org-tickets--ticket-heading-position'.  Point is restored after."
  (declare (indent 0) (debug (body)))
  (let ((pos (make-symbol "pos")))
    `(let ((,pos (org-tickets--ticket-heading-position)))
       (save-excursion
         (when ,pos (goto-char ,pos))
         ,@body))))

(defun org-tickets--check-ticket-level (type title level)
  "Signal a `user-error' unless a TYPE ticket TITLE may sit at outline LEVEL.
Parent types (Features) must be level 1 and every other ticket level 1
or 2, so description headings (`***' and deeper) always nest inside
their ticket."
  (unless (if (org-tickets--parent-type-p type) (= level 1) (<= level 2))
    (user-error "org-tickets: %s \"%s\" is at outline level %d; \
features must be level 1 and other tickets level 1 or 2"
                type title level)))

(defun org-tickets--append-csv-property (property value)
  "Append VALUE to the comma-separated org PROPERTY on the heading at point.
An empty or absent property becomes VALUE; otherwise VALUE is appended
after a comma.  Point must already be on the target heading."
  (let ((current (or (org-entry-get (point) property) "")))
    (org-entry-put (point) property
                   (if (string= current "")
                       value
                     (concat current "," value)))))

(defun org-tickets--valid-ticket-key-p (key)
  "Return non-nil if KEY looks like a valid Jira ticket key (e.g. PROJ-123)."
  (let ((case-fold-search nil))
    (and (stringp key)
         (string-match-p "\\`[A-Z][A-Z0-9_]*-[0-9]+\\'" key))))

;;;; Ticket Parsing from Org

(defun org-tickets--parse-document ()
  "Parse the current org buffer and return an org-tickets--doc struct."
  (save-excursion
    (goto-char (point-min))
    (let ((tickets nil)
          (features nil)
          (children nil))
      (while (re-search-forward org-heading-regexp nil t)
        ;; Capture the heading's end before parsing: parsing may clobber the
        ;; match data and may not move point (e.g. non-ticket headings), so we
        ;; must advance past this heading ourselves or the next search will
        ;; re-match it forever.
        (let ((heading-end (match-end 0)))
          (goto-char (match-beginning 0))
          (let ((ticket (org-tickets--parse-ticket-at-point)))
            (when ticket
              (push ticket tickets)
              (pcase (org-tickets--ticket-type ticket)
                ((pred org-tickets--parent-type-p)
                 (push ticket features))
                ((pred org-tickets--child-type-p)
                 (push ticket children)))))
          (goto-char (max (point) heading-end))))
      (org-tickets--doc-create
       :tickets (nreverse tickets)
       :features (nreverse features)
       :children (nreverse children)))))

(defun org-tickets--doc-non-feature-tickets (doc)
  "Return DOC's tickets that are not features, in document order.
Phase 1's sequential path syncs features first and then everything
else.  \"Everything else\" must be derived by exclusion, not by asking
for child tickets: a ticket of some other type would be dropped from
both batches and never reach Jira."
  (let ((features (org-tickets--doc-features doc)))
    (seq-remove (lambda (ticket) (memq ticket features))
                (org-tickets--doc-tickets doc))))

(defun org-tickets--parse-ticket-at-point ()
  "Parse a ticket from the org heading at point.
Returns an org-tickets--ticket struct or nil if not a valid ticket."
  (let* ((element (org-element-at-point))
         (title (or (org-element-property :raw-value element) ""))
         (node element)
         (type-prop (org-entry-get (point) "JIRA_TYPE"))
         (key-prop (org-entry-get (point) "JIRA_KEY"))
         (fix-version (org-entry-get (point) "FIX_VERSION"))
         (labels-str (org-entry-get (point) "LABELS"))
         (story-points-str (org-entry-get (point) "STORY_POINTS"))
         (blocks-str (org-entry-get (point) "BLOCKS"))
         (blocked-by-str (org-entry-get (point) "BLOCKED-BY"))
         (parent-str (org-entry-get (point) "PARENT"))
         (sprint-str (org-entry-get (point) "SPRINT"))
         (due-date-str (org-entry-get (point) "DUE_DATE")))

    (when type-prop
      (org-tickets--check-ticket-level
       type-prop title (org-element-property :level element))
      (org-tickets--ticket-create
       :key key-prop
       :type type-prop
       :summary title
       :description (org-tickets--get-ticket-description node)
       :fix-version fix-version
       :labels (and (> (length labels-str) 0) (split-string labels-str "," t))
       :story-points (and (> (length story-points-str) 0) (string-to-number story-points-str))
       :blocks (and (> (length blocks-str) 0) (split-string blocks-str "," t))
       :blocked-by (and (> (length blocked-by-str) 0) (split-string blocked-by-str "," t))
       :parent (and (> (length parent-str) 0)
                    (if (org-tickets--valid-ticket-key-p parent-str)
                        parent-str
                      (message "org-tickets: ignoring invalid PARENT value %S on %s"
                               parent-str (or key-prop title))
                      nil))
       :sprint (and (> (length sprint-str) 0) sprint-str)
       :due-date (and (> (length due-date-str) 0) due-date-str)
       :attachments nil  ; Populated from Jira during sync
       :org-node node
       :marker (copy-marker (org-element-property :begin element))
       :clear-labels (and labels-str
                          (null (split-string labels-str "," t)))
       :clear-story-points (and story-points-str
                                (or (string= (string-trim story-points-str) "")
                                    (= 0 (string-to-number story-points-str))))))))

(defun org-tickets--description-end (limit)
  "Return where the description of the ticket heading at point ends.
That is the first heading below it, before LIMIT, that is itself a
ticket (has JIRA_TYPE), or LIMIT when there is none.  Other headings
are part of the description and push as ADF headings."
  (save-excursion
    (let ((end nil))
      (while (and (not end) (outline-next-heading) (< (point) limit))
        (when (org-entry-get (point) "JIRA_TYPE")
          (setq end (point))))
      (or end limit))))

(defun org-tickets--get-ticket-description (node)
  "Get the description content from org heading NODE.
The description runs up to the first child ticket heading; non-ticket
child headings are included.  Returns nil if it is empty."
  (let ((begin (org-element-property :contents-begin node))
        (end (org-element-property :contents-end node)))
    (when (and begin end)
      (goto-char begin)
      ;; Skip past properties drawer if present
      (when (save-excursion
              (goto-char begin)
              (re-search-forward org-property-start-re end t))
        (re-search-forward org-property-end-re end t)
        (setq begin (point)))
      (goto-char (org-element-property :begin node))
      (let ((content (string-trim (buffer-substring-no-properties
                                   begin (org-tickets--description-end end)))))
        (when (> (length content) 0) content)))))

(defun org-tickets--ensure-blocks-entry (blocker-key key)
  "Add KEY to the BLOCKS property of ticket BLOCKER-KEY unless already listed.
Keys are compared exactly, not as substrings.  Point is preserved."
  (org-tickets--with-ticket-at-key blocker-key
    (let ((current (split-string (or (org-entry-get (point) "BLOCKS") "")
                                 "," t "[ \t]+")))
      (unless (member key current)
        (org-tickets--append-csv-property "BLOCKS" key)))))

(defun org-tickets--ticket-blockers (ticket)
  "Return the BLOCKED-BY keys of TICKET whose BLOCKS need updating.
Nil when TICKET has no key; empty keys and TICKET's own key are dropped."
  (let ((key (org-tickets--ticket-key ticket)))
    (and key (not (string-empty-p key))
         (seq-remove (lambda (b) (or (string-empty-p b) (string= b key)))
                     (org-tickets--ticket-blocked-by ticket)))))

(defun org-tickets--resolve-blocked-by-in-org (doc)
  "Update org buffer BLOCKS properties from BLOCKED-BY relationships in DOC.
For each ticket with a BLOCKED-BY property, ensure the referenced ticket's
BLOCKS property includes the current ticket's key."
  (dolist (ticket (org-tickets--doc-tickets doc))
    (dolist (blocker (org-tickets--ticket-blockers ticket))
      (org-tickets--ensure-blocks-entry
       blocker (org-tickets--ticket-key ticket)))))

(defun org-tickets--find-parent-ticket-key ()
  "Return the JIRA_KEY of the nearest ancestor Feature/Improvement.
Climbs the outline from the heading at point; skips ancestors that are
not Features/Improvements or lack a key.  Returns nil at top level —
never the heading itself."
  (save-excursion
    (let ((found nil))
      (while (and (not found) (org-up-heading-safe))
        (let ((type (org-entry-get (point) "JIRA_TYPE"))
              (key (org-entry-get (point) "JIRA_KEY")))
          (when (and (org-tickets--parent-type-p type)
                     key (> (length key) 0))
            (setq found key))))
      found)))

(defun org-tickets--find-ticket-by-key (ticket-key)
  "Return the position of the heading whose JIRA_KEY is TICKET-KEY.
Uses the JIRA_KEY property to match exactly."
  (save-excursion
    (goto-char (point-min))
    (catch 'found
      (while (re-search-forward (regexp-quote ticket-key) nil t)
        (save-excursion
          (goto-char (match-beginning 0))
          (when (string= (org-entry-get (point) "JIRA_KEY") ticket-key)
            (throw 'found (point))))))))

(provide 'org-tickets-parse)

;;; org-tickets-parse.el ends here
