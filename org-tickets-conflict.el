;;; org-tickets-conflict.el --- Remote change classification for org-tickets  -*- lexical-binding: t; -*-

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

;; Detecting Jira edits made by other people: Jira timestamp comparison,
;; classifying changelog entries as foreign changes, describing content
;; conflicts, and pulling a ticket's metadata (not its text) into the
;; heading at point.

;;; Code:

(require 'iso8601)
(require 'org-tickets-core)
(require 'org-tickets-api)
(require 'org-tickets-import)

(defun org-tickets--jira-time-seconds (timestamp)
  "Return Jira TIMESTAMP as float seconds since the epoch.
Keeps the fractional seconds that `iso8601-parse' drops."
  (let ((fraction (if (string-match "\\.\\([0-9]+\\)" timestamp)
                      (string-to-number (concat "0." (match-string 1 timestamp)))
                    0)))
    (+ (float-time (encode-time (iso8601-parse timestamp))) fraction)))

(defun org-tickets--jira-time-later-p (a b)
  "Return non-nil when Jira timestamp A is strictly after timestamp B."
  (> (org-tickets--jira-time-seconds a) (org-tickets--jira-time-seconds b)))

(defun org-tickets--history-changes (history)
  "Return (FIELD-ID . AUTHOR-NAME) for each changelog item in HISTORY."
  (let ((name (org-tickets--alist-get
               "displayName" (org-tickets--alist-get "author" history))))
    (mapcar (lambda (item)
              (cons (org-tickets--alist-get "fieldId" item) name))
            (org-tickets--ensure-list (org-tickets--alist-get "items" history)))))

(defun org-tickets--foreign-changes (response account-id since)
  "Return changes in issue RESPONSE made by others after SINCE.
Each element is (FIELD-ID . AUTHOR-NAME).  Histories authored by
ACCOUNT-ID, or created at or before the Jira timestamp SINCE, are
skipped."
  (let ((histories (org-tickets--ensure-list
                    (org-tickets--alist-get
                     "histories" (org-tickets--alist-get "changelog" response)))))
    (mapcan
     (lambda (history)
       (let ((author (org-tickets--alist-get "accountId"
                                             (org-tickets--alist-get "author" history))))
         (when (and (not (equal author account-id))
                    (org-tickets--jira-time-later-p
                     (org-tickets--alist-get "created" history) since))
           (org-tickets--history-changes history))))
     histories)))

(defun org-tickets--content-change-p (change)
  "Return non-nil when CHANGE, (FIELD-ID . AUTHOR-NAME), edits text content."
  (and (member (car change) '("summary" "description")) t))

(defun org-tickets--conflict-line (key changes)
  "Describe the content changes in CHANGES for ticket KEY on one line."
  (format "%s: %s" key
          (mapconcat (lambda (change)
                       (format "%s changed by %s" (car change) (cdr change)))
                     (seq-filter #'org-tickets--content-change-p changes)
                     ", ")))

(defun org-tickets--pull-ticket-metadata (response)
  "Write the metadata of issue RESPONSE to the ticket heading at point.
Headline, description and JIRA_SYNCED are left alone.  PARENT keeps its
local value, since Jira's parent field is not used for hierarchy."
  (let ((parent (org-entry-get (point) "PARENT")))
    (org-tickets--write-ticket-properties
     (org-tickets--parse-jira-issue response) t)
    (if parent
        (org-entry-put (point) "PARENT" parent)
      (org-entry-delete (point) "PARENT"))))

(provide 'org-tickets-conflict)
;;; org-tickets-conflict.el ends here
