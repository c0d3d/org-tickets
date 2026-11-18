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

;; Tests for the JIRA_SYNCED baseline recorded after each push, and the
;; pre-flight check for Jira edits made by someone else.

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

;;;; Pre-flight remote change check

(defconst org-tickets-test--baseline "2026-11-01T00:00:00.000+0000"
  "The JIRA_SYNCED baseline of every heading in the check tests.")

(defconst org-tickets-test--after-baseline "2026-11-10T00:00:00.000+0000"
  "A changelog timestamp later than `org-tickets-test--baseline'.")

(defun org-tickets-test--remote-issue (key &rest args)
  "Return the issue response for Feature KEY built from ARGS.
ARGS is as for `org-tickets-test--issue-response'."
  (apply #'org-tickets-test--issue-response
         :key key :type "Feature" :updated org-tickets-test--updated args))

(defun org-tickets-test--remote-get (issues)
  "Return a fake-Jira `:get' function answering from ISSUES.
/rest/api/3/myself answers with account id \"me\".  An issue GET for a
key in ISSUES, an alist of (KEY . RESPONSE), answers with its response;
any other issue gets a Feature response with no changelog."
  (lambda (endpoint)
    (if (equal endpoint "/rest/api/3/myself")
        (org-tickets-test--json "{\"accountId\":\"me\"}")
      (let ((key (and (string-match "/issue/\\([^/?]+\\)" endpoint)
                      (match-string 1 endpoint))))
        (or (cdr (assoc key issues))
            (org-tickets-test--remote-issue key))))))

(defun org-tickets-test--edit-by (author-id author-name &rest field-ids)
  "Return a changelog history by AUTHOR-ID/AUTHOR-NAME editing FIELD-IDS."
  (append (list author-id author-name org-tickets-test--after-baseline)
          field-ids))

(defun org-tickets-test--insert-synced-feature (title key &rest props)
  "Append Feature TITLE with KEY, the check baseline, and PROPS."
  (apply #'org-tickets-test--insert-feature title key
         "JIRA_SYNCED" org-tickets-test--baseline props))

(defmacro org-tickets-test--with-remote-sync (issues log warnings &rest body)
  "Run BODY in a temp org buffer synced against a fake Jira.
The fake answers GETs through `org-tickets-test--remote-get' of ISSUES
and logs into the variable LOG.  Warnings shown with `display-warning'
are pushed onto the variable WARNINGS."
  (declare (indent 3))
  `(let ((,log nil) (,warnings nil))
     (org-tickets-test--with-sync-mocks
         (org-tickets-test--fake-jira-handler
          :get (org-tickets-test--remote-get ,issues) :log ,log)
       (org-tickets-test--with-stubs
           ((display-warning
             (lambda (_type text &rest _) (push text ,warnings))))
         (with-temp-buffer
           (org-mode)
           ,@body)))))

(defun org-tickets-test--pushes (log)
  "Return the PUT and POST requests in LOG."
  (append (org-tickets-test--requests log "PUT")
          (org-tickets-test--requests log "POST")))

(ert-deftest org-tickets-test--sync-cancels-on-foreign-description-edit ()
  "Someone else's description edit cancels the sync with a warning."
  (org-tickets-test--with-remote-sync
      (list (cons "PROJ-10" (org-tickets-test--remote-issue
                             "PROJ-10" :histories
                             (list (org-tickets-test--edit-by
                                    "bob" "Bob" "description")))))
      log warnings
    (org-tickets-test--insert-synced-feature "Feature A" "PROJ-10")
    (org-tickets-test--run-sync)
    (should-not (org-tickets-test--pushes log))
    (should (= (length warnings) 1))
    (should (string-match-p "PROJ-10: description changed by Bob"
                            (car warnings)))
    (should-not buffer-read-only)
    (should-not org-tickets--sync-in-progress)))

(ert-deftest org-tickets-test--sync-cancel-leaves-buffer-untouched ()
  "A cancelled sync pulls nothing, even for metadata-only changes."
  (org-tickets-test--with-remote-sync
      (list (cons "PROJ-10" (org-tickets-test--remote-issue
                             "PROJ-10" :histories
                             (list (org-tickets-test--edit-by
                                    "bob" "Bob" "summary"))))
            (cons "PROJ-20" (org-tickets-test--remote-issue
                             "PROJ-20" :labels '("remote") :histories
                             (list (org-tickets-test--edit-by
                                    "bob" "Bob" "labels")))))
      log warnings
    (org-tickets-test--insert-synced-feature "Feature A" "PROJ-10")
    (org-tickets-test--insert-synced-feature "Feature B" "PROJ-20"
                                             "LABELS" "local")
    (let ((before (buffer-string)))
      (org-tickets-test--run-sync)
      (should (equal (buffer-string) before)))))

(ert-deftest org-tickets-test--sync-pulls-foreign-metadata-then-pushes ()
  "Someone else's metadata edit is pulled into org and then pushed."
  (org-tickets-test--with-remote-sync
      (list (cons "PROJ-10" (org-tickets-test--remote-issue
                             "PROJ-10" :labels '("remote") :histories
                             (list (org-tickets-test--edit-by
                                    "bob" "Bob" "labels")))))
      log warnings
    (org-tickets-test--insert-synced-feature "Feature A" "PROJ-10"
                                             "LABELS" "local")
    (org-tickets-test--run-sync)
    (should (equal (org-tickets-test--prop-of "PROJ-10" "LABELS") "remote"))
    (let ((put (car (org-tickets-test--requests
                     log "PUT" "/rest/api/3/issue/PROJ-10"))))
      (should put)
      (should (equal (append (org-tickets-test--payload-field
                              (nth 2 put) 'labels)
                             nil)
                     '("remote"))))
    (should-not warnings)))

(ert-deftest org-tickets-test--sync-ignores-my-own-remote-edits ()
  "My own description edit in Jira does not cancel the sync."
  (org-tickets-test--with-remote-sync
      (list (cons "PROJ-10" (org-tickets-test--remote-issue
                             "PROJ-10" :histories
                             (list (org-tickets-test--edit-by
                                    "me" "Me" "description")))))
      log warnings
    (org-tickets-test--insert-synced-feature "Feature A" "PROJ-10")
    (org-tickets-test--run-sync)
    (should (org-tickets-test--requests log "PUT" "/rest/api/3/issue/PROJ-10"))
    (should-not warnings)))

(ert-deftest org-tickets-test--sync-skips-check-without-baseline ()
  "Without any JIRA_SYNCED baseline, no check request is made."
  (org-tickets-test--with-remote-sync nil log _warnings
    (org-tickets-test--insert-feature "Feature A" "PROJ-10")
    (org-tickets-test--run-sync)
    (should-not (org-tickets-test--requests log "GET" "/rest/api/3/myself"))
    (should-not (seq-filter (lambda (request)
                              (string-match-p "expand=changelog" (nth 1 request)))
                            (org-tickets-test--requests log "GET")))
    (should (org-tickets-test--requests log "PUT"))))

(ert-deftest org-tickets-test--sync-cancels-when-check-request-fails ()
  "A failed check request cancels the sync and names the ticket."
  (let* ((log nil)
         (messages nil)
         (ok (org-tickets-test--fake-jira-handler
              :get (org-tickets-test--remote-get nil) :log log))
         (handler (lambda (method endpoint callback &optional data)
                    (if (string-match-p "PROJ-10\\?expand=changelog" endpoint)
                        (progn (push (list method endpoint data) log)
                               (funcall callback nil "boom"))
                      (funcall ok method endpoint callback data)))))
    (org-tickets-test--with-sync-mocks handler
      (org-tickets-test--with-stubs
          ((message (lambda (format-string &rest args)
                      (when format-string
                        (push (apply #'format format-string args) messages)))))
        (with-temp-buffer
          (org-mode)
          (org-tickets-test--insert-synced-feature "Feature A" "PROJ-10")
          (org-tickets-test--run-sync)
          (should-not (org-tickets-test--pushes log))
          (should-not buffer-read-only)
          (should-not org-tickets--sync-in-progress)
          (should (seq-find (lambda (m) (string-match-p "PROJ-10" m))
                            messages)))))))

(ert-deftest org-tickets-test--sync-parse-error-signals-and-unlocks ()
  "A parse error before phase 1 still signals and leaves the buffer unlocked."
  (org-tickets-test--with-remote-sync nil _log _warnings
    (org-tickets-test--with-stubs
        ((org-tickets--parse-document (lambda () (error "Bad document"))))
      (org-tickets-test--insert-feature "Feature A" "PROJ-10")
      (should-error (org-tickets-test--run-sync))
      (should-not buffer-read-only)
      (should-not org-tickets--sync-in-progress))))

(ert-deftest org-tickets-test--sync-pull-error-unlocks-buffer ()
  "An error while pulling metadata ends the sync without pushing."
  (org-tickets-test--with-remote-sync
      (list (cons "PROJ-10" (org-tickets-test--remote-issue
                             "PROJ-10" :histories
                             (list (org-tickets-test--edit-by
                                    "bob" "Bob" "labels")))))
      log _warnings
    (org-tickets-test--with-stubs
        ((org-tickets--pull-ticket-metadata (lambda (&rest _) (error "Boom")))
         (message #'ignore))
      (org-tickets-test--insert-synced-feature "Feature A" "PROJ-10")
      (org-tickets-test--run-sync)
      (should-not (org-tickets-test--pushes log))
      (should-not buffer-read-only)
      (should-not org-tickets--sync-in-progress))))

(defmacro org-tickets-test--with-messages (messages &rest body)
  "Run BODY, pushing each formatted `message' onto the variable MESSAGES."
  (declare (indent 1))
  `(org-tickets-test--with-stubs
       ((message (lambda (format-string &rest args)
                   (when format-string
                     (push (apply #'format format-string args) ,messages)))))
     ,@body))

(ert-deftest org-tickets-test--sync-cancels-when-account-lookup-fails ()
  "A failed /myself request cancels the sync and blames the account lookup."
  (let* ((log nil)
         (messages nil)
         (ok (org-tickets-test--fake-jira-handler
              :get (org-tickets-test--remote-get nil) :log log))
         (handler (lambda (method endpoint callback &optional data)
                    (if (equal endpoint "/rest/api/3/myself")
                        (funcall callback nil "boom")
                      (funcall ok method endpoint callback data)))))
    (org-tickets-test--with-sync-mocks handler
      (org-tickets-test--with-messages messages
        (with-temp-buffer
          (org-mode)
          (org-tickets-test--insert-synced-feature "Feature A" "PROJ-10")
          (org-tickets-test--run-sync)
          (should-not (org-tickets-test--pushes log))
          (should-not buffer-read-only)
          (should-not org-tickets--sync-in-progress)
          (should (seq-find (lambda (m)
                              (string-match-p "could not look up your Jira account: boom" m))
                            messages))
          (should-not (seq-find (lambda (m) (string-match-p "PROJ-10" m))
                                messages)))))))

(ert-deftest org-tickets-test--sync-check-failure-suggests-deleted-ticket-fix ()
  "A failed check request tells the user how to unblock a deleted ticket."
  (let* ((messages nil)
         (ok (org-tickets-test--fake-jira-handler
              :get (org-tickets-test--remote-get nil)))
         (handler (lambda (method endpoint callback &optional data)
                    (if (string-match-p "expand=changelog" endpoint)
                        (funcall callback nil "404")
                      (funcall ok method endpoint callback data)))))
    (org-tickets-test--with-sync-mocks handler
      (org-tickets-test--with-messages messages
        (with-temp-buffer
          (org-mode)
          (org-tickets-test--insert-synced-feature "Feature A" "PROJ-10")
          (org-tickets-test--run-sync)
          (should (seq-find
                   (lambda (m)
                     (string-match-p
                      "if the ticket was deleted, remove its JIRA_KEY and JIRA_SYNCED"
                      m))
                   messages)))))))

(ert-deftest org-tickets-test--sync-keeps-local-metadata-on-untracked-change ()
  "A foreign status change pulls nothing, so local LABELS are pushed."
  (let ((messages nil))
    (org-tickets-test--with-remote-sync
        (list (cons "PROJ-10" (org-tickets-test--remote-issue
                               "PROJ-10" :labels '("remote") :histories
                               (list (org-tickets-test--edit-by
                                      "bob" "Bob" "status")))))
        log warnings
      (org-tickets-test--with-messages messages
        (org-tickets-test--insert-synced-feature "Feature A" "PROJ-10"
                                                 "LABELS" "local")
        (org-tickets-test--run-sync))
      (should (equal (org-tickets-test--prop-of "PROJ-10" "LABELS") "local"))
      (let ((put (car (org-tickets-test--requests
                       log "PUT" "/rest/api/3/issue/PROJ-10"))))
        (should (equal (append (org-tickets-test--payload-field
                                (nth 2 put) 'labels)
                               nil)
                       '("local"))))
      (should-not (seq-find (lambda (m) (string-match-p "Pulled remote metadata" m))
                            messages))
      (should-not warnings))))

(ert-deftest org-tickets-test--sync-pulls-only-changed-metadata ()
  "A foreign labels change pulls LABELS but keeps a local STORY_POINTS edit."
  (org-tickets-test--with-remote-sync
      (list (cons "PROJ-10" (org-tickets-test--remote-issue
                             "PROJ-10" :labels '("remote") :histories
                             (list (org-tickets-test--edit-by
                                    "bob" "Bob" "labels")))))
      _log _warnings
    (org-tickets-test--insert-synced-feature "Feature A" "PROJ-10"
                                             "LABELS" "local"
                                             "STORY_POINTS" "5")
    (org-tickets-test--run-sync)
    (should (equal (org-tickets-test--prop-of "PROJ-10" "LABELS") "remote"))
    (should (equal (org-tickets-test--prop-of "PROJ-10" "STORY_POINTS") "5"))))

(ert-deftest org-tickets-test--sync-pushes-after-pulling-content-conflict ()
  "Pulling a conflicting ticket records a baseline, so the next sync pushes."
  (org-tickets-test--with-remote-sync
      (list (cons "PROJ-10" (org-tickets-test--remote-issue
                             "PROJ-10" :summary "Feature A" :histories
                             (list (org-tickets-test--edit-by
                                    "bob" "Bob" "description")))))
      log warnings
    (org-tickets-test--insert-synced-feature "Feature A" "PROJ-10")
    (org-tickets-test--run-sync)
    (should-not (org-tickets-test--pushes log))
    (goto-char (point-min))
    (org-tickets-test--with-stubs ((message #'ignore))
      (org-tickets-pull-remote-changes))
    (should (equal (org-tickets-test--prop-of "PROJ-10" "JIRA_SYNCED")
                   org-tickets-test--updated))
    (org-tickets-test--run-sync)
    (should (org-tickets-test--requests log "PUT" "/rest/api/3/issue/PROJ-10"))
    (should (= (length warnings) 1))))

(provide 'org-tickets-test-sync-remote-changes)
;;; org-tickets-test-sync-remote-changes.el ends here
