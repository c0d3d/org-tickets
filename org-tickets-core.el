;;; org-tickets-core.el --- Core definitions for org-tickets  -*- lexical-binding: t; -*-

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

;; Core definitions for org-tickets package.
;; Contains requires, defcustoms, defvars, and data structures.

;;; Code:

(require 'gv)
(require 'seq)
(require 'json)
(require 'url)
(require 'auth-source)
(require 'org)
(require 'org-element)
(require 'ox)

;;;; Utilities

(defun org-tickets--alist-get (key alist)
  "Get value from ALIST for string KEY, tolerating symbol keys.
json.el produces symbol keys for `alist' object type; locally built
ADF alists use string keys.  KEY must be a string."
  (or (cdr (assoc key alist))
      (let ((sym (intern-soft key)))
        (and sym (cdr (assoc sym alist))))))

;;;; Configuration Group

(defgroup org-tickets nil
  "Manage Jira tickets from Org-mode files."
  :group 'tools)

(defcustom org-tickets-debug nil
  "Enable debug messages for org-tickets.
When non-nil, verbose progress and debugging messages will be shown.
Defaults to nil (no debug output)."
  :type 'boolean
  :group 'org-tickets)

;;;; Variables

(defcustom org-tickets-base-url nil
  "Base URL for Jira instance (e.g., \"https://company.atlassian.net\")."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'org-tickets)

(defvar org-tickets--jira-base-url nil
  "Internal: resolved base URL for API calls.")

(defcustom org-tickets-project-key nil
  "Jira project key (e.g., \"PROJ\")."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'org-tickets)

(defcustom org-tickets-project-id nil
  "Jira project numeric ID (e.g., \"12345\")."
  :type '(choice (const :tag "Unset" nil) string)
  :group 'org-tickets)

(defcustom org-tickets-default-sprint nil
  "Default sprint for new tickets created by org-tickets sync.

This value is used ONLY when creating a new ticket (no JIRA_KEY present).
It is never sent to Jira during updates to existing tickets.

After creation, the SPRINT drawer property is managed by Jira: each sync
pulls the current sprint from Jira via org-tickets--sync-sprint-from-jira and
writes it to the drawer.  Do not rely on the drawer value to push sprint
changes to Jira — use the Jira UI to move tickets between sprints.

Can be a sprint ID (number or numeric string, e.g., 3453) or a
sprint name (e.g., \"Sprint 42\").  Sprint IDs are preferred because name
resolution requires a Jira Agile API call and silently skips the sprint if
the name is not in the active/future sprint list."
  :type '(choice (string :tag "Sprint Name (e.g., \"Sprint 42\")")
                 (integer :tag "Sprint ID (e.g., 3453)")
                 (const :tag "No default sprint" nil))
  :group 'org-tickets)

(defcustom org-tickets-story-points-field "customfield_10016"
  "Jira custom field ID holding story points.
Field IDs are instance-specific; find yours via
GET /rest/api/3/field and look for \"Story Points\"."
  :type 'string
  :group 'org-tickets)

(defcustom org-tickets-sprint-field "customfield_10020"
  "Jira custom field ID holding the sprint assignment.
Field IDs are instance-specific; find yours via
GET /rest/api/3/field and look for \"Sprint\"."
  :type 'string
  :group 'org-tickets)

(defvar org-tickets--project-key nil
  "Internal: resolved project key for API calls.")

(defvar org-tickets--project-id nil
  "Internal: resolved project ID for API calls.")

(defvar org-tickets--api-user nil
  "Jira API user email (from authinfo).")

(defvar org-tickets--api-token nil
  "Jira API token (from authinfo).")

(defvar org-tickets--issue-type-ids
  nil
  "Mapping of issue type names to Jira IDs.
If nil, will be fetched from Jira on first sync.")

(defcustom org-tickets-fix-version-months
  '("Feb" "May" "Aug" "Nov")
  "Months allowed in a Fix Version name (short month names).
Fix Versions are named MONTHYYYY, e.g. \"Aug2026\"."
  :type '(repeat string)
  :group 'org-tickets)

(defcustom org-tickets-needs-sizing-label "NeedsSizing"
  "Label applied to tickets that have no story points.
It is added to new stories and removed once story points are set.
When nil, no sizing label is managed."
  :type '(choice (string :tag "Label")
                 (const :tag "Do not manage a sizing label" nil))
  :group 'org-tickets)

(defconst org-tickets--parent-issue-types
  '("Feature" "New Feature" "Improvement" "Epic")
  "Issue types that can act as a parent to other tickets.
This is the only enumerated side of the hierarchy: everything else is
a child (see `org-tickets--child-type-p').  To stop a type from getting a
parent link, add it here.")

(defun org-tickets--parent-type-p (type)
  "Non-nil when TYPE can parent other tickets."
  (and (stringp type) (member type org-tickets--parent-issue-types) t))

(defun org-tickets--child-type-p (type)
  "Non-nil when TYPE hangs off a parent ticket.
Any type that is not an `org-tickets--parent-issue-types' counts: a child
inherits its parent's properties and gets a \"Blocks\" link to it.
Deliberately NOT an allowlist.  Enumerating child types is what left
Tasks and Bugs, and later the custom \"Merge\" type, with no parent
link and no inherited properties -- every custom issue type a project
invents would have to be added by hand, and the failure is silent."
  (and (stringp type)
       (> (length (string-trim type)) 0)
       (not (org-tickets--parent-type-p type))))

(defvar-local org-tickets--sync-in-progress nil
  "Non-nil when an async sync is running in this buffer.")

(defvar-local org-tickets--sync-saved-point nil
  "Marker for point when the current async sync began, or nil.")

(defvar-local org-tickets--sync-saved-window-start nil
  "Marker for `window-start' when the current async sync began, or nil.")

(defvar-local org-tickets--sync-prior-read-only nil
  "Buffer's `buffer-read-only' value before sync locked it.")

;;;; Data Structures

(eval-and-compile
  (defun org-tickets--record-slot-keyword (slot)
    "Return the keyword symbol naming SLOT in a record constructor call."
    (intern (concat ":" (symbol-name slot))))

  (defun org-tickets--record-constructor-docstring (docstring keywords)
    "Return DOCSTRING extended with a filled list of KEYWORDS."
    (with-temp-buffer
      (insert "ARGS is a plist of slot keywords: "
              (mapconcat #'symbol-name keywords ", ") ".")
      (let ((fill-column 70))
        (fill-region (point-min) (point-max)))
      (concat docstring "\n\n" (buffer-string)))))

(defmacro org-tickets--define-record (name docstring &rest slots)
  "Define record type NAME, documented by DOCSTRING, holding SLOTS.

Each entry in SLOTS is either a symbol or a (SYMBOL DEFAULT) list,
where DEFAULT is a form evaluated at construction time when the
slot is not supplied.

Expands to a keyword constructor `NAME-create', a type predicate
`NAME-p', and one accessor `NAME-SLOT' per slot.  Accessors are
valid `setf' places, so callers read and write slots exactly as
they would with a `cl-defstruct'."
  (declare (indent 2) (doc-string 2))
  (let* ((specs (mapcar (lambda (slot) (if (consp slot) slot (list slot nil)))
                        slots))
         (keywords (mapcar (lambda (spec)
                             (org-tickets--record-slot-keyword (car spec)))
                           specs))
         (index 0)
         (accessors nil))
    (dolist (spec specs)
      (setq index (1+ index))
      (let ((accessor (intern (format "%s-%s" name (car spec))))
            (slot-index index))
        (push `(progn
                 (defsubst ,accessor (record)
                   ,(format "Return the `%s' slot of RECORD." (car spec))
                   (aref record ,slot-index))
                 (gv-define-setter ,accessor (value record)
                   (list 'aset record ,slot-index value)))
              accessors)))
    `(progn
       ,@(nreverse accessors)
       (defun ,(intern (format "%s-p" name)) (object)
         ,(format "Return non-nil when OBJECT is a `%s' record." name)
         (and (recordp object) (eq (aref object 0) ',name)))
       (defun ,(intern (format "%s-create" name)) (&rest args)
         ,(org-tickets--record-constructor-docstring docstring keywords)
         (org-tickets--check-record-keywords ',name args ',keywords)
         (record ',name
                 ,@(mapcar
                    (lambda (spec)
                      (let ((keyword (org-tickets--record-slot-keyword (car spec))))
                        `(if (plist-member args ,keyword)
                             (plist-get args ,keyword)
                           ,(cadr spec))))
                    specs))))))

(defun org-tickets--check-record-keywords (name args keywords)
  "Signal an error when ARGS is not a plist of KEYWORDS for record NAME."
  (let ((rest args))
    (while rest
      (unless (memq (car rest) keywords)
        (error "Unknown %s slot %S (known slots: %S)"
               name (car rest) keywords))
      (unless (cdr rest)
        (error "Missing value for %s slot %S" name (car rest)))
      (setq rest (cddr rest)))))

(org-tickets--define-record org-tickets--ticket
    "Represents a Jira ticket parsed from org document."
  id                                ; Numeric ID
  key                               ; Ticket key (e.g., "PROJ-123")
  type                              ; Jira issue type name, e.g. "Feature",
                                        ; "Improvement", "Story", "Task"
  summary
  description
  fix-version
  labels
  story-points
  blocks                            ; List of ticket keys this blocks
  blocked-by                       ; List of ticket keys this is blocked by
  parent                           ; Parent ticket key for Stories
  attachments                      ; List of attachment metadata (from Jira)
  sprint                           ; Sprint name from Jira
  due-date                         ; Due date string "YYYY-MM-DD"
  org-node                         ; Org headline element (parse-time snapshot)
  marker                           ; Marker at the heading start; survives
                                        ; buffer edits during async sync
  clear-labels                     ; t when LABELS property exists but is empty
  clear-story-points)              ; t when STORY_POINTS exists but is empty/0

(org-tickets--define-record org-tickets--doc
    "Represents the entire org document with parsed tickets."
  tickets                           ; List of org-tickets--ticket structs
  features                          ; Tickets of an `org-tickets--parent-type-p'
  children)                         ; Tickets of an `org-tickets--child-type-p'

(provide 'org-tickets-core)

;;; org-tickets-core.el ends here
