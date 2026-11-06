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

;;;; Issue accessors

(defun org-tickets--issue-due-date (response)
  "Return the due date of the Jira issue RESPONSE, or nil."
  (org-tickets--response-field response "duedate"))

(defun org-tickets--issue-fix-version (response)
  "Return the name of the first fix version of issue RESPONSE, or nil."
  (let ((first (car (org-tickets--ensure-list
                     (org-tickets--response-field response "fixVersions")))))
    (org-tickets--alist-get "name" first)))

(defun org-tickets--issue-sprint (response)
  "Return the name of the first sprint of issue RESPONSE, or nil.
The sprint is read from the field named by `org-tickets-sprint-field'."
  (let ((sprints (org-tickets--response-field response org-tickets-sprint-field)))
    (when (consp sprints)
      (org-tickets--alist-get "name" (car sprints)))))

(defun org-tickets--issue-attachments (response)
  "Return the raw Jira attachment list of issue RESPONSE, or nil."
  (org-tickets--ensure-list (org-tickets--response-field response "attachment")))

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
             (is-last (org-tickets--alist-get "isLast" response))
             (last-page-p (and is-last (not (eq is-last :json-false)))))
        (setq all-values (append all-values values))
        (if (or last-page-p (null values))
            (setq done t)
          (setq start-at (+ start-at (length values))))))
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

(defun org-tickets--ticket-request-fields (ticket create-p)
  "Return the Jira `fields' alist for TICKET, a `org-tickets--ticket' record.
CREATE-P selects the create field set.  The record's attachments resolve
attachment: links, and its sprint overrides any default sprint."
  (org-tickets--with-sprint-field
   (org-tickets--ticket-fields ticket
                            :create-p create-p
                            :attachments (org-tickets--ticket-attachments ticket))
   (org-tickets--ticket-sprint ticket)))

(defun org-tickets--create-ticket (ticket)
  "Create TICKET, an `org-tickets--ticket' record, in Jira.
Returns the Jira response, whose `key' is the new issue key.  Payload
construction is delegated to `org-tickets--ticket-fields'; the record's
sprint overrides the configured default sprint.  Parent relationships
are modeled as \"Blocks\" links, never Jira's parent field."
  (org-tickets--ensure-issue-types)
  (org-tickets--api-request
   "POST" "/rest/api/3/issue"
   (list (cons 'fields (org-tickets--ticket-request-fields ticket t)))))

(defun org-tickets--update-ticket (ticket)
  "PUT TICKET, an `org-tickets--ticket' record, to its Jira issue.
Only the fields the record carries are sent; its `clear-labels' and
`clear-story-points' slots clear those fields.  Sends nothing when the
record carries no fields."
  (let ((fields (org-tickets--ticket-request-fields ticket nil)))
    (when fields
      (org-tickets--api-request
       "PUT" (concat "/rest/api/3/issue/" (org-tickets--ticket-key ticket))
       (list (cons 'fields fields))))))

(defvar org-tickets--sprint-cache nil
  "Cache of sprints for the current project: ((\"name\" . ID) ...).")

(defun org-tickets--clear-sprint-cache ()
  "Clear the sprint cache, forcing a re-fetch on the next sprint lookup."
  (setq org-tickets--sprint-cache nil))

(defun org-tickets--resolve-sprint-value (sprint)
  "Resolve SPRINT to a numeric ID for the field `org-tickets-sprint-field'.
SPRINT may be a number, a numeric string, or a sprint name.
Returns the numeric ID (as a number), or nil if SPRINT is nil or empty
or cannot be resolved."
  (cond
   ((or (null sprint) (equal sprint "")) nil)
   ((numberp sprint) sprint)
   ((not (stringp sprint)) nil)
   ((string-match-p "\\`[0-9]+\\'" sprint) (string-to-number sprint))
   (t (let ((id (org-tickets--resolve-sprint-id sprint)))
        (and (numberp id) id)))))

(defun org-tickets--with-sprint-field (fields sprint)
  "Return FIELDS with the sprint field set from SPRINT.
SPRINT is resolved by `org-tickets--resolve-sprint-value'; any existing
`org-tickets-sprint-field' entry is replaced.  FIELDS is returned
unchanged when SPRINT is nil, empty or unresolvable."
  (let ((sprint-id (org-tickets--resolve-sprint-value sprint))
        (field (intern org-tickets-sprint-field)))
    (if sprint-id
        (append (assq-delete-all field fields) (list (cons field sprint-id)))
      fields)))

(defun org-tickets--resolve-sprint-id (sprint-name)
  "Resolve SPRINT-NAME to its numeric ID.
Uses cached sprints if available, otherwise fetches from Jira."
  (unless org-tickets--sprint-cache
    (let ((board-id (org-tickets--get-board-id-for-project)))
      (when board-id
        (setq org-tickets--sprint-cache (org-tickets--get-sprints-for-project board-id t)))))
  (assoc-default sprint-name org-tickets--sprint-cache #'string=))

(provide 'org-tickets-api)

;;; org-tickets-api.el ends here
