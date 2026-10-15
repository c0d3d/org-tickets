;;; org-tickets.el --- Manage Jira tickets from Org-mode files  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Neil Locketz

;; Author: Neil Locketz <neil@nlocketz.com>
;; Keywords: outlines, comm, tools
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (org "9.6"))
;; URL: https://github.com/c0d3d/org-tickets

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

;; Manage Jira tickets from Org-mode files.  Each heading is a ticket;
;; syncing creates or updates the matching Jira issue and writes the
;; issue key back into the heading's property drawer.
;;
;; Supported workflow:
;; - Parent tickets (Feature, Improvement, Epic) and child tickets
;;   (Story, Task, Bug, ...) linked to their parent with "Blocks"
;; - Blocks/Blocked-by relationships between tickets
;; - Fix Versions, labels, story points, sprints and due dates
;; - Attachment upload and download via `org-attach'
;;
;; Configuration:
;; - Customize `org-tickets-base-url', `org-tickets-project-key' and
;;   `org-tickets-project-id' (M-x customize-group RET org-tickets).
;; - Credentials are read with `auth-source' (e.g. ~/.authinfo.gpg)
;;   using the host from `org-tickets-base-url'.
;; - Issue type IDs are fetched from Jira on first sync and cached in
;;   the Org document.

;;; Code:

(require 'org-tickets-core)
(require 'org-tickets-api)
(require 'org-tickets-async)
(require 'org-tickets-convert)
(require 'org-tickets-fields)
(require 'org-tickets-attachments)
(require 'org-tickets-parse)
(require 'org-tickets-adf-import)
(require 'org-tickets-sync-phases)
(require 'org-tickets-sync)
(require 'org-tickets-import)
(require 'org-tickets-cmd)

(provide 'org-tickets)

;;; org-tickets.el ends here
