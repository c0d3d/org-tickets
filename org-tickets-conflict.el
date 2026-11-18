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
;; conflicts, pulling a ticket's metadata (not its text) into the
;; heading at point, and the pre-flight check sync runs before pushing.

;;; Code:

(require 'iso8601)
(require 'org-tickets-core)
(require 'org-tickets-api)
(require 'org-tickets-import)
(require 'org-tickets-parse)
(require 'org-tickets-async)
(require 'org-tickets-inherit)
(require 'org-tickets-sync-phases)

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

;;;; Pre-flight check

(defun org-tickets--remote-change-candidates ()
  "Return (KEY . SYNCED) for each heading with a JIRA_KEY and JIRA_SYNCED."
  (delq nil
        (org-map-entries
         (lambda ()
           (let ((key (org-tickets--non-empty-string
                       (org-entry-get (point) "JIRA_KEY")))
                 (synced (org-tickets--non-empty-string
                          (org-entry-get (point) "JIRA_SYNCED"))))
             (when (and key synced)
               (cons key synced)))))))

(defun org-tickets--remote-check-failed (keys err)
  "End the sync because ticket KEYS could not be checked, with ERR."
  (message "org-tickets: Sync cancelled, could not check %s for remote changes: %s"
           keys err)
  (org-tickets--sync-cleanup))

(defmacro org-tickets--with-remote-check-guard (org-buffer &rest body)
  "Run BODY in ORG-BUFFER, ending the sync there if BODY signals.
BODY runs from a response callback, long after the sync command
returned, so an error must not leave ORG-BUFFER locked."
  (declare (indent 1) (debug (form body)))
  (let ((err (make-symbol "err")))
    `(org-tickets--safe-with-buffer
      ,org-buffer
      (lambda ()
        (condition-case ,err
            (progn ,@body)
          (error
           (when org-tickets--sync-in-progress
             (org-tickets--sync-cleanup))
           (message "org-tickets: Sync failed: %S" ,err)))))))

(defun org-tickets--check-remote-changes (org-buffer continue)
  "Check ORG-BUFFER's synced tickets for Jira edits by someone else.
Calls CONTINUE, a function of no arguments, once metadata-only edits
have been pulled into ORG-BUFFER.  Content edits by someone else, or a
failed check request, end the sync instead, leaving the buffer as it
was.  Without any JIRA_SYNCED baseline, CONTINUE is called at once."
  (let ((candidates (with-current-buffer org-buffer
                      (org-tickets--remote-change-candidates))))
    (if (null candidates)
        (funcall continue)
      (org-tickets--async-request
       "GET" "/rest/api/3/myself"
       (lambda (response err)
         (org-tickets--with-remote-check-guard org-buffer
           (if err
               (org-tickets--remote-check-failed
                (mapconcat #'car candidates ", ") err)
             (org-tickets--fetch-changelogs
              org-buffer candidates
              (org-tickets--alist-get "accountId" response) continue))))))))

(defun org-tickets--fetch-changelogs (org-buffer candidates account-id continue)
  "GET the changelog of every CANDIDATES ticket, then judge the changes.
CANDIDATES is a list of (KEY . SYNCED).  ACCOUNT-ID is the user's own
Jira account; ORG-BUFFER and CONTINUE are as for
`org-tickets--check-remote-changes'."
  (org-tickets--async-batch
   (mapcar (lambda (candidate)
             (lambda (done)
               (org-tickets--async-request
                "GET" (format "/rest/api/3/issue/%s?expand=changelog"
                              (car candidate))
                done)))
           candidates)
   (lambda (results)
     (org-tickets--with-remote-check-guard org-buffer
       (org-tickets--judge-remote-changes
        candidates results account-id continue)))))

(defun org-tickets--remote-change-reports (candidates results account-id)
  "Return (KEY CHANGES RESPONSE) for each changed ticket in CANDIDATES.
RESULTS are the batch results, (RESPONSE . ERR), in CANDIDATES order;
ACCOUNT-ID is the user's own Jira account.  Tickets without foreign
changes are left out."
  (delq nil
        (seq-mapn (lambda (candidate result)
                    (let ((changes (org-tickets--foreign-changes
                                    (car result) account-id (cdr candidate))))
                      (when changes
                        (list (car candidate) changes (car result)))))
                  candidates results)))

(defun org-tickets--judge-remote-changes (candidates results account-id continue)
  "Cancel the sync or pull metadata, given the changelog RESULTS.
CANDIDATES, ACCOUNT-ID and CONTINUE are as for
`org-tickets--fetch-changelogs'."
  (let ((failed (seq-find (lambda (pair) (cddr pair))
                          (seq-mapn #'cons candidates results))))
    (if failed
        (org-tickets--remote-check-failed (caar failed) (cddr failed))
      (let* ((reports (org-tickets--remote-change-reports
                       candidates results account-id))
             (conflicts (seq-filter
                         (lambda (report)
                           (seq-some #'org-tickets--content-change-p
                                     (nth 1 report)))
                         reports)))
        (if conflicts
            (org-tickets--report-content-conflicts conflicts)
          (org-tickets--apply-metadata-pulls reports)
          (funcall continue))))))

(defun org-tickets--report-content-conflicts (conflicts)
  "Warn about CONFLICTS, a list of (KEY CHANGES RESPONSE), and end the sync."
  (display-warning
   'org-tickets
   (concat "Sync cancelled: tickets changed in Jira by someone else:\n"
           (mapconcat (lambda (report)
                        (org-tickets--conflict-line (car report) (nth 1 report)))
                      conflicts "\n")
           "\nMerge them by hand (org-tickets-pull-remote-changes) and sync again.")
   :warning)
  (org-tickets--sync-cleanup))

(defun org-tickets--apply-metadata-pulls (reports)
  "Pull the metadata of each (KEY CHANGES RESPONSE) in REPORTS into org.
Inheritance is re-run afterwards so pulled values reach child tickets."
  (when reports
    (let ((inhibit-read-only t))
      (dolist (report reports)
        (org-tickets--with-ticket-at-key (car report)
          (org-tickets--pull-ticket-metadata (nth 2 report))))
      (org-tickets--inherit-parent-properties-in-buffer))
    (message "org-tickets: Pulled remote metadata for %s"
             (mapconcat #'car reports ", "))))

(provide 'org-tickets-conflict)
;;; org-tickets-conflict.el ends here
