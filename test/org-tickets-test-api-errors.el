;;; org-tickets-test-api-errors.el --- Error and edge-case tests for org-tickets-api  -*- lexical-binding: t; -*-

;;; Commentary:

;; Error paths and edge cases of org-tickets-api.el: synchronous request
;; failures, credential and issue-type errors, HTTP response parsing,
;; sprint pagination and sprint resolution.

;;; Code:

(require 'ert)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; Helpers

(defmacro org-tickets-test--with-sync-response (response buffer-var &rest body)
  "Run BODY with `url-retrieve-synchronously' answering RESPONSE.
BUFFER-VAR is bound to the response buffer handed out, so BODY can
check that it was killed."
  (declare (indent 2))
  `(let ((,buffer-var nil))
     (org-tickets-test--with-fake-config
       (org-tickets-test--with-stubs
           ((url-retrieve-synchronously
             (lambda (&rest _)
               (setq ,buffer-var (generate-new-buffer " test-http"))
               (with-current-buffer ,buffer-var (insert ,response))
               ,buffer-var)))
         ,@body))))

(defmacro org-tickets-test--with-api-pages (pages log &rest body)
  "Run BODY with `org-tickets--api-request' answering PAGES in order.
Each requested endpoint is appended to LOG.  Config resolution is
stubbed out."
  (declare (indent 2))
  `(let ((queue ,pages))
     (org-tickets-test--with-stubs
         ((org-tickets--api-request
           (lambda (_method endpoint &rest _)
             (setq ,log (append ,log (list endpoint)))
             (pop queue)))
          (org-tickets--resolve-config #'ignore))
       (let ((org-tickets-project-key "PROJ"))
         ,@body))))

(defun org-tickets-test--split (response)
  "Return `org-tickets--http-split-response' of RESPONSE in a unibyte buffer."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert response)
    (org-tickets--http-split-response)))

;;;; Synchronous requests

(ert-deftest org-tickets-test--api-request-non-2xx-signals-status-and-body ()
  "A non-2xx response signals an error naming status and body.
The response buffer is killed even though the request failed."
  (org-tickets-test--with-sync-response
      "HTTP/1.1 404 Not Found\nContent-Type: application/json\n\n{\"errorMessages\":[\"Issue does not exist\"]}"
      buffer
    (let ((message (error-message-string
                    (should-error (org-tickets--api-request "GET" "/rest/api/3/issue/X-1")))))
      (should (string-match-p "404 Not Found" message))
      (should (string-match-p "Issue does not exist" message)))
    (should buffer)
    (should-not (buffer-live-p buffer))))

(ert-deftest org-tickets-test--api-request-header-mentioning-200-is-not-success ()
  "A failed response is an error even when a header contains \"HTTP/1.1 200\"."
  (org-tickets-test--with-sync-response
      "HTTP/1.1 502 Bad Gateway\nVia: HTTP/1.1 200 upstream\n\n{}"
      _buffer
    (should-error (org-tickets--api-request "GET" "/x"))))

(ert-deftest org-tickets-test--update-ticket-without-fields-makes-no-http-request ()
  "Updating a record that carries no fields never reaches the network."
  (let ((requested nil))
    (org-tickets-test--with-fake-config
      (org-tickets-test--with-stubs
          ((url-retrieve-synchronously
            (lambda (&rest _) (setq requested t) nil)))
        (let ((org-tickets-default-sprint nil))
          (should-not (org-tickets--update-ticket
                       (org-tickets--ticket-create :key "PROJ-1"))))))
    (should-not requested)))

;;;; Credentials

(ert-deftest org-tickets-test--missing-authinfo-entry-names-host ()
  "With no authinfo entry for the host, resolving config names the host."
  (org-tickets-test--with-fake-config
    (org-tickets-test--with-stubs ((auth-source-search #'ignore))
      (should (string-match-p
               "No authinfo entry found for host: test\\.atlassian\\.net"
               (error-message-string
                (should-error (org-tickets--resolve-config))))))))

;;;; Issue types

(defun org-tickets-test--issue-types-error (json)
  "Return the error message of fetching issue types answered by JSON.
JSON nil stands for an empty response."
  (org-tickets-test--with-stubs
      ((org-tickets--api-request
        (lambda (&rest _) (and json (org-tickets-test--json json)))))
    (let ((org-tickets-project-key "PROJ"))
      (error-message-string (should-error (org-tickets--fetch-issue-types))))))

(ert-deftest org-tickets-test--fetch-issue-types-empty-response-errors ()
  "An empty createmeta response is an error."
  (should (string-match-p "empty response"
                          (org-tickets-test--issue-types-error nil))))

(ert-deftest org-tickets-test--fetch-issue-types-no-projects-errors ()
  "A createmeta response with no projects is an error."
  (should (string-match-p "No projects found"
                          (org-tickets-test--issue-types-error "{\"projects\": []}"))))

(ert-deftest org-tickets-test--fetch-issue-types-no-issuetypes-errors ()
  "A project with no issue types is an error."
  (should (string-match-p
           "No issueTypes found"
           (org-tickets-test--issue-types-error
            "{\"projects\": [{\"key\": \"PROJ\", \"issuetypes\": []}]}"))))

;;;; HTTP response parsing

(ert-deftest org-tickets-test--http-success-p-reads-status-line-only ()
  "Only the status line decides success; headers mentioning 200 do not."
  (should (org-tickets--http-success-p "HTTP/1.1 200 OK\n"))
  (should (org-tickets--http-success-p "HTTP/2 204\r\n"))
  (should (org-tickets--http-success-p "HTTP/1.1 201 Created\nX: y\n"))
  (should-not (org-tickets--http-success-p "HTTP/1.1 404 Not Found\nX-Note: HTTP/1.1 200\n"))
  (should-not (org-tickets--http-success-p "HTTP/1.1 500 Server Error 200\n"))
  (should-not (org-tickets--http-success-p "HTTP/1.1 302 Found\nLocation: /a 200\n"))
  (should-not (org-tickets--http-success-p "HTTP/1.1 2000 Odd\n"))
  (should-not (org-tickets--http-success-p "")))

(ert-deftest org-tickets-test--http-split-response-without-blank-line ()
  "A response with no blank line after the headers has empty status and body."
  (should (equal (org-tickets-test--split "HTTP/1.1 200 OK")
                 '(:status "" :body ""))))

(ert-deftest org-tickets-test--http-split-response-crlf-headers ()
  "CRLF-terminated headers split at the blank line, keeping the body whole."
  (let ((parsed (org-tickets-test--split
                 "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n{\"a\":\n1}")))
    (should (org-tickets--http-success-p (plist-get parsed :status)))
    (should-not (string-match-p "{" (plist-get parsed :status)))
    (should (equal (org-tickets--http-parse-json-body (plist-get parsed :body))
                   '((a . 1))))))

(ert-deftest org-tickets-test--http-split-response-decodes-utf-8-body ()
  "The body is decoded from UTF-8."
  (should (equal (plist-get (org-tickets-test--split
                             (concat "HTTP/1.1 200 OK\n\n"
                                     (encode-coding-string "café" 'utf-8)))
                            :body)
                 "\ncafé")))

;;;; Sprint listing

(ert-deftest org-tickets-test--board-sprints-without-is-last-pages-until-empty ()
  "Without isLast, pages are fetched until an empty page."
  (let ((log nil))
    (org-tickets-test--with-api-pages
        (list (org-tickets-test--json "{\"values\": [{\"id\": 1, \"name\": \"A\"}]}")
              (org-tickets-test--json "{\"values\": [{\"id\": 2, \"name\": \"B\"}]}")
              (org-tickets-test--json "{\"values\": []}"))
        log
      (should (equal (org-tickets--fetch-board-sprints 7) '(("A" . 1) ("B" . 2)))))
    (should (equal (mapcar (lambda (e) (car (last (split-string e "=")))) log)
                   '("0" "1" "2")))))

(ert-deftest org-tickets-test--board-sprints-empty-first-page ()
  "An empty first page yields no sprints after one request."
  (let ((log nil))
    (org-tickets-test--with-api-pages
        (list (org-tickets-test--json "{\"values\": [], \"isLast\": false}"))
        log
      (should-not (org-tickets--fetch-board-sprints 7)))
    (should (= (length log) 1))))

(ert-deftest org-tickets-test--board-sprints-json-false-is-last-keeps-paging ()
  "isLast false on what turns out to be the last page fetches one more page."
  (let ((log nil))
    (org-tickets-test--with-api-pages
        (list (org-tickets-test--json
               "{\"values\": [{\"id\": 1, \"name\": \"A\"}], \"isLast\": false}")
              (org-tickets-test--json "{\"values\": [], \"isLast\": false}"))
        log
      (should (equal (org-tickets--fetch-board-sprints 7) '(("A" . 1)))))
    (should (= (length log) 2))))

(ert-deftest org-tickets-test--board-id-nil-without-boards ()
  "A project with no boards has no board id."
  (let ((log nil))
    (org-tickets-test--with-api-pages
        (list (org-tickets-test--json "{\"values\": []}"))
        log
      (should-not (org-tickets--get-board-id-for-project)))))

;;;; Sprint resolution

(ert-deftest org-tickets-test--resolve-sprint-id-fetches-board-then-sprints ()
  "With an empty cache, the board and its sprints are fetched.
The result is the numeric id `org-tickets--resolve-sprint-value' needs."
  (let ((log nil)
        (org-tickets--sprint-cache nil))
    (org-tickets-test--with-api-pages
        (list (org-tickets-test--json "{\"values\": [{\"id\": 210}]}")
              (org-tickets-test--json
               "{\"values\": [{\"id\": 3453, \"name\": \"Sprint 1\"}], \"isLast\": true}"))
        log
      (should (eql (org-tickets--resolve-sprint-value "Sprint 1") 3453))
      (should (string-match-p "/board\\?projectKeyOrId=PROJ" (nth 0 log)))
      (should (string-match-p "/board/210/sprint" (nth 1 log)))
      ;; Cached: no further requests.
      (should (eql (org-tickets--resolve-sprint-id "Sprint 1") 3453))
      (should (= (length log) 2)))))

(ert-deftest org-tickets-test--resolve-sprint-id-without-board-caches-nothing ()
  "When the project has no board, nothing is cached and the name is unresolved."
  (let ((log nil)
        (org-tickets--sprint-cache nil))
    (org-tickets-test--with-api-pages
        (list (org-tickets-test--json "{\"values\": []}"))
        log
      (should-not (org-tickets--resolve-sprint-id "Sprint 1"))
      (should-not org-tickets--sprint-cache)
      (should (= (length log) 1)))))

(ert-deftest org-tickets-test--resolve-sprint-value-rejects-other-types ()
  "A sprint that is neither a string nor a number resolves to nil."
  (org-tickets-test--with-stubs
      ((org-tickets--resolve-sprint-id (lambda (_) (error "Unexpected lookup"))))
    (should-not (org-tickets--resolve-sprint-value 'sprint-1))
    (should-not (org-tickets--resolve-sprint-value '("Sprint 1")))))

(provide 'org-tickets-test-api-errors)
;;; org-tickets-test-api-errors.el ends here
