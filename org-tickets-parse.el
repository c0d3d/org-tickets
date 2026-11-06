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
;; Contains document and ticket parsing, and reading/writing the
;; #+JIRA_ISSUE_TYPES keyword.

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
  (let ((current (org-tickets--heading-property property)))
    (org-entry-put (point) property
                   (if current (concat current "," value) value))))

(defun org-tickets--non-empty-string (value)
  "Return VALUE when it is a string with non-whitespace content, else nil."
  (and (stringp value) (not (string-blank-p value)) value))

(defun org-tickets--heading-property (property)
  "Return the trimmed PROPERTY of the heading at point, or nil if empty."
  (let ((value (org-tickets--non-empty-string (org-entry-get (point) property))))
    (and value (string-trim value))))

(defun org-tickets--csv-property (property)
  "Return the comma-separated PROPERTY at point as a list of trimmed strings.
Blank entries are dropped; an absent or blank property gives nil."
  (split-string (or (org-entry-get (point) property) "") "," t "[ \t]+"))

(defun org-tickets--valid-ticket-key-p (key)
  "Return non-nil if KEY looks like a valid Jira ticket key (e.g. PROJ-123)."
  (let ((case-fold-search nil))
    (and (stringp key)
         (string-match-p "\\`[A-Z][A-Z0-9_]*-[0-9]+\\'" key))))

;;;; Ticket Parsing from Org

(defun org-tickets--parse-document ()
  "Parse the current org buffer and return an org-tickets--doc struct."
  (let ((tickets (delq nil (org-map-entries #'org-tickets--parse-ticket-at-point))))
    (org-tickets--doc-create :tickets tickets)))

(defun org-tickets--doc-non-feature-tickets (doc)
  "Return DOC's tickets that are not features, in document order.
Phase 1's sequential path syncs features first and then everything
else.  \"Everything else\" must be derived by exclusion, not by asking
for child tickets: a ticket of some other type would be dropped from
both batches and never reach Jira."
  (let ((features (org-tickets--doc-features doc)))
    (seq-remove (lambda (ticket) (memq ticket features))
                (org-tickets--doc-tickets doc))))

(defun org-tickets--valid-parent-property (title)
  "Return the PARENT property at point if it is a valid key, else nil.
An invalid value is reported via `message' using the ticket's key or TITLE."
  (let ((parent (org-tickets--heading-property "PARENT")))
    (cond ((null parent) nil)
          ((org-tickets--valid-ticket-key-p parent) parent)
          (t (message "org-tickets: ignoring invalid PARENT value %S on %s"
                      parent (or (org-tickets--heading-property "JIRA_KEY")
                                 title))
             nil))))

(defun org-tickets--parse-ticket-at-point ()
  "Parse a ticket from the org heading at point.
Returns an org-tickets--ticket struct or nil if not a valid ticket."
  (let ((element (org-element-at-point))
        (type-prop (org-entry-get (point) "JIRA_TYPE"))
        (story-points-str (org-entry-get (point) "STORY_POINTS")))
    (when type-prop
      (let ((title (or (org-element-property :raw-value element) ""))
            (labels (org-tickets--csv-property "LABELS"))
            (story-points (org-tickets--heading-property "STORY_POINTS")))
        (org-tickets--check-ticket-level
         type-prop title (org-element-property :level element))
        (org-tickets--ticket-create
         :key (org-entry-get (point) "JIRA_KEY")
         :type type-prop
         :summary title
         :description (org-tickets--get-ticket-description)
         :fix-version (org-entry-get (point) "FIX_VERSION")
         :labels labels
         :story-points (and story-points (string-to-number story-points))
         :blocks (org-tickets--csv-property "BLOCKS")
         :blocked-by (org-tickets--csv-property "BLOCKED-BY")
         :parent (org-tickets--valid-parent-property title)
         :sprint (org-tickets--heading-property "SPRINT")
         :due-date (org-tickets--heading-property "DUE_DATE")
         :attachments nil  ; Populated from Jira during sync
         :marker (copy-marker (org-element-property :begin element))
         :clear-labels (and (org-entry-get (point) "LABELS") (null labels))
         :clear-story-points (and story-points-str
                                  (or (null story-points)
                                      (= 0 (string-to-number story-points)))))))))

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

(defun org-tickets--description-begin (element)
  "Return where the description of heading ELEMENT at point begins.
That is the end of the property drawer's :END: line, or ELEMENT's
contents start when it has no drawer."
  (let ((drawer (org-get-property-block)))
    (if drawer
        (save-excursion (goto-char (cdr drawer)) (line-end-position))
      (org-element-property :contents-begin element))))

(defun org-tickets--description-region ()
  "Return (BEG . END) of the description of the ticket heading at point.
BEG is `org-tickets--description-begin'; END is
`org-tickets--description-end'.  Nil when the heading has no contents.
Point is not moved."
  (save-excursion
    (org-back-to-heading t)
    (let ((element (org-element-at-point)))
      (when (org-element-property :contents-begin element)
        (cons (org-tickets--description-begin element)
              (org-tickets--description-end
               (org-element-property :contents-end element)))))))

(defun org-tickets--get-ticket-description ()
  "Return the description of the ticket heading at point, or nil if empty.
The description runs up to the first child ticket heading; non-ticket
child headings are included."
  (let ((region (org-tickets--description-region)))
    (when region
      (org-tickets--non-empty-string
       (string-trim (buffer-substring-no-properties (car region) (cdr region)))))))

(defun org-tickets--find-parent-ticket-key ()
  "Return the JIRA_KEY of the nearest ancestor Feature/Improvement.
Climbs the outline from the heading at point; skips ancestors that are
not Features/Improvements or lack a key.  Returns nil at top level —
never the heading itself."
  (save-excursion
    (let ((found nil))
      (while (and (not found) (org-up-heading-safe))
        (let ((type (org-entry-get (point) "JIRA_TYPE"))
              (key (org-tickets--heading-property "JIRA_KEY")))
          (when (and (org-tickets--parent-type-p type) key)
            (setq found key))))
      found)))

(defun org-tickets--find-ticket-by-key (ticket-key)
  "Return the position of the heading whose JIRA_KEY is TICKET-KEY, or nil."
  (org-find-property "JIRA_KEY" ticket-key))

;;;; Issue types keyword

(defun org-tickets--parse-issue-type-pair (pair)
  "Parse PAIR, a \"NAME=ID\" string, into (NAME . ID), or nil if malformed."
  (when (string-match "\\(.+\\)=\\(.+\\)" pair)
    (let ((name (match-string-no-properties 1 pair))
          (id (match-string-no-properties 2 pair)))
      (cons (string-trim name) (string-trim id)))))

(defun org-tickets--load-issue-types ()
  "Return the issue types in the #+JIRA_ISSUE_TYPES keyword, or nil.
The keyword holds \"NAME=ID\" pairs separated by commas; the result is an
alist of (NAME . ID) strings.  Point is left alone and keywords inside
src blocks are ignored."
  (let ((raw (cadar (org-collect-keywords '("JIRA_ISSUE_TYPES")))))
    (unless (or (null raw) (string= raw ""))
      (mapcar #'org-tickets--parse-issue-type-pair (split-string raw "," t)))))

(defun org-tickets--format-issue-types (issue-types)
  "Format ISSUE-TYPES, an alist of (NAME . ID), as a #+JIRA_ISSUE_TYPES line."
  (format "#+JIRA_ISSUE_TYPES: %s"
          (mapconcat (lambda (pair)
                       (format "%s=%s"
                               (substring-no-properties (car pair))
                               (substring-no-properties (cdr pair))))
                     issue-types
                     ",")))

(defun org-tickets--save-issue-types (issue-types)
  "Write ISSUE-TYPES, an alist of (NAME . ID), to the #+JIRA_ISSUE_TYPES line.
Replaces an existing line in place (kill ring untouched) or inserts one
at the top of the buffer.  Any narrowing is ignored and kept.  Point is
preserved."
  (org-with-wide-buffer
   (goto-char (point-min))
   (if (re-search-forward "^#\\+JIRA_ISSUE_TYPES:.*$" nil t)
       (replace-match (org-tickets--format-issue-types issue-types) t t)
     (goto-char (point-min))
     (insert (org-tickets--format-issue-types issue-types) "\n"))))

(provide 'org-tickets-parse)

;;; org-tickets-parse.el ends here
