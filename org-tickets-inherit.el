;;; org-tickets-inherit.el --- Parent property inheritance for org-tickets  -*- lexical-binding: t; -*-

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

;; Parent property inheritance for org-tickets: a ticket heading with no
;; DUE_DATE or FIX_VERSION takes it from its parent -- the ticket named
;; by its PARENT property (read from the buffer, or from Jira when the
;; parent is not in the buffer) or else its nearest ancestor ticket
;; heading.  Remote parents are cached per pass by
;; `org-tickets--with-parent-cache'.

;;; Code:

(require 'org-tickets-core)
(require 'org-tickets-api)
(require 'org-tickets-parse)
(require 'org-tickets-import)

(defconst org-tickets--inherited-properties '("DUE_DATE" "FIX_VERSION")
  "Drawer properties a ticket takes from its parent when it has none.
Both are payload fields (`duedate' and `fixVersions'), so inheritance
has to happen before the sync builds its requests.")

(defun org-tickets--fields-due-date (fields)
  "Return the duedate in Jira issue FIELDS, or nil."
  (org-tickets--alist-get "duedate" fields))

(defconst org-tickets--remote-inherited-fields
  '(("DUE_DATE" . org-tickets--fields-due-date)
    ("FIX_VERSION" . org-tickets--first-fix-version-name))
  "Inherited properties read from Jira when the PARENT is not in the buffer.
Each maps to a function of the issue's fields that returns the value.")

(defvar org-tickets--remote-parent-cache nil
  "Hash of parent key to its Jira issue, bound for one inheritance pass.")

(defmacro org-tickets--with-parent-cache (&rest body)
  "Run BODY as one inheritance pass with a fresh remote parent cache.
Within BODY each parent absent from the buffer is fetched from Jira at
most once."
  (declare (indent 0) (debug (body)))
  `(let ((org-tickets--remote-parent-cache (make-hash-table :test #'equal)))
     ,@body))

(defun org-tickets--fetch-parent-issue (parent-key)
  "Return the Jira issue PARENT-KEY, or nil when the fetch fails."
  (condition-case err
      (org-tickets--get-ticket parent-key)
    (error
     (message "org-tickets: could not fetch parent %s: %s"
              parent-key (error-message-string err))
     nil)))

(defun org-tickets--remote-parent-issue (parent-key)
  "Return the Jira issue PARENT-KEY, fetching it at most once per pass.
Fetches uncached when no pass has bound `org-tickets--remote-parent-cache'.
Returns nil when the fetch fails."
  (if (not org-tickets--remote-parent-cache)
      (org-tickets--fetch-parent-issue parent-key)
    (let ((cached (gethash parent-key org-tickets--remote-parent-cache 'missing)))
      (if (not (eq cached 'missing))
          cached
        (puthash parent-key (org-tickets--fetch-parent-issue parent-key)
                 org-tickets--remote-parent-cache)))))

(defun org-tickets--remote-parent-property (parent-key property)
  "Return PARENT-KEY's PROPERTY as Jira has it, or nil.
Only properties in `org-tickets--remote-inherited-fields' are looked up."
  (let ((extract (cdr (assoc property org-tickets--remote-inherited-fields))))
    (when extract
      (let ((value (funcall extract
                            (org-tickets--alist-get
                             "fields" (org-tickets--remote-parent-issue parent-key)))))
        (and (stringp value) (not (string-blank-p value)) value)))))

(defun org-tickets--ancestor-property (property)
  "Return PROPERTY of the nearest ancestor ticket heading carrying it, or nil."
  (save-excursion
    (catch 'ancestor-value
      (while (org-up-heading-safe)
        (when (org-entry-get (point) "JIRA_TYPE")
          (let ((value (org-tickets--heading-property property)))
            (when value
              (throw 'ancestor-value value))))))))

(defun org-tickets--parent-key-property (parent-key property)
  "Return PROPERTY of the ticket PARENT-KEY, or nil.
Read from its heading when it is in the buffer, otherwise from Jira."
  (let ((parent-pos (org-tickets--find-ticket-by-key parent-key)))
    (if parent-pos
        (save-excursion
          (goto-char parent-pos)
          (org-tickets--heading-property property))
      (org-tickets--remote-parent-property parent-key property))))

(defun org-tickets--explicit-parent-property (property)
  "Return PROPERTY of the ticket named by the heading's PARENT, or nil."
  (let ((parent-key (org-entry-get (point) "PARENT")))
    (when (org-tickets--valid-ticket-key-p parent-key)
      (org-tickets--parent-key-property parent-key property))))

(defun org-tickets--parent-property (property)
  "Return the PROPERTY value the ticket heading at point inherits, or nil.
Prefers the ticket named by the heading's PARENT property, which need
not be an outline ancestor nor in the buffer -- it is also the ticket the
\"Blocks\" link goes to.  Failing that, the nearest ancestor ticket
heading that carries PROPERTY.  Non-ticket headings are never a source:
only headings with a JIRA_TYPE count."
  (or (org-tickets--explicit-parent-property property)
      (org-tickets--ancestor-property property)))

(defun org-tickets--inherit-parent-property-at-point (property)
  "Set PROPERTY on the heading at point from its parent when it is empty.
A value the heading already carries is left alone."
  (unless (org-tickets--heading-property property)
    (let ((inherited (org-tickets--parent-property property)))
      (when inherited
        (org-entry-put (point) property inherited)))))

(defun org-tickets--inherit-parent-properties-in-buffer ()
  "Fill every ticket heading's empty `org-tickets--inherited-properties'.
Runs before the sync parses the document, so an inherited value is part
of the same create/update payload Jira receives -- inheriting only after
the requests were sent left Jira with an empty due date until the next
sync, and fix version was never inherited at all.  Walking top-down
cascades: a heading that just inherited is the source for its own
children.  A heading that already carries the property is left alone;
its value wins over the parent's."
  (org-tickets--with-parent-cache
    (org-map-entries
     (lambda ()
       (when (org-entry-get (point) "JIRA_TYPE")
         (mapc #'org-tickets--inherit-parent-property-at-point
               org-tickets--inherited-properties))))))

(defun org-tickets--inherit-due-date (story-key feature-key)
  "Inherit due date from parent Feature/Improvement to Story if not already set.
STORY-KEY is the Story ticket key.
FEATURE-KEY is the parent Feature/Improvement key.
Only sets the due date if the Story doesn't already have one.  A
FEATURE-KEY absent from the buffer is looked up in Jira."
  (org-tickets--with-ticket-at-key story-key
    (unless (org-tickets--heading-property "DUE_DATE")
      (let ((parent-due-date (org-tickets--parent-key-property
                              feature-key "DUE_DATE")))
        (when parent-due-date
          (org-entry-put (point) "DUE_DATE" parent-due-date))))))

(provide 'org-tickets-inherit)

;;; org-tickets-inherit.el ends here
