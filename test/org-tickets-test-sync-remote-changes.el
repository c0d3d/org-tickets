;;; org-tickets-test-sync-remote-changes.el --- Tests for remote-change detection during sync  -*- lexical-binding: t; -*-

;; Copyright (C) 2025  Neil Locketz

;; Author: Neil Locketz <neil@nlocketz.com>
;; Keywords: org, jira, tests

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

;; Tests for the JIRA_SYNCED baseline recorded after each push.

;;; Code:

(require 'ert)
(require 'org-tickets-test-fixtures)
(require 'org-tickets)

(defconst org-tickets-test--updated "2026-11-18T10:00:00.000+0000"
  "A Jira `updated' timestamp used by the remote-change tests.")

(ert-deftest org-tickets-test--sync-records-jira-synced-after-push ()
  "A pushed existing ticket gets JIRA_SYNCED set to Jira's updated time."
  (org-tickets-test--with-sync-mocks
      (org-tickets-test--fake-jira-handler
       :get (org-tickets-test--issue-response
             :updated org-tickets-test--updated))
    (with-temp-buffer
      (org-mode)
      (org-tickets-test--insert-feature "Feature A" "PROJ-10")
      (org-tickets-test--run-sync)
      (should (equal (org-tickets-test--prop-of "PROJ-10" "JIRA_SYNCED")
                     org-tickets-test--updated)))))

(ert-deftest org-tickets-test--sync-keeps-old-jira-synced-when-put-fails ()
  "A failed PUT leaves the previous JIRA_SYNCED baseline untouched."
  (let* ((old "2026-01-01T00:00:00.000+0000")
         (ok (org-tickets-test--fake-jira-handler
              :get (org-tickets-test--issue-response
                    :updated org-tickets-test--updated)))
         (handler (lambda (method endpoint callback &optional data)
                    (if (equal method "PUT")
                        (funcall callback nil "boom")
                      (funcall ok method endpoint callback data)))))
    (org-tickets-test--with-sync-mocks handler
      (with-temp-buffer
        (org-mode)
        (org-tickets-test--insert-feature
         "Feature A" "PROJ-10" "JIRA_SYNCED" old)
        (org-tickets-test--run-sync)
        (should (equal (org-tickets-test--prop-of "PROJ-10" "JIRA_SYNCED")
                       old))))))

(ert-deftest org-tickets-test--sync-new-ticket-gets-no-jira-synced ()
  "A ticket created by the sync has no JIRA_SYNCED baseline."
  (org-tickets-test--with-sync-mocks
      (org-tickets-test--fake-jira-handler :post-keys '("PROJ-NEW"))
    (with-temp-buffer
      (org-mode)
      (org-tickets-test--insert-feature "Brand New" nil)
      (org-tickets-test--run-sync)
      (should-not (org-tickets-test--prop-of "PROJ-NEW" "JIRA_SYNCED")))))

(provide 'org-tickets-test-sync-remote-changes)
;;; org-tickets-test-sync-remote-changes.el ends here
