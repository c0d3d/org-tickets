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
;; batch coordination, modeline progress, and request encoding.

;;; Code:

(require 'ert)

(require 'org-tickets)
(require 'org-tickets-async)
(require 'org-tickets-test-fixtures)

;;;; Tests: org-tickets--async-request

(ert-deftest org-tickets-test--async-request-success-parses-json ()
  "Verify callback receives parsed JSON on a 200 response.
The JSON parser returns symbol keys by default, so use assq or symbol assoc."
  (org-tickets-test--with-url-responses
      (list "HTTP/1.1 200 OK\nContent-Type: application/json\n\n{\"key\":\"PROJ-123\"}")
      nil
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
        (should (string= (cdr (assq 'key got-response)) "PROJ-123"))))))

(ert-deftest org-tickets-test--async-request-error-response-passes-error-string ()
  "Verify callback receives nil response and an error string on a non-2xx response."
  (org-tickets-test--with-url-responses
      (list "HTTP/1.1 500 Internal Server Error\nContent-Type: application/json\n\n{\"errorMessages\":[\"Something went wrong\"]}")
      nil
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
        (should (string-match-p "Jira API error" got-err))))))

(ert-deftest org-tickets-test--async-request-empty-body-passes-nil-nil ()
  "Verify callback receives nil response and nil error on a 204 No Content response."
  (org-tickets-test--with-url-responses
      (list "HTTP/1.1 204 No Content\n\n")
      nil
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
        (should (null got-err))))))

(ert-deftest org-tickets-test--async-request-success-malformed-json-passes-error ()
  "A 2xx response with an unparseable body invokes the callback once with
a \"JSON parse error\" string and a nil response, rather than signalling."
  (org-tickets-test--with-url-responses
      (list "HTTP/1.1 200 OK\nContent-Type: application/json\n\n{not valid json")
      nil
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
        (should (string-match-p "JSON parse error" got-err))))))

(ert-deftest org-tickets-test--async-request-encoding-utf8 ()
  "The request body is unibyte UTF-8 that decodes back to the original text."
  (let ((calls nil))
    (org-tickets-test--with-url-responses :deferred calls
      (with-temp-buffer
        (org-tickets--rate-limit-reset)
        (org-tickets--async-request
         "POST" "/rest/api/3/issue"
         #'ignore
         (list (cons 'summary "Caf\u00e9 r\u00e9sum\u00e9 \u2014 espa\u00f1ol")))))
    (let ((data (plist-get (car calls) :data)))
      (should data)
      (should-not (multibyte-string-p data))
      (should (equal (cdr (assq 'summary
                                (json-read-from-string
                                 (decode-coding-string data 'utf-8))))
                     "Caf\u00e9 r\u00e9sum\u00e9 \u2014 espa\u00f1ol")))))

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
  "Each resume doubles max-concurrent: 1->2->4->8->nil, and nil stays nil."
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
      (should (null (org-tickets--rate-limit-state-max-concurrent (org-tickets--rate-state))))
      (org-tickets--rate-limit-resume)
      (should (null (org-tickets--rate-limit-state-max-concurrent (org-tickets--rate-state)))))))

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

(ert-deftest org-tickets-test--progress-renders-done-over-total ()
  "The shared mode-line entry renders this buffer's done/total count."
  (org-tickets-test--with-stubs ((force-mode-line-update #'ignore))
    (with-temp-buffer
      (org-tickets--progress-init 10)
      (should (member org-tickets--progress-mode-line-entry
                      (default-value 'mode-line-misc-info)))
      (should (equal (org-tickets-test--progress-render) " [org-tickets: 0/10]"))
      (dotimes (_ 3)
        (org-tickets--progress-increment))
      (should (equal (org-tickets-test--progress-render) " [org-tickets: 3/10]")))))

(ert-deftest org-tickets-test--progress-init-replaces-stale-entry ()
  "Initializing progress repeatedly keeps one entry on the default mode line."
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
        (should (equal (org-tickets-test--progress-render)
                       " [org-tickets: 0/10]"))))))

(ert-deftest org-tickets-test--progress-clear-hides-without-uninstalling ()
  "Verify org-tickets--progress-clear stops this buffer's rendering but
leaves the shared entry installed on the default mode line."
  (org-tickets-test--with-stubs ((force-mode-line-update #'ignore))
    (with-temp-buffer
      (org-tickets--progress-init 5)
      (org-tickets--progress-clear)
      (should (member org-tickets--progress-mode-line-entry
                      (default-value 'mode-line-misc-info)))
      (should (null (org-tickets-test--progress-render))))))

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

;;;; Tests: Retry-After parsing

(ert-deftest org-tickets-test--async-parse-retry-after-reads-header ()
  "Verify org-tickets--async-parse-retry-after extracts Retry-After value."
  (should (= 3 (org-tickets--async-parse-retry-after "HTTP/1.1 429 Too Many Requests\nRetry-After: 3\n")))
  (should (= 60 (org-tickets--async-parse-retry-after "HTTP/1.1 429\nRetry-After: 60\n"))))

(ert-deftest org-tickets-test--async-parse-retry-after-defaults-to-5 ()
  "Verify org-tickets--async-parse-retry-after defaults to 5 when header is absent."
  (should (= 5 (org-tickets--async-parse-retry-after "HTTP/1.1 429 Too Many Requests\n"))))

;;;; Tests: Callbacks and rate-limit state run in the requesting buffer

(ert-deftest org-tickets-test--async-callback-runs-in-requesting-buffer ()
  "Success callbacks must run in the buffer that made the request,
not in url.el's response buffer."
  (with-temp-buffer
    (org-tickets--rate-limit-reset)
    (let ((org-buffer (current-buffer))
          (calls nil) (got-buffer nil) (got-response nil))
      (org-tickets-test--with-url-responses :deferred calls
        (org-tickets--async-request
         "GET" "/x"
         (lambda (resp _err)
           (setq got-buffer (current-buffer) got-response resp)))
        (should calls)
        ;; Answered in a fresh buffer, like url.el's response buffer.
        (org-tickets-test--url-respond (car calls) "HTTP/1.1 200 OK\n\n{\"a\": 1}")
        (should (eq got-buffer org-buffer))
        (should (equal (cdr (assq 'a got-response)) 1))))))

(ert-deftest org-tickets-test--async-429-state-lands-in-requesting-buffer ()
  "A 429 must throttle and queue in the requesting buffer's state,
and the retry timer must drain that same buffer's queue."
  (with-temp-buffer
    (org-tickets--rate-limit-reset)
    (let ((org-buffer (current-buffer))
          (calls nil) (timer-fn nil))
      (org-tickets-test--with-url-responses :deferred calls
        (org-tickets-test--with-stubs ((run-at-time
                                     (lambda (_secs _repeat fn &rest _) (setq timer-fn fn) nil)))
          (org-tickets--async-request "GET" "/x" #'ignore)
          (should (= (length calls) 1))
          (org-tickets-test--url-respond
           (car calls) "HTTP/1.1 429 Too Many Requests\nRetry-After: 3\n\n")
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
          (should (= (length calls) 2))
          (with-current-buffer org-buffer
            (let ((state (org-tickets--rate-state)))
              (should-not (org-tickets--rate-limit-state-throttled-p state))
              (should (null (org-tickets--rate-limit-state-pending-queue state))))))))))

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

;;;; Tests: Concurrency cap

(ert-deftest org-tickets-test--async-respects-concurrency-cap ()
  "With a cap of 2, the third request queues until one completes."
  (with-temp-buffer
    (org-tickets--rate-limit-reset)
    (let ((org-tickets-max-concurrent-requests 2)
          (calls nil))
      (org-tickets-test--with-url-responses :deferred calls
        (dotimes (_ 3)
          (org-tickets--async-request "GET" "/x" #'ignore))
        (should (= (length calls) 2))   ; third is queued
        ;; Complete one request -> queued one fires.
        (org-tickets-test--url-respond (car calls) "HTTP/1.1 200 OK\n\n{}")
        (should (= (length calls) 3))))))

(provide 'org-tickets-test-async)
;;; org-tickets-test-async.el ends here
