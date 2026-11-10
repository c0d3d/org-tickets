;;; org-tickets-test-sync-errors.el --- Sync pipeline failure paths  -*- lexical-binding: t; -*-

;;; Commentary:

;; Failure paths of the async sync pipeline (org-tickets-sync-phases.el):
;; failed phase-1 requests, a killed buffer, errors signalled from a
;; response callback after the sync command returned, and the phase-3
;; buffer write-back helpers.

;;; Code:

(require 'ert)
(require 'org-tickets-test-fixtures)

(require 'org-tickets)
(require 'org-tickets-sync-phases)

;;;; Helpers

(defun org-tickets-test--failing-handler (fail-p inner)
  "Return a request handler failing requests that match FAIL-P.
FAIL-P is called with METHOD and ENDPOINT; a match answers with a
\"500\" error and is not passed on.  Every other request goes to INNER."
  (lambda (method endpoint callback &optional data)
    (if (funcall fail-p method endpoint)
        (funcall callback nil "Jira API error: HTTP/1.1 500 Internal Server Error")
      (funcall inner method endpoint callback data))))

(defmacro org-tickets-test--capturing-messages (var &rest body)
  "Run BODY collecting every formatted `message' onto VAR, newest first."
  (declare (indent 1))
  `(org-tickets-test--with-stubs
       ((message (lambda (fmt &rest args)
                   (when fmt (push (apply #'format fmt args) ,var)))))
     ,@body))

(defun org-tickets-test--message-matching (messages regexp)
  "Return the first of MESSAGES matching REGEXP, or nil."
  (seq-find (lambda (m) (string-match-p regexp m)) messages))

(defun org-tickets-test--deferred-handler (box)
  "Return a request handler that holds every request in BOX.
BOX is a one-element list whose car collects (METHOD ENDPOINT CALLBACK)
entries, newest first, until `org-tickets-test--drain' answers them."
  (lambda (method endpoint callback &optional _data)
    (push (list method endpoint callback) (car box))))

(defun org-tickets-test--drain (box)
  "Answer the requests held in BOX like Jira, oldest first, until none remain.
Each callback runs through `org-tickets--async-safe-callback', as a real
response would, so an error it signals is trapped and logged."
  (let ((key-queue (list '("PROJ-NEW"))))
    (while (car box)
      (let ((request (car (last (car box)))))
        (setcar box (butlast (car box)))
        (org-tickets--async-safe-callback
         (nth 2 request)
         (org-tickets-test--fake-jira-answer
          (nth 0 request) (nth 1 request)
          (org-tickets-test--make-get-response "Sprint 1")
          key-queue)
         nil)))))

(defun org-tickets-test--sync-unlocked-p ()
  "Return non-nil when the current buffer shows no sync left in progress."
  (and (not buffer-read-only)
       (not org-tickets--sync-in-progress)
       (null org-tickets--sync-saved-point)))

(defmacro org-tickets-test--deferred-sync-signalling (fn &rest body)
  "Sync a feature against a Jira answering later, with FN signalling.
FN is a function symbol stubbed to signal an error.  The sync command
returns first; the responses then arrive through the real trapped
callback path.  BODY runs afterwards in the org buffer."
  (declare (indent 1))
  `(let ((box (list nil)))
     (org-tickets-test--with-sync-mocks (org-tickets-test--deferred-handler box)
       (org-tickets-test--with-stubs
           ((,fn (lambda (&rest _) (error "Simulated failure")))
            (display-warning #'ignore))
         (with-temp-buffer
           (org-mode)
           (org-tickets-test--insert-feature "Feature" "PROJ-1")
           (org-tickets-test--run-sync)
           (should buffer-read-only)
           (org-tickets-test--drain box)
           ,@body)))))

;;;; Phase 1 failures

(ert-deftest org-tickets-test--failed-get-skips-put-and-reports-error ()
  "A failed GET of an existing ticket sends no PUT, is counted as an error
in the final message, and leaves the buffer unlocked."
  (let ((requests nil)
        (messages nil))
    (org-tickets-test--with-sync-mocks
        (org-tickets-test--failing-handler
         (lambda (method _endpoint) (equal method "GET"))
         (org-tickets-test--fake-jira-handler :log requests))
      (org-tickets-test--capturing-messages messages
        (with-temp-buffer
          (org-mode)
          (org-tickets-test--insert-feature "Feature" "PROJ-1")
          (org-tickets-test--run-sync)
          (should (org-tickets-test--sync-unlocked-p)))))
    (should-not (org-tickets-test--requests requests "PUT"))
    (should (org-tickets-test--message-matching
             messages "Sync complete (1 tickets, 1 errors)"))
    (should (org-tickets-test--message-matching messages "Error syncing PROJ-1"))))

(ert-deftest org-tickets-test--failed-put-error-is-reported ()
  "A failed PUT's error reaches the final report with the ticket's key."
  (let ((messages nil))
    (org-tickets-test--with-sync-mocks
        (org-tickets-test--failing-handler
         (lambda (method _endpoint) (equal method "PUT"))
         (org-tickets-test--fake-jira-handler))
      (org-tickets-test--capturing-messages messages
        (with-temp-buffer
          (org-mode)
          (org-tickets-test--insert-feature "Feature" "PROJ-1")
          (org-tickets-test--run-sync))))
    (should (org-tickets-test--message-matching
             messages "Error syncing PROJ-1: .*500 Internal Server Error"))
    (should (org-tickets-test--message-matching
             messages "Sync complete (1 tickets, 1 errors)"))))

(ert-deftest org-tickets-test--failed-create-writes-nothing-back ()
  "A failed issue create writes no JIRA_KEY, SPRINT or DUE_DATE, even with a
default sprint configured, and is counted as an error."
  (let ((messages nil))
    (org-tickets-test--with-sync-mocks
        (org-tickets-test--failing-handler
         (lambda (method endpoint)
           (and (equal method "POST") (equal endpoint "/rest/api/3/issue")))
         (org-tickets-test--fake-jira-handler))
      (let ((org-tickets-default-sprint "42"))
        (org-tickets-test--capturing-messages messages
          (with-temp-buffer
            (org-mode)
            (org-tickets-test--insert-feature "Feature" "PROJ-1")
            (org-tickets-test--insert-story "New Story" nil nil)
            (org-tickets-test--run-sync)
            (should (org-tickets-test--sync-unlocked-p))
            (goto-char (point-min))
            (search-forward "New Story")
            (should-not (org-entry-get (point) "JIRA_KEY"))
            (should-not (org-entry-get (point) "SPRINT"))
            (should-not (org-entry-get (point) "DUE_DATE"))))))
    (should (org-tickets-test--message-matching
             messages "Sync complete (2 tickets, 1 errors)"))))

(ert-deftest org-tickets-test--put-skipped-when-ticket-has-no-fields ()
  "An existing ticket with nothing to send gets no PUT; done still fires once."
  (let ((requests nil)
        (results nil))
    (org-tickets-test--with-fake-config
      (org-tickets-test--with-stubs
          ((org-tickets--async-request
            (org-tickets-test--fake-jira-handler :log requests))
           (org-tickets--ticket-fields #'ignore))
        (with-temp-buffer
          (org-tickets--fire-ticket-put
           (org-tickets--ticket-create :key "PROJ-1") "PROJ-1" nil "Sprint 1" nil
           (current-buffer)
           (lambda (result err) (push (cons result err) results))))))
    (should-not requests)
    (should (= (length results) 1))
    (let ((result (caar results)))
      (should (equal (org-tickets--sync-result-key result) "PROJ-1"))
      (should (equal (org-tickets--sync-result-sprint result) "Sprint 1"))
      (should-not (org-tickets--sync-result-error result)))))

(ert-deftest org-tickets-test--new-ticket-thunk-dead-buffer-sends-nothing ()
  "A create whose org buffer was killed sends no POST and reports one error."
  (let ((requests nil)
        (results nil)
        (buffer (generate-new-buffer " *dead*")))
    (kill-buffer buffer)
    (org-tickets-test--with-fake-config
      (org-tickets-test--with-stubs
          ((org-tickets--async-request
            (org-tickets-test--fake-jira-handler :log requests)))
        (funcall (org-tickets--make-new-ticket-thunk
                  (org-tickets--ticket-create :type "Story" :summary "S")
                  buffer)
                 (lambda (result err) (push (cons result err) results)))))
    (should-not requests)
    (should (= (length results) 1))
    (let ((result (caar results)))
      (should (org-tickets--sync-result-error result))
      (should-not (org-tickets--sync-result-key result)))))

;;;; Errors after the sync command returned

(ert-deftest org-tickets-test--phase-3-error-still-unlocks-buffer ()
  "An error while writing a fetched sprint back still ends the sync."
  (org-tickets-test--deferred-sync-signalling org-tickets--set-org-sprint
    (should (org-tickets-test--sync-unlocked-p))))

(ert-deftest org-tickets-test--blocked-by-write-back-error-still-unlocks-buffer ()
  "An error while resolving BLOCKED-BY in phase 3 still ends the sync."
  (org-tickets-test--deferred-sync-signalling org-tickets--resolve-blocked-by-in-org
    (should (org-tickets-test--sync-unlocked-p))))

(ert-deftest org-tickets-test--phase-2-error-still-unlocks-buffer ()
  "An error in a response callback before phase 3 still ends the sync."
  (org-tickets-test--deferred-sync-signalling org-tickets--apply-new-keys
    (should (org-tickets-test--sync-unlocked-p))))

(ert-deftest org-tickets-test--phase-3-error-keeps-prior-read-only ()
  "A buffer the user made read-only stays read-only after a failed phase 3."
  (let ((box (list nil)))
    (org-tickets-test--with-sync-mocks (org-tickets-test--deferred-handler box)
      (org-tickets-test--with-stubs
          ((org-tickets--set-org-sprint (lambda (&rest _) (error "Boom")))
           (display-warning #'ignore)
           (org-tickets--progress-install #'ignore))
        (with-temp-buffer
          (org-mode)
          (org-tickets-test--insert-feature "Feature" "PROJ-1")
          (setq buffer-read-only t)
          (org-tickets--sync-to-jira)
          (org-tickets-test--drain box)
          (should buffer-read-only)
          (should-not org-tickets--sync-in-progress))))))

;;;; Phase 3 write-back

(ert-deftest org-tickets-test--sync-releases-ticket-markers ()
  "After a sync, the heading markers of the parsed tickets are unset."
  (let ((docs nil)
        (parse (symbol-function 'org-tickets--parse-document)))
    (org-tickets-test--with-sync-mocks nil
      (org-tickets-test--with-stubs
          ((org-tickets--parse-document
            (lambda () (car (push (funcall parse) docs)))))
        (with-temp-buffer
          (org-mode)
          (org-tickets-test--insert-feature "Feature" "PROJ-1")
          (org-tickets-test--insert-story "Story" "PROJ-2" "PROJ-1")
          (org-tickets-test--run-sync))))
    (let ((tickets (org-tickets--doc-tickets (car (last docs)))))
      (should (= (length tickets) 2))
      (dolist (ticket tickets)
        (should-not (marker-position (org-tickets--ticket-marker ticket)))))))

(ert-deftest org-tickets-test--new-child-inherits-fetched-due-date ()
  "A child created in this run inherits the due date phase 1 fetched for its
parent, though only the buffer knows its new key."
  (org-tickets-test--with-sync-mocks
      (org-tickets-test--fake-jira-handler
       :get (org-tickets-test--make-get-response nil "2026-12-01")
       :post-keys '("PROJ-50"))
    (with-temp-buffer
      (org-mode)
      (org-tickets-test--insert-feature "Feature" "PROJ-1")
      (org-tickets-test--insert-ticket 2 "New Story" "JIRA_TYPE" "Story")
      (org-tickets-test--run-sync)
      (should (equal (org-tickets-test--prop-of "PROJ-50" "DUE_DATE")
                     "2026-12-01")))))

(ert-deftest org-tickets-test--apply-new-keys-skips-failed-create ()
  "A new ticket whose create failed (nil key) gets no JIRA_KEY."
  (with-temp-buffer
    (org-mode)
    (org-tickets-test--insert-ticket 1 "Story" "JIRA_TYPE" "Story")
    (let ((ticket (car (org-tickets--doc-tickets (org-tickets--parse-document)))))
      (org-tickets--apply-new-keys
       (list (org-tickets--sync-result-create :ticket ticket :is-new t
                                              :key nil :error "500")))
      (goto-char (point-min))
      (should-not (org-entry-get (point) "JIRA_KEY")))))

(ert-deftest org-tickets-test--ticket-blockers-drop-self-and-empty ()
  "BLOCKED-BY entries naming the ticket itself or nothing are not blockers."
  (should (equal (org-tickets--ticket-blockers
                  (org-tickets--ticket-create :key "P-1"
                                              :blocked-by '("P-1" "" "P-2")))
                 '("P-2")))
  (should-not (org-tickets--ticket-blockers
               (org-tickets--ticket-create :key nil :blocked-by '("P-2")))))

(ert-deftest org-tickets-test--ensure-blocks-entry-matches-exact-keys ()
  "An existing PROJ-200 does not count as PROJ-20 already being listed."
  (with-temp-buffer
    (org-mode)
    (org-tickets-test--insert-feature "Feature" "PROJ-1" "BLOCKS" "PROJ-200")
    (org-tickets--ensure-blocks-entry "PROJ-1" "PROJ-20")
    (org-tickets--ensure-blocks-entry "PROJ-1" "PROJ-20")
    (should (equal (org-tickets-test--prop-of "PROJ-1" "BLOCKS")
                   "PROJ-200,PROJ-20"))))

(provide 'org-tickets-test-sync-errors)

;;; org-tickets-test-sync-errors.el ends here
