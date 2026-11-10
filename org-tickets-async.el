;;; org-tickets-async.el --- Async HTTP layer for org-tickets  -*- lexical-binding: t; -*-

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

;; Async HTTP layer for org-tickets.
;; Wraps `url-retrieve' with coordination primitives: rate limiting,
;; batch execution, and modeline progress reporting.

;;; Code:

(require 'url)
(require 'json)
(require 'org-tickets-core)
(require 'org-tickets-api)

(defcustom org-tickets-max-concurrent-requests nil
  "Maximum simultaneous async requests per buffer, or nil for no cap.
Large documents fire one GET+PUT per ticket concurrently; a cap
\(8 is a reasonable value) reduces the chance of Jira 429 throttling."
  :type '(choice (const :tag "Uncapped" nil) integer)
  :group 'org-tickets)

;;;; Rate Limit State

(org-tickets--define-record org-tickets--rate-limit-state
    "Tracks adaptive rate limiting state."
  (throttled-p nil)      ; Non-nil when rate-limited
  (max-concurrent nil)     ; nil = uncapped, number = max simultaneous
  (pending-queue nil)      ; List of deferred thunks
  (in-flight 0))           ; Number of requests currently outstanding

(defvar-local org-tickets--rate-state nil
  "Per-buffer rate limiting state for async requests.
Initialized to a fresh `org-tickets--rate-limit-state' on first use.")

(defun org-tickets--rate-state ()
  "Return the buffer-local rate-limit state, creating it if needed."
  (unless org-tickets--rate-state
    (setq org-tickets--rate-state (org-tickets--rate-limit-state-create)))
  org-tickets--rate-state)

(defun org-tickets--rate-limit-reset ()
  "Reset the rate-limit state for the current buffer."
  (setq org-tickets--rate-state (org-tickets--rate-limit-state-create)))

;;;; Modeline Progress

(defvar-local org-tickets--progress-total 0
  "Total number of async operations for the current sync.")

(defvar-local org-tickets--progress-done 0
  "Number of completed async operations for the current sync.")

(defvar org-tickets--progress-mode-line-entry
  '(:eval (when (> org-tickets--progress-total 0)
            (org-tickets--progress-format)))
  "Mode-line entry rendering per-buffer sync progress.
Installed once globally; each buffer's buffer-local
`org-tickets--progress-total' gates whether it renders.")

(defun org-tickets--progress-format ()
  "Return a formatted modeline string for current progress."
  (format " [org-tickets: %d/%d]"
          org-tickets--progress-done
          org-tickets--progress-total))

(defun org-tickets--progress-install ()
  "Ensure the shared progress entry is on the default mode line."
  (unless (member org-tickets--progress-mode-line-entry
                  (default-value 'mode-line-misc-info))
    (setq-default mode-line-misc-info
                  (cons org-tickets--progress-mode-line-entry
                        (default-value 'mode-line-misc-info)))))

(defun org-tickets--progress-init (total)
  "Initialize progress tracking for TOTAL operations in this buffer."
  (org-tickets--progress-install)
  (setq org-tickets--progress-total total
        org-tickets--progress-done 0)
  (force-mode-line-update))

(defun org-tickets--progress-increment ()
  "Increment the completed operation count and refresh the modeline."
  (setq org-tickets--progress-done (1+ org-tickets--progress-done))
  (force-mode-line-update))

(defun org-tickets--progress-clear ()
  "Stop rendering progress for this buffer.
The shared entry stays installed; zeroing the buffer-local total
hides it here without touching other buffers' indicators."
  (setq org-tickets--progress-total 0
        org-tickets--progress-done 0)
  (force-mode-line-update))

;;;; Rate Limit Helpers

(defun org-tickets--rate-limit-on-429 (retry-after)
  "Throttle the current buffer's state; resume after RETRY-AFTER seconds.
The resume timer re-enters this buffer explicitly — timers run with an
arbitrary buffer current."
  (let ((state (org-tickets--rate-state))
        (buf (current-buffer)))
    (setf (org-tickets--rate-limit-state-throttled-p state) t)
    (setf (org-tickets--rate-limit-state-max-concurrent state) 1)
    (run-at-time retry-after nil
                 (lambda ()
                   (when (buffer-live-p buf)
                     (with-current-buffer buf
                       (org-tickets--rate-limit-resume)))))))

(defun org-tickets--rate-limit-next-max-concurrent (current-max)
  "Return the next max-concurrent value after a successful 429 recovery.
Doubles CURRENT-MAX from 1 up to 8, then returns nil (uncapped)."
  (cond
   ((null current-max) nil)
   ((>= current-max 8) nil)
   (t (* current-max 2))))

(defun org-tickets--rate-limit-resume ()
  "Resume after rate limit window expires.
Clears throttle flag, doubles max-concurrent, drains pending queue."
  (let ((state (org-tickets--rate-state)))
    (setf (org-tickets--rate-limit-state-throttled-p state) nil)
    (setf (org-tickets--rate-limit-state-max-concurrent state)
          (org-tickets--rate-limit-next-max-concurrent
           (org-tickets--rate-limit-state-max-concurrent state))))
  (org-tickets--rate-limit-drain-queue))

(defun org-tickets--rate-limit-effective-max (state)
  "Return the effective concurrency cap for rate-limit STATE.
That is the stricter of the 429-recovery cap and the defcustom."
  (let ((caps (delq nil (list (org-tickets--rate-limit-state-max-concurrent state)
                              org-tickets-max-concurrent-requests))))
    (and caps (apply #'min caps))))

(defun org-tickets--rate-limit-enqueue (state thunk)
  "Append THUNK to the pending queue of rate-limit STATE."
  (setf (org-tickets--rate-limit-state-pending-queue state)
        (append (org-tickets--rate-limit-state-pending-queue state)
                (list thunk))))

(defun org-tickets--rate-limit-at-capacity-p (state)
  "Non-nil when STATE's in-flight count has reached the effective cap."
  (let ((cap (org-tickets--rate-limit-effective-max state)))
    (and cap (>= (org-tickets--rate-limit-state-in-flight state) cap))))

(defun org-tickets--rate-limit-drain-queue ()
  "Fire queued thunks while not throttled and under the concurrency cap."
  (let ((state (org-tickets--rate-state)))
    (while (and (org-tickets--rate-limit-state-pending-queue state)
                (not (org-tickets--rate-limit-state-throttled-p state))
                (not (org-tickets--rate-limit-at-capacity-p state)))
      (funcall (pop (org-tickets--rate-limit-state-pending-queue state))))))

;;;; Internal Request Helpers

(defun org-tickets--async-parse-retry-after (status-text)
  "Extract Retry-After seconds from STATUS-TEXT headers.
Returns a number; defaults to 5 if header is absent or unparseable."
  (if (string-match "Retry-After:[ \t]*\\([0-9]+\\)" status-text)
      (string-to-number (match-string 1 status-text))
    5))

(defun org-tickets--async-handle-429 (status-text thunk)
  "Handle a 429 described by STATUS-TEXT in the current (state) buffer.
Queues THUNK to re-fire after the Retry-After window."
  (org-tickets--rate-limit-on-429 (org-tickets--async-parse-retry-after status-text))
  (org-tickets--rate-limit-enqueue (org-tickets--rate-state) thunk))

(defun org-tickets--async-safe-callback (callback response err)
  "Invoke CALLBACK with RESPONSE and ERR, trapping elisp errors.
An error inside a callback would otherwise unwind into url.el's
process machinery and silently strand the batch pipeline (stuck
read-only buffer, progress frozen).  Errors are logged loudly
instead; recovery is `org-tickets-sync-reset'."
  (condition-case cb-err
      (funcall callback response err)
    (error
     (display-warning
      'org-tickets
      (format "async callback error (sync may need M-x org-tickets-sync-reset): %S"
              cb-err)
      :error))))

(defun org-tickets--async-decrement-in-flight ()
  "Decrement the current buffer's in-flight request counter, floored at 0."
  (let ((state (org-tickets--rate-state)))
    (when (> (org-tickets--rate-limit-state-in-flight state) 0)
      (setf (org-tickets--rate-limit-state-in-flight state)
            (1- (org-tickets--rate-limit-state-in-flight state))))))

(defun org-tickets--async-dispatch-success (parsed callback)
  "Parse the JSON body of a successful PARSED response and invoke CALLBACK.
On a JSON parse error, CALLBACK is invoked once with an error message
instead of the body."
  (condition-case err
      (let ((body (org-tickets--http-parse-json-body (plist-get parsed :body))))
        (org-tickets--async-safe-callback callback body nil))
    (error
     (org-tickets--async-safe-callback
      callback nil (format "JSON parse error: %S" err)))))

(defun org-tickets--async-dispatch-response (parsed callback thunk state-buffer)
  "Dispatch PARSED response plist in STATE-BUFFER.
Rate-limit bookkeeping and CALLBACK both run in the buffer that made
the request, never in url.el's response buffer.  THUNK re-fires the
request on 429.  When STATE-BUFFER has been killed the response is
dropped: running CALLBACK in whatever buffer happens to be current
would corrupt that buffer's rate-limit state and contents."
  (if (not (buffer-live-p state-buffer))
      (when org-tickets-debug
        (message "org-tickets: dropping response for a killed buffer: %s"
                 (plist-get parsed :status)))
    (with-current-buffer state-buffer
      (org-tickets--async-decrement-in-flight)
      ;; `unwind-protect' guarantees the queue is drained on every branch.
      (unwind-protect
          (let ((status (plist-get parsed :status)))
            (cond
             ((string-empty-p status)
              (org-tickets--async-safe-callback
               callback nil "Could not find end of HTTP headers"))
             ((eql (org-tickets--http-status-code status) 429)
              (org-tickets--async-handle-429 status thunk))
             ((org-tickets--http-success-p status)
              (org-tickets--async-dispatch-success parsed callback))
             (t
              (org-tickets--async-safe-callback
               callback nil
               (format "Jira API error: %s\nResponse: %s"
                       status (plist-get parsed :body))))))
        (org-tickets--rate-limit-drain-queue)))))

(defun org-tickets--async-fire-request (method url headers data callback thunk state-buffer)
  "Fire an async METHOD request to URL with HEADERS and DATA.
The response is parsed in url.el's buffer; CALLBACK runs in STATE-BUFFER.
THUNK re-fires the request after a 429."
  (let ((url-request-method method)
        (url-request-extra-headers headers)
        (url-request-data data))
    (url-retrieve url
                  (lambda (_status)
                    (let ((parsed (org-tickets--http-split-response)))
                      (kill-buffer (current-buffer))
                      (org-tickets--async-dispatch-response
                       parsed callback thunk state-buffer)))
                  nil t)))

;;;; Public API

(defun org-tickets--async-request (method endpoint callback &optional data)
  "Make an async HTTP request to Jira.
METHOD is the HTTP method and ENDPOINT the API path.  CALLBACK is
\(lambda (response err) ...) and always runs in the buffer current at
call time.  Optional DATA is the request body, encoded as JSON.  When
that buffer's rate-limit state is throttled, or its concurrency cap is
at capacity, the request is queued instead of fired."
  (org-tickets--async-enqueue method
                              (concat (org-tickets--base-url) endpoint)
                              (org-tickets--async-build-headers)
                              (org-tickets--encode-request-data data)
                              callback))

(defun org-tickets--async-enqueue (method url headers body callback)
  "Send METHOD request to URL with HEADERS and raw BODY under rate limiting.
BODY is a unibyte string or nil.  CALLBACK is (lambda (response err) ...)
with the JSON-parsed RESPONSE, and runs in the buffer current at call
time.  The request is queued while that buffer is throttled or at its
concurrency cap."
  (let ((state-buffer (current-buffer))
        (thunk nil))
    (setq thunk (lambda ()
                  (let ((state (org-tickets--rate-state)))
                    (setf (org-tickets--rate-limit-state-in-flight state)
                          (1+ (org-tickets--rate-limit-state-in-flight state))))
                  (org-tickets--async-fire-request
                   method url headers body callback thunk state-buffer)))
    (let ((state (org-tickets--rate-state)))
      (if (or (org-tickets--rate-limit-state-throttled-p state)
              (org-tickets--rate-limit-at-capacity-p state))
          (org-tickets--rate-limit-enqueue state thunk)
        (funcall thunk)))))

(defun org-tickets--async-batch (thunks final-callback)
  "Fire all THUNKS concurrently and call FINAL-CALLBACK when all complete.
THUNKS is a list of one-arg functions.  Each thunk accepts a single DONE
argument: a callback of the form `(lambda (response err) ...)'.  The thunk
must call DONE once when its async operation completes; any later call
of the same DONE is ignored.

Example thunk:
  (lambda (done)
    (org-tickets--async-request \"GET\" \"/rest/api/3/issue/PROJ-1\" done))

FINAL-CALLBACK is `(lambda (results) ...)' called once every thunk has
completed.  RESULTS is a list of `(response . err)' cons cells in the same
order as THUNKS.  Thunks are fired immediately with no artificial concurrency
limit."
  (let ((total (length thunks)))
    (if (= total 0)
        (funcall final-callback nil)
      (let ((results (make-vector total nil))
            (counter (list 0))   ; mutable counter via cons cell
            (idx 0))
        (dolist (thunk thunks)
          (funcall thunk (org-tickets--async-batch-done
                          results idx counter final-callback))
          (setq idx (1+ idx)))))))

(defun org-tickets--async-batch-done (results index counter final-callback)
  "Return the DONE callback for thunk INDEX of an `org-tickets--async-batch'.
It stores (RESPONSE . ERR) at INDEX of the RESULTS vector and bumps
COUNTER, a one-element list; the last thunk to finish calls
FINAL-CALLBACK with RESULTS as a list.  Calls after the first are
ignored, so a thunk calling DONE twice cannot finish the batch early."
  (let ((called nil))
    (lambda (response err)
      (unless called
        (setq called t)
        (aset results index (cons response err))
        (setcar counter (1+ (car counter)))
        (when (= (car counter) (length results))
          (funcall final-callback (append results nil)))))))

(provide 'org-tickets-async)

;;; org-tickets-async.el ends here
