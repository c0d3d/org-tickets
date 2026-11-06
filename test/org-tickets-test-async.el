;;; org-tickets-test-async.el --- Tests for org-tickets async HTTP layer  -*- lexical-binding: t; -*-

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

;; Tests for the async HTTP layer in org-tickets-async.el.
;; Covers: async-request dispatch, error handling, 429 rate limiting,
;; batch coordination, modeline progress, and encoding.

;;; Code:

(require 'ert)

(require 'org-tickets)
(require 'org-tickets-async)
(require 'org-tickets-test-fixtures)

;;;; Helpers

(defmacro org-tickets-test--with-mock-url-retrieve (response-text &rest body)
  "Execute BODY with `url-retrieve' mocked to respond synchronously.
RESPONSE-TEXT is the full HTTP response string (headers + body).
The mock calls the callback immediately in a temp buffer containing RESPONSE-TEXT."
  (declare (indent 1))
  `(org-tickets-test--with-stubs ((url-retrieve
                                (lambda (_url callback &optional _cbargs _silent _inhibit-cookies)
                                  (with-temp-buffer
                                    (insert ,response-text)
                                    (funcall callback nil)))))
     ,@body))

(defmacro org-tickets-test--with-async-stubs (&rest body)
  "Execute BODY with config and credential stubs in place.
Stubs out `org-tickets--resolve-config', `org-tickets--async-build-headers',
and sets `org-tickets--jira-base-url' so `org-tickets--async-request' can run."
  (declare (indent 0))
  `(org-tickets-test--with-stubs ((org-tickets--resolve-config #'ignore)
                               (org-tickets--async-build-headers
                                (lambda () (list (cons "Content-Type" "application/json"))))
                               (run-at-time #'ignore)
                               (force-mode-line-update #'ignore))
     (let ((org-tickets--jira-base-url "https://test.atlassian.net"))
       ,@body)))

;;;; Tests: org-tickets--async-request

(ert-deftest org-tickets-test--async-request-success-parses-json ()
  "Verify callback receives parsed JSON on a 200 response.
The JSON parser returns symbol keys by default, so use assq or symbol assoc."
  (org-tickets-test--with-async-stubs
    (org-tickets-test--with-mock-url-retrieve
        "HTTP/1.1 200 OK\nContent-Type: application/json\n\n{\"key\":\"PROJ-123\"}"
      (with-temp-buffer
        (org-tickets--rate-limit-reset)
        (let (got-response got-err)
          (org-tickets--async-request
           "GET" "/rest/api/3/issue/PROJ-123"
           (lambda (response err)
             (setq got-response response
                   got-err err)))
          (should (null got-err))
          (should got-response)
          ;; json-read-from-string returns symbol keys by default
          (should (string= (cdr (assq 'key got-response)) "PROJ-123")))))))

(ert-deftest org-tickets-test--async-request-error-response-passes-error-string ()
  "Verify callback receives nil response and an error string on a non-2xx response."
  (org-tickets-test--with-async-stubs
    (org-tickets-test--with-mock-url-retrieve
        "HTTP/1.1 500 Internal Server Error\nContent-Type: application/json\n\n{\"errorMessages\":[\"Something went wrong\"]}"
      (with-temp-buffer
        (org-tickets--rate-limit-reset)
        (let (got-response got-err)
          (org-tickets--async-request
           "GET" "/rest/api/3/issue/PROJ-123"
           (lambda (response err)
             (setq got-response response
                   got-err err)))
          (should (null got-response))
          (should got-err)
          (should (stringp got-err))
          (should (string-match-p "Jira API error" got-err)))))))

(ert-deftest org-tickets-test--async-request-empty-body-passes-nil-nil ()
  "Verify callback receives nil response and nil error on a 204 No Content response."
  (org-tickets-test--with-async-stubs
    (org-tickets-test--with-mock-url-retrieve
        "HTTP/1.1 204 No Content\n\n"
      (with-temp-buffer
        (org-tickets--rate-limit-reset)
        (let (called got-response got-err)
          (org-tickets--async-request
           "DELETE" "/rest/api/3/issue/PROJ-123"
           (lambda (response err)
             (setq called t
                   got-response response
                   got-err err)))
          (should called)
          (should (null got-response))
          (should (null got-err)))))))

(ert-deftest org-tickets-test--async-request-success-malformed-json-passes-error ()
  "A 2xx response with an unparseable body invokes the callback once with
a \"JSON parse error\" string and a nil response, rather than signalling."
  (org-tickets-test--with-async-stubs
    (org-tickets-test--with-mock-url-retrieve
        "HTTP/1.1 200 OK\nContent-Type: application/json\n\n{not valid json"
      (with-temp-buffer
        (org-tickets--rate-limit-reset)
        (let ((call-count 0) got-response got-err)
          (org-tickets--async-request
           "GET" "/rest/api/3/issue/PROJ-123"
           (lambda (response err)
             (setq call-count (1+ call-count))
             (setq got-response response
                   got-err err)))
          (should (= call-count 1))
          (should (null got-response))
          (should (stringp got-err))
          (should (string-match-p "JSON parse error" got-err)))))))

(ert-deftest org-tickets-test--async-request-429-requeues-thunk ()
  "Verify a 429 response sets throttled state and re-queues the thunk.

`url-retrieve' calls the callback in url.el's response buffer, but
rate-limit state must land in the buffer that made the request (the
state buffer captured by `org-tickets--async-request'), never in the
dead response buffer."
  (with-temp-buffer
    (org-tickets--rate-limit-reset)
    (let ((state-buffer (current-buffer)))
      (org-tickets-test--with-async-stubs
        (org-tickets-test--with-stubs ((url-retrieve
                                     (lambda (_url callback &optional _cbargs _silent _inhibit)
                                       ;; Simulate url-retrieve: callback runs in a fresh
                                       ;; response buffer, distinct from the state buffer.
                                       (with-temp-buffer
                                         (insert "HTTP/1.1 429 Too Many Requests\nRetry-After: 3\n\n")
                                         (funcall callback nil)))))
          (let ((org-tickets--jira-base-url "https://test.atlassian.net"))
            (org-tickets--async-request
             "GET" "/rest/api/3/issue/PROJ-123"
             #'ignore))))
      (with-current-buffer state-buffer
        (let ((state (org-tickets--rate-state)))
          ;; After 429: throttled-p should be set
          (should (org-tickets--rate-limit-state-throttled-p state))
          ;; The request thunk should have been re-queued
          (should (= 1 (length (org-tickets--rate-limit-state-pending-queue state))))
          ;; max-concurrent should be 1 during throttle
          (should (= 1 (org-tickets--rate-limit-state-max-concurrent state))))))))

(ert-deftest org-tickets-test--async-request-encoding-utf8 ()
  "Verify JSON request body is UTF-8 encoded for non-ASCII data."
  (let ((captured-data nil))
    (org-tickets-test--with-async-stubs
      (org-tickets-test--with-stubs ((url-retrieve
                                   (lambda (_url _callback &optional _cbargs _silent _inhibit-cookies)
                                     (setq captured-data url-request-data))))
        (with-temp-buffer
          (org-tickets--rate-limit-reset)
          (org-tickets--async-request
           "POST" "/rest/api/3/issue"
           #'ignore
           (list (cons "summary" "Café résumé — español")))
          (should captured-data)
          ;; The encoded bytes should be longer than the raw Elisp string
          ;; because multi-byte chars get expanded to multiple UTF-8 bytes
          (should (> (length captured-data) 10))
          ;; The content should decode back to valid UTF-8 containing the original text
          (let ((decoded (decode-coding-string captured-data 'utf-8)))
            (should (string-match-p "Caf" decoded))
            (should (string-match-p "summary" decoded))))))))

;;;; Tests: org-tickets--async-batch

(ert-deftest org-tickets-test--async-batch-fires-all-callbacks ()
  "Verify final-callback fires with all results after all thunks complete."
  (let (final-results)
    (org-tickets--async-batch
     (list
      (lambda (done) (funcall done '((a . 1)) nil))
      (lambda (done) (funcall done '((b . 2)) nil))
      (lambda (done) (funcall done '((c . 3)) nil)))
     (lambda (results) (setq final-results results)))
    (should final-results)
    (should (= 3 (length final-results)))
    (should (equal (car (nth 0 final-results)) '((a . 1))))
    (should (equal (car (nth 1 final-results)) '((b . 2))))
    (should (equal (car (nth 2 final-results)) '((c . 3))))))

(ert-deftest org-tickets-test--async-batch-empty-thunks-calls-final-immediately ()
  "Verify final-callback is called immediately with nil when thunks list is empty."
  (let (final-called final-results sentinel)
    (setq sentinel t)
    (org-tickets--async-batch
     nil
     (lambda (results)
       (setq final-called t
             final-results results)))
    (should final-called)
    (should (null final-results))))

(ert-deftest org-tickets-test--async-batch-results-in-order ()
  "Verify results list preserves thunk order even if callbacks fire out of order.
Uses deferred callbacks to simulate out-of-order completion."
  (let (final-results
        cb-0 cb-1 cb-2)
    ;; Capture callbacks without firing them immediately
    (org-tickets--async-batch
     (list
      (lambda (done) (setq cb-0 done))
      (lambda (done) (setq cb-1 done))
      (lambda (done) (setq cb-2 done)))
     (lambda (results) (setq final-results results)))
    ;; Fire out of order: 2, 0, 1
    (funcall cb-2 '((z . 3)) nil)
    (should (null final-results))          ; not done yet
    (funcall cb-0 '((x . 1)) nil)
    (should (null final-results))          ; still not done
    (funcall cb-1 '((y . 2)) nil)
    ;; Now all done
    (should final-results)
    (should (= 3 (length final-results)))
    ;; Order must match original thunk order (0, 1, 2)
    (should (equal (car (nth 0 final-results)) '((x . 1))))
    (should (equal (car (nth 1 final-results)) '((y . 2))))
    (should (equal (car (nth 2 final-results)) '((z . 3))))))

(ert-deftest org-tickets-test--async-batch-propagates-errors ()
  "Verify error values are preserved in results alongside successful ones."
  (let (final-results)
    (org-tickets--async-batch
     (list
      (lambda (done) (funcall done '((key . "PROJ-1")) nil))
      (lambda (done) (funcall done nil "API error: 404")))
     (lambda (results) (setq final-results results)))
    (should (= 2 (length final-results)))
    (should (equal (car (nth 0 final-results)) '((key . "PROJ-1"))))
    (should (null (car (nth 1 final-results))))
    (should (string= (cdr (nth 1 final-results)) "API error: 404"))))

;;;; Tests: Rate Limit Helpers

(ert-deftest org-tickets-test--rate-limit-on-429-sets-state ()
  "Verify org-tickets--rate-limit-on-429 sets throttled-p and max-concurrent."
  (org-tickets-test--with-stubs ((run-at-time #'ignore))
    (with-temp-buffer
      (org-tickets--rate-limit-reset)
      (org-tickets--rate-limit-on-429 5)
      (let ((state (org-tickets--rate-state)))
        (should (org-tickets--rate-limit-state-throttled-p state))
        (should (= 1 (org-tickets--rate-limit-state-max-concurrent state)))))))

(ert-deftest org-tickets-test--rate-limit-resume-clears-throttle ()
  "Verify org-tickets--rate-limit-resume clears throttled-p."
  (org-tickets-test--with-stubs ((run-at-time #'ignore))
    (with-temp-buffer
      (org-tickets--rate-limit-reset)
      ;; First set throttled state with max-concurrent = 1
      (org-tickets--rate-limit-on-429 5)
      (should (org-tickets--rate-limit-state-throttled-p (org-tickets--rate-state)))
      ;; Now resume
      (org-tickets--rate-limit-resume)
      (let ((state (org-tickets--rate-state)))
        (should (null (org-tickets--rate-limit-state-throttled-p state)))))))

(ert-deftest org-tickets-test--rate-limit-resume-doubles-max-concurrent ()
  "Verify org-tickets--rate-limit-resume doubles max-concurrent: 1->2->4->8->nil."
  (org-tickets-test--with-stubs ((run-at-time #'ignore))
    (with-temp-buffer
      (org-tickets--rate-limit-reset)
      ;; Set up throttled state at max-concurrent = 1
      (org-tickets--rate-limit-on-429 5)
      (should (= 1 (org-tickets--rate-limit-state-max-concurrent (org-tickets--rate-state))))
      ;; Resume once: 1 -> 2
      (org-tickets--rate-limit-resume)
      (should (= 2 (org-tickets--rate-limit-state-max-concurrent (org-tickets--rate-state))))
      ;; Manually set to 2, resume: 2 -> 4
      (setf (org-tickets--rate-limit-state-max-concurrent (org-tickets--rate-state)) 2)
      (org-tickets--rate-limit-resume)
      (should (= 4 (org-tickets--rate-limit-state-max-concurrent (org-tickets--rate-state))))
      ;; 4 -> 8
      (setf (org-tickets--rate-limit-state-max-concurrent (org-tickets--rate-state)) 4)
      (org-tickets--rate-limit-resume)
      (should (= 8 (org-tickets--rate-limit-state-max-concurrent (org-tickets--rate-state))))
      ;; 8 -> nil (uncapped)
      (setf (org-tickets--rate-limit-state-max-concurrent (org-tickets--rate-state)) 8)
      (org-tickets--rate-limit-resume)
      (should (null (org-tickets--rate-limit-state-max-concurrent (org-tickets--rate-state)))))))

(ert-deftest org-tickets-test--rate-limit-next-max-concurrent-progression ()
  "Verify org-tickets--rate-limit-next-max-concurrent doubles 1->2->4->8->nil."
  (should (= 2 (org-tickets--rate-limit-next-max-concurrent 1)))
  (should (= 4 (org-tickets--rate-limit-next-max-concurrent 2)))
  (should (= 8 (org-tickets--rate-limit-next-max-concurrent 4)))
  (should (null (org-tickets--rate-limit-next-max-concurrent 8)))
  (should (null (org-tickets--rate-limit-next-max-concurrent nil))))

(ert-deftest org-tickets-test--rate-limit-drain-queue-respects-max-concurrent ()
  "Verify org-tickets--rate-limit-drain-queue fires at most max-concurrent thunks.
Capacity is tracked via the real `in-flight' counter, so each queued
thunk must bump it itself, exactly as `org-tickets--async-request''s
production thunk does."
  (with-temp-buffer
    (org-tickets--rate-limit-reset)
    (let ((fired-count 0)
          (state (org-tickets--rate-state)))
      ;; Queue 5 thunks that each mark themselves in-flight, like a real request thunk.
      (dotimes (_ 5)
        (setf (org-tickets--rate-limit-state-pending-queue state)
              (append (org-tickets--rate-limit-state-pending-queue state)
                      (list (lambda ()
                              (setq fired-count (1+ fired-count))
                              (setf (org-tickets--rate-limit-state-in-flight state)
                                    (1+ (org-tickets--rate-limit-state-in-flight
                                         state))))))))
      ;; Set max-concurrent to 2
      (setf (org-tickets--rate-limit-state-max-concurrent state) 2)
      (org-tickets--rate-limit-drain-queue)
      ;; Only 2 should have fired before hitting the cap
      (should (= 2 fired-count))
      ;; 3 should remain in the queue
      (should (= 3 (length (org-tickets--rate-limit-state-pending-queue state)))))))

(ert-deftest org-tickets-test--rate-limit-drain-queue-no-cap-fires-all ()
  "Verify org-tickets--rate-limit-drain-queue fires all thunks when max-concurrent is nil."
  (with-temp-buffer
    (org-tickets--rate-limit-reset)
    (let ((fired-count 0)
          (state (org-tickets--rate-state)))
      ;; Queue 5 thunks
      (dotimes (_ 5)
        (setf (org-tickets--rate-limit-state-pending-queue state)
              (append (org-tickets--rate-limit-state-pending-queue state)
                      (list (lambda () (setq fired-count (1+ fired-count)))))))
      ;; max-concurrent is nil (uncapped)
      (setf (org-tickets--rate-limit-state-max-concurrent state) nil)
      (org-tickets--rate-limit-drain-queue)
      ;; All 5 should have fired
      (should (= 5 fired-count))
      (should (null (org-tickets--rate-limit-state-pending-queue state))))))

(ert-deftest org-tickets-test--rate-limit-reset-clears-all-state ()
  "Verify org-tickets--rate-limit-reset returns state to fresh values."
  (org-tickets-test--with-stubs ((run-at-time #'ignore))
    (with-temp-buffer
      (org-tickets--rate-limit-reset)
      ;; Dirty the state
      (org-tickets--rate-limit-on-429 10)
      (setf (org-tickets--rate-limit-state-pending-queue (org-tickets--rate-state))
            (list #'ignore #'ignore))
      ;; Reset
      (org-tickets--rate-limit-reset)
      (let ((state (org-tickets--rate-state)))
        (should (null (org-tickets--rate-limit-state-throttled-p state)))
        (should (null (org-tickets--rate-limit-state-max-concurrent state)))
        (should (null (org-tickets--rate-limit-state-pending-queue state)))))))

;;;; Tests: Modeline Progress

(defun org-tickets-test--progress-render ()
  "Evaluate the shared progress entry's `:eval' form in the current buffer.
`format-mode-line' always returns \"\" under `emacs --batch' (no live
window/display), regardless of content, so tests must evaluate the
entry's own `:eval' form directly to observe its rendering logic."
  (eval (cadr org-tickets--progress-mode-line-entry) t))

(ert-deftest org-tickets-test--progress-init-sets-total ()
  "Verify org-tickets--progress-init sets total and resets done to zero."
  (org-tickets-test--with-stubs ((force-mode-line-update #'ignore))
    (with-temp-buffer
      (org-tickets--progress-init 42)
      (should (= 42 org-tickets--progress-total))
      (should (= 0 org-tickets--progress-done)))))

(ert-deftest org-tickets-test--progress-init-adds-to-mode-line ()
  "Verify org-tickets--progress-init installs the shared entry on the
default mode line and that it renders this buffer's progress."
  (org-tickets-test--with-stubs ((force-mode-line-update #'ignore))
    (with-temp-buffer
      (org-tickets--progress-init 10)
      (should (member org-tickets--progress-mode-line-entry
                      (default-value 'mode-line-misc-info)))
      (should (equal (org-tickets-test--progress-render) " [org-tickets: 0/10]")))))

(ert-deftest org-tickets-test--progress-init-replaces-stale-entry ()
  "Verify org-tickets--progress-init does not accumulate duplicate entries
in the default mode-line-misc-info.  Calling it multiple times must
keep exactly one org-tickets progress entry, not grow the list."
  (org-tickets-test--with-stubs ((force-mode-line-update #'ignore))
    (with-temp-buffer
      (org-tickets--progress-init 5)
      (let ((count-after-first
             (seq-count (lambda (entry)
                          (equal entry org-tickets--progress-mode-line-entry))
                        (default-value 'mode-line-misc-info))))
        (should (= 1 count-after-first))
        ;; Call init again with different total
        (org-tickets--progress-init 10)
        ;; Count must not have grown — no duplicate was added
        (should (= count-after-first
                   (seq-count (lambda (entry)
                                (equal entry org-tickets--progress-mode-line-entry))
                              (default-value 'mode-line-misc-info))))
        ;; Total should reflect the latest call
        (should (= 10 org-tickets--progress-total))))))

(ert-deftest org-tickets-test--progress-increment-bumps-done ()
  "Verify org-tickets--progress-increment increases done count by one."
  (org-tickets-test--with-stubs ((force-mode-line-update #'ignore))
    (with-temp-buffer
      (org-tickets--progress-init 5)
      (should (= 0 org-tickets--progress-done))
      (org-tickets--progress-increment)
      (should (= 1 org-tickets--progress-done))
      (org-tickets--progress-increment)
      (should (= 2 org-tickets--progress-done)))))

(ert-deftest org-tickets-test--progress-clear-hides-without-uninstalling ()
  "Verify org-tickets--progress-clear stops this buffer's rendering but
leaves the shared entry installed on the default mode line."
  (org-tickets-test--with-stubs ((force-mode-line-update #'ignore))
    (with-temp-buffer
      (org-tickets--progress-init 5)
      (org-tickets--progress-clear)
      (should (member org-tickets--progress-mode-line-entry
                      (default-value 'mode-line-misc-info)))
      (should (null (org-tickets-test--progress-render)))
      (should (= 0 org-tickets--progress-total))
      (should (= 0 org-tickets--progress-done)))))

(ert-deftest org-tickets-test--progress-concurrent-buffers-do-not-clobber ()
  "Buffer B's progress-clear must not remove buffer A's indicator."
  (let ((buf-a (generate-new-buffer "a")) (buf-b (generate-new-buffer "b")))
    (unwind-protect
        (progn
          (with-current-buffer buf-a (org-tickets--progress-init 5))
          (with-current-buffer buf-b
            (org-tickets--progress-init 3)
            (org-tickets--progress-clear))
          ;; A's modeline still renders its progress.
          (with-current-buffer buf-a
            (should (member org-tickets--progress-mode-line-entry
                            (default-value 'mode-line-misc-info)))
            (should (equal (org-tickets-test--progress-render) " [org-tickets: 0/5]")))
          ;; B renders nothing (its total is 0 again).
          (with-current-buffer buf-b
            (should (null (org-tickets-test--progress-render)))))
      (kill-buffer buf-a) (kill-buffer buf-b))))

(ert-deftest org-tickets-test--progress-format-returns-string ()
  "Verify org-tickets--progress-format returns a correctly formatted string."
  (org-tickets-test--with-stubs ((force-mode-line-update #'ignore))
    (with-temp-buffer
      (org-tickets--progress-init 10)
      (org-tickets--progress-increment)
      (org-tickets--progress-increment)
      (org-tickets--progress-increment)
      (let ((fmt (org-tickets--progress-format)))
        (should (stringp fmt))
        (should (string-match-p "3" fmt))
        (should (string-match-p "10" fmt))
        (should (string-match-p "org-tickets" fmt))))))

;;;; Tests: Buffer-local sync-in-progress

(ert-deftest org-tickets-test--sync-in-progress-is-buffer-local ()
  "Verify org-tickets--sync-in-progress is buffer-local and independent per buffer."
  (let (buf-a buf-b)
    (unwind-protect
        (progn
          (setq buf-a (get-buffer-create " *org-tickets-test-buf-a*"))
          (setq buf-b (get-buffer-create " *org-tickets-test-buf-b*"))
          (with-current-buffer buf-a
            (setq org-tickets--sync-in-progress t))
          (with-current-buffer buf-b
            (setq org-tickets--sync-in-progress nil))
          (should (buffer-local-value 'org-tickets--sync-in-progress buf-a))
          (should (null (buffer-local-value 'org-tickets--sync-in-progress buf-b))))
      (when (buffer-live-p buf-a) (kill-buffer buf-a))
      (when (buffer-live-p buf-b) (kill-buffer buf-b)))))

;;;; Tests: Encoding

(ert-deftest org-tickets-test--encoding-non-ascii-json-round-trip ()
  "Verify JSON body round-trips non-ASCII (accented chars, emoji) through encode/decode."
  (let* ((data (list (cons "summary" "Café résumé — español")
                     (cons "emoji" "Hello 🌍")))
         (json-str (json-encode data))
         (encoded (encode-coding-string json-str 'utf-8))
         (decoded (decode-coding-string encoded 'utf-8)))
    ;; The JSON string should contain the original text
    (should (string-match-p "Café" json-str))
    (should (string-match-p "résumé" json-str))
    (should (string-match-p "español" json-str))
    ;; UTF-8 encoding should produce more bytes than the Elisp character count
    (should (> (length encoded) (length json-str)))
    ;; Round-trip through encode + decode must preserve content
    (should (string= json-str decoded))
    ;; The decoded string must parse back as valid JSON.
    ;; json-read-from-string returns symbol keys by default; use assq.
    (let* ((json-object-type 'alist)
           (parsed (json-read-from-string decoded)))
      (should parsed)
      (should (string-match-p "Café" (cdr (assq 'summary parsed)))))))

(ert-deftest org-tickets-test--encoding-emoji-survives-utf8 ()
  "Verify emoji characters survive UTF-8 encode/decode round-trip."
  (let* ((text "🎉 party 🚀 rocket 🌍 earth")
         (json-str (json-encode (list (cons "text" text))))
         (encoded (encode-coding-string json-str 'utf-8))
         (decoded (decode-coding-string encoded 'utf-8)))
    (should (string= json-str decoded))
    (let* ((json-object-type 'alist)
           (parsed (json-read-from-string decoded)))
      (should parsed))))

(ert-deftest org-tickets-test--async-parse-retry-after-reads-header ()
  "Verify org-tickets--async-parse-retry-after extracts Retry-After value."
  (should (= 3 (org-tickets--async-parse-retry-after "HTTP/1.1 429 Too Many Requests\nRetry-After: 3\n")))
  (should (= 60 (org-tickets--async-parse-retry-after "HTTP/1.1 429\nRetry-After: 60\n"))))

(ert-deftest org-tickets-test--async-parse-retry-after-defaults-to-5 ()
  "Verify org-tickets--async-parse-retry-after defaults to 5 when header is absent."
  (should (= 5 (org-tickets--async-parse-retry-after "HTTP/1.1 429 Too Many Requests\n"))))

;;;; Tests: Shared HTTP response core

(ert-deftest org-tickets-test--http-split-response-basic ()
  (with-temp-buffer
    (insert "HTTP/1.1 200 OK\nContent-Type: application/json\n\n{\"a\": 1}")
    (let ((parsed (org-tickets--http-split-response)))
      (should (string-match-p "200 OK" (plist-get parsed :status)))
      (should (equal (string-trim (plist-get parsed :body)) "{\"a\": 1}")))))

(ert-deftest org-tickets-test--http-parse-json-body-shapes ()
  (should (null (org-tickets--http-parse-json-body "")))
  (should (null (org-tickets--http-parse-json-body "  \n ")))
  (let ((parsed (org-tickets--http-parse-json-body "{\"key\": \"P-1\", \"ok\": false}")))
    (should (equal (cdr (assq 'key parsed)) "P-1"))
    (should (eq (cdr (assq 'ok parsed)) :json-false))))

(ert-deftest org-tickets-test--api-request-kills-response-buffer-and-tolerates-percent ()
  "The sync path must kill its response buffer and never treat the URL
as a format string (URLs with %20 crashed `message')."
  (let ((org-tickets--jira-base-url "https://test.example")
        (org-tickets--api-user "u") (org-tickets--api-token "t")
        (made-buffer nil))
    (org-tickets-test--with-stubs ((url-retrieve-synchronously
                                 (lambda (_url &rest _)
                                   (setq made-buffer (generate-new-buffer " test-http"))
                                   (with-current-buffer made-buffer
                                     (insert "HTTP/1.1 200 OK\n\n{\"ok\": true}"))
                                   made-buffer)))
      (let ((response (org-tickets--api-request "GET" "/rest/api/3/search?jql=a%20b")))
        (should (eq (cdr (assq 'ok response)) t))
        (should-not (buffer-live-p made-buffer))))))

(ert-deftest org-tickets-test--api-request-nil-buffer-is-clear-error ()
  (let ((org-tickets--jira-base-url "https://test.example")
        (org-tickets--api-user "u") (org-tickets--api-token "t"))
    (org-tickets-test--with-stubs ((url-retrieve-synchronously
                                 (lambda (&rest _) nil)))
      (should-error (org-tickets--api-request "GET" "/x")))))

;;;; Tests: Callbacks and rate-limit state run in the requesting buffer

(ert-deftest org-tickets-test--async-callback-runs-in-requesting-buffer ()
  "Success callbacks must run in the buffer that made the request,
not in url.el's response buffer."
  (with-temp-buffer
    (org-tickets--rate-limit-reset)
    (let ((org-buffer (current-buffer))
          (org-tickets--jira-base-url "https://test.example")
          (org-tickets--api-user "u") (org-tickets--api-token "t")
          (captured-cb nil) (got-buffer nil) (got-response nil))
      (org-tickets-test--with-stubs ((url-retrieve
                                   (lambda (_url cb &rest _) (setq captured-cb cb) nil)))
        (org-tickets--async-request
         "GET" "/x"
         (lambda (resp _err)
           (setq got-buffer (current-buffer) got-response resp)))
        (should captured-cb)
        (with-temp-buffer          ; simulate url.el's response buffer
          (insert "HTTP/1.1 200 OK\n\n{\"a\": 1}")
          (funcall captured-cb nil))
        (should (eq got-buffer org-buffer))
        (should (equal (cdr (assq 'a got-response)) 1))))))

(ert-deftest org-tickets-test--async-429-state-lands-in-requesting-buffer ()
  "A 429 must throttle and queue in the requesting buffer's state,
and the retry timer must drain that same buffer's queue."
  (with-temp-buffer
    (org-tickets--rate-limit-reset)
    (let ((org-buffer (current-buffer))
          (org-tickets--jira-base-url "https://test.example")
          (org-tickets--api-user "u") (org-tickets--api-token "t")
          (captured-cb nil) (timer-fn nil) (fired 0))
      (org-tickets-test--with-stubs ((url-retrieve
                                   (lambda (_url cb &rest _)
                                     (setq fired (1+ fired)) (setq captured-cb cb) nil))
                                  (run-at-time
                                   (lambda (_secs _repeat fn &rest _) (setq timer-fn fn) nil)))
        (org-tickets--async-request "GET" "/x" #'ignore)
        (should (= fired 1))
        (with-temp-buffer
          (insert "HTTP/1.1 429 Too Many Requests\nRetry-After: 3\n\n")
          (funcall captured-cb nil))
        ;; State is in ORG-BUFFER (the old code stored it in the dead
        ;; response buffer, losing the queued retry forever).
        (with-current-buffer org-buffer
          (let ((state (org-tickets--rate-state)))
            (should (org-tickets--rate-limit-state-throttled-p state))
            (should (= 1 (length (org-tickets--rate-limit-state-pending-queue state))))))
        (should timer-fn)
        ;; Timer fires with some unrelated buffer current — must still
        ;; resume ORG-BUFFER's queue.
        (with-temp-buffer (funcall timer-fn))
        (should (= fired 2))
        (with-current-buffer org-buffer
          (let ((state (org-tickets--rate-state)))
            (should-not (org-tickets--rate-limit-state-throttled-p state))
            (should (null (org-tickets--rate-limit-state-pending-queue state)))))))))

;;;; Tests: Error boundary around async callbacks

(ert-deftest org-tickets-test--async-callback-errors-are-trapped-and-logged ()
  "One buggy callback must not silently kill the whole pipeline."
  (let ((warned nil))
    (org-tickets-test--with-stubs ((display-warning
                                 (lambda (_type message &rest _) (setq warned message))))
      ;; Must not signal:
      (org-tickets--async-safe-callback
       (lambda (_r _e) (error "boom")) nil nil)
      (should warned)
      (should (string-match-p "boom" warned)))))

;;;; Tests: Issue type fetch/save

(ert-deftest org-tickets-test--save-issue-types-preserves-kill-ring ()
  "Saving issue types must not push the old line onto the kill ring."
  (with-temp-buffer
    (org-mode)
    (insert "#+JIRA_ISSUE_TYPES: Story=1\nbody\n")
    (let ((org-tickets--issue-type-ids '(("Story" . "2")))
          (kill-ring nil))
      (org-tickets--save-issue-types-to-document)
      (should (null kill-ring))
      (should (string-match-p "^#\\+JIRA_ISSUE_TYPES: Story=2$" (buffer-string)))
      ;; No blank line accumulation on repeated saves.
      (org-tickets--save-issue-types-to-document)
      (should-not (string-match-p "\n\n\n" (buffer-string))))))

(ert-deftest org-tickets-test--fetch-issue-types-parses-realistic-response ()
  (with-temp-buffer
    (org-mode)
    (let ((org-tickets--issue-type-ids nil)
          (org-tickets--project-key "TEST"))
      (org-tickets-test--with-stubs ((org-tickets--api-request
                                   (lambda (&rest _)
                                     (org-tickets-test--json
                                      "{\"projects\": [{\"issuetypes\": [
                        {\"name\": \"Story\", \"id\": \"10001\"},
                        {\"name\": \"New Feature\", \"id\": \"10002\"}]}]}"))))
        (org-tickets--fetch-issue-types)
        (should (equal org-tickets--issue-type-ids
                       '(("Story" . "10001") ("New Feature" . "10002"))))))))

;;;; Tests: Concurrency cap

(ert-deftest org-tickets-test--async-respects-concurrency-cap ()
  "With a cap of 2, the third request queues until one completes."
  (with-temp-buffer
    (org-tickets--rate-limit-reset)
    (let ((org-tickets-max-concurrent-requests 2)
          (org-tickets--jira-base-url "https://test.example")
          (org-tickets--api-user "u") (org-tickets--api-token "t")
          (callbacks nil))
      (org-tickets-test--with-stubs ((url-retrieve
                                   (lambda (_url cb &rest _) (push cb callbacks) nil)))
        (dotimes (_ 3)
          (org-tickets--async-request "GET" "/x" #'ignore))
        (should (= (length callbacks) 2))   ; third is queued
        ;; Complete one request -> queued one fires.
        (let ((cb (pop callbacks)))
          (with-temp-buffer
            (insert "HTTP/1.1 200 OK\n\n{}")
            (funcall cb nil)))
        (should (= (length callbacks) 2))))))

(provide 'org-tickets-test-async)
;;; org-tickets-test-async.el ends here
