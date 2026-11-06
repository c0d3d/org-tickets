;;; org-tickets-api.el --- Jira REST API client for org-tickets  -*- lexical-binding: t; -*-

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

;; Jira REST API client for org-tickets.
;; Contains config resolution, HTTP requests, and issue type management.

;;; Code:

(require 'org-tickets-core)
(require 'org-tickets-fields)

(declare-function org-tickets--async-request "org-tickets-async")

;;;; Jira API Client

(defmacro org-tickets--require-config (internal-var custom-var)
  "Set INTERNAL-VAR from CUSTOM-VAR, signalling an error if CUSTOM-VAR is unset.
CUSTOM-VAR names an org-tickets configuration variable the user sets in
their init file."
  `(progn
     (setq ,internal-var ,custom-var)
     (unless ,internal-var
       (user-error "`%s' is not set; customize it or set it in your init file"
                  ',custom-var))))

(defun org-tickets--encode-request-data (data)
  "JSON-encode DATA as a UTF-8 request body, or nil when DATA is nil.
Binds `json-null' so fields holding :json-null encode as JSON null."
  (when data
    (let ((json-null :json-null))
      (encode-coding-string (json-encode data) 'utf-8))))

(defun org-tickets--response-field (response key)
  "Return the KEY field from a Jira issue RESPONSE's \"fields\" object.
Returns nil when RESPONSE lacks a fields object or that field."
  (org-tickets--alist-get key (org-tickets--alist-get "fields" response)))

(defun org-tickets--resolve-config ()
  "Resolve configuration from custom vars and authinfo."
  (org-tickets--require-config org-tickets--jira-base-url org-tickets-base-url)
  (org-tickets--require-config org-tickets--project-key org-tickets-project-key)
  (org-tickets--require-config org-tickets--project-id org-tickets-project-id)

  ;; Resolve credentials from authinfo
  (let* ((host (url-host (url-generic-parse-url org-tickets--jira-base-url)))
         (auth (auth-source-search :host host :user nil :require '(:secret))))
    (unless auth
      (error "No authinfo entry found for host: %s" host))
    (setq org-tickets--api-user (plist-get (car auth) :user))
    (let ((secret (plist-get (car auth) :secret)))
      (setq org-tickets--api-token
            (if (functionp secret) (funcall secret) secret)))))

(defun org-tickets--async-build-headers ()
  "Build the standard Jira API request headers alist.
Signals an error if credentials have not been resolved."
  (unless org-tickets--api-user
    (error "Jira API user is not set; call `org-tickets--resolve-config' first"))
  (unless org-tickets--api-token
    (error "Jira API token is not set; call `org-tickets--resolve-config' first"))
  (list (cons "Content-Type" "application/json")
        (cons "Accept" "application/json")
        (cons "Authorization"
              (concat "Basic "
                      (base64-encode-string
                       (concat org-tickets--api-user ":" org-tickets--api-token) t)))))

(defun org-tickets--http-split-response ()
  "Split the url.el response in the current buffer into status and body.
Decodes the buffer as utf-8 first.  Returns a plist
\(:status STATUS-TEXT :body BODY-TEXT).  Does not kill the buffer."
  (set-buffer-multibyte t)
  (decode-coding-region (point-min) (point-max) 'utf-8)
  (goto-char (point-min))
  (if (re-search-forward "^$" nil t)
      (list :status (buffer-substring-no-properties (point-min) (point))
            :body (buffer-substring-no-properties (point) (point-max)))
    (list :status "" :body "")))

(defun org-tickets--http-success-p (status)
  "Return non-nil when STATUS text carries a 2xx HTTP status."
  (string-match-p "HTTP/.* 2[0-9][0-9]" status))

(defun org-tickets--http-parse-json-body (body)
  "Parse BODY as JSON with the project-standard settings.
Returns nil for an empty body (204 No Content)."
  (let ((trimmed (string-trim (or body ""))))
    (unless (string-empty-p trimmed)
      (let ((json-object-type 'alist)
            (json-array-type 'list))
        (json-read-from-string trimmed)))))

(defun org-tickets--api-request (method endpoint &optional data)
  "Make a synchronous API request to Jira.
METHOD is the HTTP method (GET, POST, PUT, DELETE).
ENDPOINT is the API path (e.g., \"/rest/api/3/search\").
DATA is an optional request body (JSON-encoded).
Returns the parsed JSON body, or nil when the response has no body.
Signals an error on non-2xx responses or connection failure."
  (unless org-tickets--jira-base-url
    (org-tickets--resolve-config))
  (let* ((url (concat org-tickets--jira-base-url endpoint))
         (url-request-method method)
         (url-request-extra-headers (org-tickets--async-build-headers))
         (url-request-data (org-tickets--encode-request-data data)))
    (when org-tickets-debug
      (message "org-tickets: %s %s" method url)
      (message "org-tickets: request data: %S" data))
    (let ((buffer (url-retrieve-synchronously url)))
      (unless buffer
        (error "No response from %s (connection failed?)" url))
      (unwind-protect
          (with-current-buffer buffer
            (let* ((parsed (org-tickets--http-split-response))
                   (status (plist-get parsed :status)))
              (unless (org-tickets--http-success-p status)
                (error "Jira API error: %s\nResponse: %s"
                       status (plist-get parsed :body)))
              (org-tickets--http-parse-json-body (plist-get parsed :body))))
        (kill-buffer buffer)))))

(defun org-tickets--get-ticket (ticket-key)
  "Get the ticket with key TICKET-KEY (e.g., \"PROJ-123\") from Jira."
  (org-tickets--api-request "GET" (concat "/rest/api/3/issue/" ticket-key)))

(defun org-tickets--fetch-issue-types ()
  "Fetch issue types from Jira for the project and cache them in the document."
  (let* ((endpoint (concat "/rest/api/3/issue/createmeta?projectKeys="
                           org-tickets--project-key
                           "&expand=projects.issuetypes.fields"))
         (response (org-tickets--api-request "GET" endpoint))
         (projects (org-tickets--alist-get "projects" response))
         (issue-types (and projects
                           (org-tickets--alist-get "issuetypes" (car projects)))))
    (unless response
      (error "Failed to fetch issue types: empty response"))
    (unless projects
      (error "No projects found in response: %S" response))
    (unless issue-types
      (error "No issueTypes found in project: %S" (car projects)))
    (setq org-tickets--issue-type-ids
          (mapcar (lambda (it)
                    (cons (substring-no-properties (org-tickets--alist-get "name" it))
                          (substring-no-properties (org-tickets--alist-get "id" it))))
                  issue-types))
    (when org-tickets-debug
      (message "org-tickets: fetched issue types: %S" org-tickets--issue-type-ids))
    (org-tickets--save-issue-types-to-document)))

(defun org-tickets--get-sprints-for-project (board-id &optional include-ids)
  "Fetch available sprints for BOARD-ID.
BOARD-ID is the Jira Software board ID.
If INCLUDE-IDS is non-nil, returns list of (\"name\" . ID) pairs.
Otherwise returns list of just sprint names.
Fetches only active and future sprints, handling pagination."
  (org-tickets--resolve-config)
  (let ((all-values nil)
        (start-at 0)
        (done nil))
    (while (not done)
      (let* ((endpoint (format "/rest/agile/1.0/board/%s/sprint?state=active,future&startAt=%d"
                               board-id start-at))
             (response (org-tickets--api-request "GET" endpoint))
             (values (org-tickets--alist-get "values" response))
             (is-last (org-tickets--alist-get "isLast" response)))
        (let ((last-page-p (and is-last (not (eq is-last :json-false)))))
          (setq all-values (append all-values values))
          (if (or last-page-p (null values))
              (setq done t)
            (setq start-at (+ start-at (length values)))))))
    (if include-ids
        (mapcar (lambda (sprint)
                  (cons (org-tickets--alist-get "name" sprint)
                        (org-tickets--alist-get "id" sprint)))
                all-values)
      (mapcar (lambda (sprint)
                (org-tickets--alist-get "name" sprint))
              all-values))))

(defun org-tickets--get-board-id-for-project ()
  "Get the default board ID for the configured project.
This is a simple implementation that returns the first agile board."
  (org-tickets--resolve-config)
  (let* ((endpoint (format "/rest/agile/1.0/board?projectKeyOrId=%s" org-tickets--project-key))
         (response (org-tickets--api-request "GET" endpoint))
         (values (org-tickets--alist-get "values" response)))
    (when values
      (org-tickets--alist-get "id" (car values)))))

(defun org-tickets--ensure-issue-types ()
  "Ensure issue type IDs are loaded, fetching from Jira if needed."
  ;; Ensure config is resolved before trying to fetch
  (org-tickets--resolve-config)
  (unless org-tickets--issue-type-ids
    (or (org-tickets--load-issue-types-from-document)
        (org-tickets--fetch-issue-types))))

(defun org-tickets--load-issue-types-from-document ()
  "Load issue type IDs from the #+JIRA_ISSUE_TYPES keyword, leaving point alone."
  (let ((raw (cadar (org-collect-keywords '("JIRA_ISSUE_TYPES")))))
    (when org-tickets-debug
      (message "org-tickets: raw issue types: %s" raw))
    (when (and raw (not (string= raw "")))
      (setq org-tickets--issue-type-ids
            (mapcar (lambda (pair)
                      (when (string-match "\\(.+\\)=\\(.+\\)" pair)
                        (let ((name (match-string-no-properties 1 pair))
                              (id (match-string-no-properties 2 pair)))
                          (cons (string-trim name) (string-trim id)))))
                    (split-string raw "," t)))
      (when org-tickets-debug
        (message "org-tickets: loaded issue types: %S" org-tickets--issue-type-ids))
      org-tickets--issue-type-ids)))

(defun org-tickets--save-issue-types-to-document ()
  "Write the #+JIRA_ISSUE_TYPES line into the org document.
Replaces an existing line in place (kill-ring untouched) or inserts
one at the top of the buffer."
  (save-excursion
    (goto-char (point-min))
    (if (re-search-forward "^#\\+JIRA_ISSUE_TYPES:.*$" nil t)
        (replace-match (org-tickets--format-issue-types-property) t t)
      (goto-char (point-min))
      (insert (org-tickets--format-issue-types-property) "\n"))))

(defun org-tickets--format-issue-types-property ()
  "Format issue type IDs as an org property line."
  (format "#+JIRA_ISSUE_TYPES: %s"
          (mapconcat (lambda (pair)
                       (format "%s=%s"
                               (substring-no-properties (car pair))
                               (substring-no-properties (cdr pair))))
                     org-tickets--issue-type-ids
                     ",")))

(defun org-tickets--create-ticket (type summary description
                                &optional fix-version labels
                                story-points sprint
                                attachments due-date)
  "Create a new ticket in Jira.
TYPE, SUMMARY, DESCRIPTION and the optional FIX-VERSION, LABELS,
STORY-POINTS, SPRINT, ATTACHMENTS, DUE-DATE as before.
Payload construction is delegated to `org-tickets--ticket-fields'; an
explicit SPRINT overrides the configured default sprint.  Parent
relationships are modeled as \"Blocks\" links, never Jira's parent
field, so no parent argument is accepted here."
  (org-tickets--ensure-issue-types)
  (let* ((ticket (org-tickets--ticket-create
                  :type type :summary summary :description description
                  :fix-version fix-version :labels labels
                  :story-points story-points :due-date due-date))
         (fields (org-tickets--ticket-fields ticket
                                          :create-p t
                                          :attachments attachments)))
    (when (and sprint (not (string= (format "%s" sprint) "")))
      (let ((sprint-id (org-tickets--resolve-sprint-value sprint))
            (field (intern org-tickets-sprint-field)))
        (when sprint-id
          (setq fields (assq-delete-all field fields))
          (setq fields (append fields (list (cons field sprint-id)))))))
    (org-tickets--api-request "POST" "/rest/api/3/issue"
                           (list (cons 'fields fields)))))

(defun org-tickets--update-ticket (ticket-key &rest args)
  "Update an existing Jira ticket TICKET-KEY.

ARGS is a plist of optional updates: :summary, :description,
:fix-version, :labels, :story-points, :sprint, :attachments and
:due-date.  Payload construction is delegated to
`org-tickets--ticket-fields'."
  (let* ((sprint (plist-get args :sprint))
         (ticket (org-tickets--ticket-create
                  :key ticket-key
                  :summary (plist-get args :summary)
                  :description (plist-get args :description)
                  :fix-version (plist-get args :fix-version)
                  :labels (plist-get args :labels)
                  :story-points (plist-get args :story-points)
                  :due-date (plist-get args :due-date)))
         (fields (org-tickets--ticket-fields
                  ticket :attachments (plist-get args :attachments))))
    (when (and sprint (not (string= (format "%s" sprint) "")))
      (let ((sprint-id (org-tickets--resolve-sprint-value sprint)))
        (when sprint-id
          (setq fields (append fields
                               (list (cons (intern org-tickets-sprint-field)
                                           sprint-id)))))))
    (when fields
      (org-tickets--api-request "PUT" (concat "/rest/api/3/issue/" ticket-key)
                             (list (cons 'fields fields))))))

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

(defvar org-tickets--sprint-cache nil
  "Cache of sprints for the current project: ((ID . \"name\") ...).")

(defun org-tickets--clear-sprint-cache ()
  "Clear the sprint cache, forcing a re-fetch on the next sprint lookup."
  (setq org-tickets--sprint-cache nil))

(defun org-tickets--resolve-sprint-value (sprint)
  "Resolve SPRINT to a numeric ID suitable for customfield_10020.
SPRINT may be a number, a numeric string, or a sprint name.
Returns the numeric ID (as a number), or nil if unresolvable."
  (cond
   ((numberp sprint) sprint)
   ((and (stringp sprint) (string-match "^[0-9]+$" sprint))
    (string-to-number sprint))
   ((stringp sprint)
    (let ((resolved (org-tickets--resolve-sprint-id sprint)))
      (cond
       ((numberp resolved) resolved)
       ((and (stringp resolved) (string-match "^[0-9]+$" resolved))
        (string-to-number resolved))
       (t nil))))
   (t nil)))

(defun org-tickets--resolve-sprint-id (sprint-name)
  "Resolve SPRINT-NAME to its numeric ID.
Uses cached sprints if available, otherwise fetches from Jira."
  (unless org-tickets--sprint-cache
    (let ((board-id (org-tickets--get-board-id-for-project)))
      (when board-id
        (setq org-tickets--sprint-cache (org-tickets--get-sprints-for-project board-id t)))))
  (assoc-default sprint-name org-tickets--sprint-cache #'string=))

(defun org-tickets--parse-sprint-from-jira-response (sprint-data)
  "Parse sprint data from Jira API response.
SPRINT-DATA may be a single object, a list of sprints, or a dotted pair.
Returns the sprint name as a string, or nil if not available."
  (when sprint-data
    (let* ((is-proper-list (proper-list-p sprint-data))
           ;; Get the first sprint from various formats
           (first-sprint (cond
                          ;; Proper list of sprints - take first
                          (is-proper-list (car sprint-data))
                          ;; Dotted pair: (first . second) - take car
                          ((consp sprint-data) (car sprint-data))
                          ;; Single item - use directly
                          (t sprint-data)))
           ;; Convert dotted pair to proper list if needed for org-tickets--alist-get
           (first-sprint-alist (if (and first-sprint
                                         (consp first-sprint)
                                         (not (consp (cdr first-sprint))))
                                    (list first-sprint)
                                  first-sprint)))
      ;; Extract name from the alist
      (org-tickets--alist-get "name" first-sprint-alist))))

(provide 'org-tickets-api)

;;; org-tickets-api.el ends here
