;;; org-tickets-test-async-queue.el --- Queue and batch edge cases for org-tickets async  -*- lexical-binding: t; -*-

;;; Commentary:

;; Edge cases of the async request queue in org-tickets-async.el: the
;; queue draining after failures, throttling, the two concurrency caps,
;; the in-flight counter, a requesting buffer killed mid-request, and
;; `org-tickets--async-batch' with a misbehaving thunk.

;;; Code:

(require 'ert)
(require 'org-tickets)
(require 'org-tickets-async)
(require 'org-tickets-test-fixtures)

(defun org-tickets-test--in-flight ()
  "Return the current buffer's in-flight request count."
  (org-tickets--rate-limit-state-in-flight (org-tickets--rate-state)))

(defun org-tickets-test--queue-length ()
  "Return the length of the current buffer's pending request queue."
  (length (org-tickets--rate-limit-state-pending-queue (org-tickets--rate-state))))

(defun org-tickets-test--drain-after-first (first-response callback)
  "Send two requests under a cap of 1; answer the first with FIRST-RESPONSE.
CALLBACK handles both responses.  Returns (CALLS-AFTER-FIRST
. IN-FLIGHT-AFTER-SECOND): requests fired once the first was answered,
and the in-flight count once the second was answered too."
  (with-temp-buffer
    (org-tickets--rate-limit-reset)
    (let ((org-tickets-max-concurrent-requests 1)
          (calls nil)
          (fired nil))
      (org-tickets-test--with-url-responses :deferred calls
        (org-tickets--async-request "GET" "/1" callback)
        (org-tickets--async-request "GET" "/2" callback)
        (should (= (length calls) 1))
        (org-tickets-test--url-respond (car calls) first-response)
        (setq fired (length calls))
        (org-tickets-test--url-respond (car calls) "HTTP/1.1 200 OK\n\n{}"))
      (cons fired (org-tickets-test--in-flight)))))

;;;; Draining after failures

(ert-deftest org-tickets-test--queue-drains-after-500 ()
  "A 500 response still frees its slot for the queued request."
  (should (equal (org-tickets-test--drain-after-first
                  "HTTP/1.1 500 Internal Server Error\n\noops" #'ignore)
                 '(2 . 0))))

(ert-deftest org-tickets-test--queue-drains-after-throwing-callback ()
  "A callback that signals still frees its slot for the queued request."
  (org-tickets-test--with-stubs ((display-warning #'ignore))
    (should (equal (org-tickets-test--drain-after-first
                    "HTTP/1.1 200 OK\n\n{}"
                    (lambda (_response _err) (error "Callback bug")))
                   '(2 . 0)))))

(ert-deftest org-tickets-test--dispatch-empty-status-reports-missing-headers ()
  "A response with no header terminator reports an error to the callback."
  (with-temp-buffer
    (org-tickets--rate-limit-reset)
    (let ((got nil))
      (org-tickets--async-dispatch-response
       '(:status "" :body "") (lambda (r e) (setq got (list r e))) #'ignore
       (current-buffer))
      (should (equal got '(nil "Could not find end of HTTP headers")))
      (should (= (org-tickets-test--in-flight) 0)))))

(ert-deftest org-tickets-test--in-flight-never-negative ()
  "Responses arriving with nothing in flight leave the count at 0."
  (with-temp-buffer
    (org-tickets--rate-limit-reset)
    (dotimes (_ 2)
      (org-tickets--async-dispatch-response
       '(:status "HTTP/1.1 200 OK\n" :body "{}") #'ignore #'ignore
       (current-buffer)))
    (should (= (org-tickets-test--in-flight) 0))))

;;;; Requesting buffer killed

(ert-deftest org-tickets-test--response-for-killed-buffer-is-dropped ()
  "A response whose requesting buffer is gone runs no callback."
  (let ((calls nil)
        (called nil))
    (org-tickets-test--with-url-responses :deferred calls
      (with-temp-buffer
        (org-tickets--rate-limit-reset)
        (org-tickets--async-request "GET" "/x" (lambda (&rest _) (setq called t))))
      (org-tickets-test--url-respond (car calls) "HTTP/1.1 200 OK\n\n{}"))
    (should-not called)))

(ert-deftest org-tickets-test--response-for-killed-buffer-leaves-others-alone ()
  "A dead requester's response never touches the current buffer's state."
  (let ((dead (generate-new-buffer " dead"))
        (fired 0))
    (kill-buffer dead)
    (with-temp-buffer
      (org-tickets--rate-limit-reset)
      (let ((state (org-tickets--rate-state)))
        (setf (org-tickets--rate-limit-state-in-flight state) 1)
        (setf (org-tickets--rate-limit-state-max-concurrent state) 1)
        (org-tickets--rate-limit-enqueue state (lambda () (setq fired (1+ fired))))
        (org-tickets--async-dispatch-response
         '(:status "HTTP/1.1 200 OK\n" :body "{}") #'ignore #'ignore dead)
        (should (= (org-tickets-test--in-flight) 1))
        (should (= (org-tickets-test--queue-length) 1))
        (should (= fired 0))))))

;;;; Throttling

(ert-deftest org-tickets-test--request-while-throttled-is-queued ()
  "After a 429, a new request waits in the queue instead of firing."
  (with-temp-buffer
    (org-tickets--rate-limit-reset)
    (let ((calls nil))
      (org-tickets-test--with-url-responses :deferred calls
        (org-tickets--async-request "GET" "/1" #'ignore)
        (org-tickets-test--url-respond
         (car calls) "HTTP/1.1 429 Too Many Requests\nRetry-After: 1\n\n")
        (org-tickets--async-request "GET" "/2" #'ignore)
        (should (= (length calls) 1))
        (should (= (org-tickets-test--queue-length) 2))))))

(ert-deftest org-tickets-test--header-mentioning-429-does-not-throttle ()
  "Only a 429 status line throttles; a header mentioning 429 does not."
  (with-temp-buffer
    (org-tickets--rate-limit-reset)
    (let ((calls nil) (got nil))
      (org-tickets-test--with-url-responses :deferred calls
        (org-tickets--async-request "GET" "/1" (lambda (r _e) (setq got r)))
        (org-tickets-test--url-respond
         (car calls) "HTTP/1.1 200 OK\nX-Trace: HTTP/1.1 429\n\n{\"a\": 1}"))
      (should (equal got '((a . 1))))
      (should-not (org-tickets--rate-limit-state-throttled-p (org-tickets--rate-state))))))

;;;; Concurrency caps

(ert-deftest org-tickets-test--effective-max-is-stricter-cap ()
  "The effective cap is the smaller of the defcustom and the 429 cap."
  (let ((state (org-tickets--rate-limit-state-create :max-concurrent 2)))
    (let ((org-tickets-max-concurrent-requests 5))
      (should (= (org-tickets--rate-limit-effective-max state) 2)))
    (let ((org-tickets-max-concurrent-requests 1))
      (should (= (org-tickets--rate-limit-effective-max state) 1)))
    (let ((org-tickets-max-concurrent-requests nil))
      (should (= (org-tickets--rate-limit-effective-max state) 2))))
  (let ((state (org-tickets--rate-limit-state-create)))
    (let ((org-tickets-max-concurrent-requests 3))
      (should (= (org-tickets--rate-limit-effective-max state) 3)))
    (let ((org-tickets-max-concurrent-requests nil))
      (should-not (org-tickets--rate-limit-effective-max state)))))

(ert-deftest org-tickets-test--at-capacity-uses-stricter-cap ()
  "Capacity is reached at whichever cap is stricter."
  (let ((state (org-tickets--rate-limit-state-create :max-concurrent 4 :in-flight 2)))
    (let ((org-tickets-max-concurrent-requests 2))
      (should (org-tickets--rate-limit-at-capacity-p state)))
    (let ((org-tickets-max-concurrent-requests 8))
      (should-not (org-tickets--rate-limit-at-capacity-p state)))
    (setf (org-tickets--rate-limit-state-max-concurrent state) 1)
    (let ((org-tickets-max-concurrent-requests 8))
      (should (org-tickets--rate-limit-at-capacity-p state)))
    (setf (org-tickets--rate-limit-state-max-concurrent state) nil)
    (let ((org-tickets-max-concurrent-requests nil))
      (should-not (org-tickets--rate-limit-at-capacity-p state)))))

(ert-deftest org-tickets-test--429-cap-stricter-than-defcustom-limits-firing ()
  "After a 429 and resume, the 429 cap (2) beats a looser defcustom (5)."
  (with-temp-buffer
    (org-tickets--rate-limit-reset)
    (let ((org-tickets-max-concurrent-requests 5)
          (calls nil))
      (org-tickets-test--with-url-responses :deferred calls
        (org-tickets--async-request "GET" "/0" #'ignore)
        (org-tickets-test--url-respond
         (car calls) "HTTP/1.1 429 Too Many Requests\n\n")
        (dotimes (_ 3) (org-tickets--async-request "GET" "/n" #'ignore))
        (org-tickets--rate-limit-resume)
        ;; One original + two of the four queued requests fire under a cap of 2.
        (should (= (length calls) 3))
        (should (= (org-tickets-test--queue-length) 2))))))

;;;; Batch

(ert-deftest org-tickets-test--async-batch-ignores-second-done ()
  "A thunk calling DONE twice neither completes the batch early nor twice.
Its first result is kept."
  (let ((finals nil)
        (late nil))
    (org-tickets--async-batch
     (list (lambda (done)
             (funcall done 'first nil)
             (funcall done 'again "dup"))
           (lambda (done) (setq late done)))
     (lambda (results) (push results finals)))
    (should-not finals)
    (funcall late 'second nil)
    (should (equal finals '(((first) (second)))))))

(provide 'org-tickets-test-async-queue)
;;; org-tickets-test-async-queue.el ends here
