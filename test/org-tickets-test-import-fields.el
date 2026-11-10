;;; org-tickets-test-import-fields.el --- Import: links, attachments, properties  -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the parts of `org-tickets-import' between the Jira response
;; and the org heading: summary prefixes, issue links, the attachment id
;; map, the properties a pull writes or clears, description replacement,
;; and the `org-tickets-import-feature' command.

;;; Code:

(require 'ert)
(require 'org)
(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; Helpers

(defun org-tickets-test--pull-ticket-into (text &rest slots)
  "Pull a ticket of SLOTS onto the first heading of org TEXT.
Return the resulting buffer text."
  (with-temp-buffer
    (org-mode)
    (insert text)
    (goto-char (point-min))
    (org-tickets--update-org-heading-from-ticket
     (apply #'org-tickets--ticket-create slots))
    (buffer-string)))

(defun org-tickets-test--import-text (&rest slots)
  "Return the org text a fresh import of a ticket of SLOTS writes."
  (with-temp-buffer
    (org-mode)
    (org-tickets--issue-to-org (apply #'org-tickets--ticket-create slots))
    (buffer-string)))

(defun org-tickets-test--first-heading-props (text props)
  "Return PROPS of the first heading in org TEXT as an alist."
  (with-temp-buffer
    (org-mode)
    (insert text)
    (goto-char (point-min))
    (mapcar (lambda (prop) (cons prop (org-entry-get (point) prop))) props)))

;;;; Summary prefix

(ert-deftest org-tickets-test--strip-type-prefix ()
  "A leading \"TYPE: \" is stripped; a nil summary stays nil."
  (should (equal (org-tickets--strip-type-prefix "Story" "Story: Do it") "Do it"))
  (should (equal (org-tickets--strip-type-prefix "Story" "Bug: Do it") "Bug: Do it"))
  (should (equal (org-tickets--strip-type-prefix nil "Story: x") "Story: x"))
  (should-not (org-tickets--strip-type-prefix "Story" nil)))

;;;; Issue links

(ert-deftest org-tickets-test--parse-issuelinks-only-blocks-links ()
  "Only Blocks links count: outward keys are blocked by this issue, inward
keys block it.  Keys come out in reverse link order."
  (should (equal (org-tickets--parse-issuelinks
                  (org-tickets-test--json
                   "[{\"type\":{\"name\":\"Relates\"},\"outwardIssue\":{\"key\":\"P-X\"}},
                     {\"type\":{\"name\":\"Blocks\"},\"outwardIssue\":{\"key\":\"P-A\"}},
                     {\"type\":{\"name\":\"Blocks\"},\"outwardIssue\":{\"key\":\"P-B\"}},
                     {\"type\":{\"name\":\"Blocks\"},\"inwardIssue\":{\"key\":\"P-C\"}}]"))
                 '(("P-B" "P-A") . ("P-C")))))

;;;; Attachments

(ert-deftest org-tickets-test--attachment-id-map-skips-incomplete-attachments ()
  "Attachments missing a filename or id contribute no entry for it."
  (should (equal (sort (org-tickets--build-attachment-id-map
                        (org-tickets-test--json
                         "[{\"id\":\"1\",\"filename\":\"a.png\",\"mediaApiFileId\":\"u1\"},
                           {\"id\":\"2\",\"mediaApiFileId\":\"u2\"},
                           {\"filename\":\"c.txt\",\"mediaApiFileId\":\"u3\"},
                           {\"id\":\"4\",\"filename\":\"d.txt\"}]"))
                       (lambda (a b) (string< (car a) (car b))))
                 '(("1" . "a.png") ("4" . "d.txt") ("u1" . "a.png") ("u3" . "c.txt")))))

(ert-deftest org-tickets-test--issue-to-org-skips-attachment-without-filename ()
  "An attachment with no filename gets no link line."
  (let ((text (org-tickets-test--import-text
               :key "P-1" :type "Feature" :summary "F"
               :attachments (org-tickets-test--json
                             "[{\"id\":\"1\",\"content\":\"https://x.test/1\"},
                               {\"id\":\"2\",\"filename\":\"b.png\",
                                \"content\":\"https://x.test/2\"}]"))))
    (should (string-match-p "^- b\\.png \\[\\[https://x\\.test/2\\]\\[b\\.png\\]\\]$" text))
    (should-not (string-match-p "x\\.test/1" text))
    (should (= (seq-count (lambda (line) (string-prefix-p "- " line))
                          (split-string text "\n"))
               1))))

;;;; Properties written by a pull

(ert-deftest org-tickets-test--pull-clears-missing-properties ()
  "A pull with no story points, parent, sprint or labels clears them:
STORY_POINTS is removed, the others are left empty."
  (let ((text (org-tickets-test--pull-ticket-into
               (concat "* F\n:PROPERTIES:\n:JIRA_KEY: P-1\n:STORY_POINTS: 3\n"
                       ":PARENT: P-9\n:SPRINT: Sprint 4\n:LABELS: a,b\n:END:\n")
               :key "P-1" :type "Story" :summary "F")))
    (should (equal (org-tickets-test--first-heading-props
                    text '("STORY_POINTS" "PARENT" "SPRINT" "LABELS"))
                   '(("STORY_POINTS") ("PARENT" . "") ("SPRINT" . "")
                     ("LABELS" . ""))))
    (should-not (string-match-p "STORY_POINTS" text))))

(ert-deftest org-tickets-test--import-writes-no-empty-optional-properties ()
  "A first import skips absent optional properties but always writes LABELS."
  (should (equal (org-tickets-test--first-heading-props
                  (org-tickets-test--import-text :key "P-1" :type "Feature"
                                                 :summary "F")
                  '("LABELS" "PARENT" "SPRINT" "STORY_POINTS"))
                 '(("LABELS" . "") ("PARENT") ("SPRINT") ("STORY_POINTS")))))

;;;; Description replacement

(ert-deftest org-tickets-test--pull-fills-heading-without-body ()
  "A heading with no body at all gets the pulled description."
  (should (string-suffix-p ":END:\nBody.\n* Next\n"
                           (org-tickets-test--pull-ticket-into
                            "* Old\n* Next\n"
                            :key "P-1" :type "Feature" :summary "New"
                            :description "Body.")))
  (should (string-suffix-p ":END:\nBody.\n"
                           (org-tickets-test--pull-ticket-into
                            "* Old" :key "P-1" :type "Feature" :summary "New"
                            :description "Body."))))

(ert-deftest org-tickets-test--replace-description-on-bare-heading ()
  "Replacing the description of a heading with no contents inserts it."
  (dolist (case '(("* T\n* Next\n" . "* T\nBody.\n* Next\n")
                  ("* T" . "* T\nBody.\n")))
    (with-temp-buffer
      (org-mode)
      (insert (car case))
      (goto-char (point-min))
      (org-tickets--replace-description "Body.")
      (should (equal (buffer-string) (cdr case))))))

(ert-deftest org-tickets-test--pull-keeps-every-comment-subtree ()
  "Each COMMENT subtree of the old description survives a pull, in order."
  (should (string-suffix-p
           ":END:\nNew.\n** COMMENT one\nx\n** COMMENT two\ny\n"
           (org-tickets-test--pull-ticket-into
            (concat "* F\n:PROPERTIES:\n:JIRA_KEY: P-1\n:END:\nOld.\n"
                    "** COMMENT one\nx\n** COMMENT two\ny\n")
            :key "P-1" :type "Feature" :summary "F"
            :description "New."))))

;;;; The import command

(ert-deftest org-tickets-test--import-feature-inserts-heading ()
  "`org-tickets-import-feature' fetches the issue and inserts its heading."
  (let ((fetched nil))
    (org-tickets-test--with-fake-config
     (org-tickets-test--with-stubs
         ((org-tickets--get-ticket
           (lambda (key)
             (push key fetched)
             (org-tickets-test--json
              "{\"key\":\"PROJ-5\",\"fields\":{
                 \"issuetype\":{\"name\":\"Feature\"},
                 \"summary\":\"Feature: Big thing\",\"labels\":[\"x\"],
                 \"fixVersions\":[{\"name\":\"25.3\"}],
                 \"duedate\":\"2026-12-01\",
                 \"description\":{\"type\":\"doc\",\"version\":1,\"content\":[
                   {\"type\":\"paragraph\",\"content\":[
                     {\"type\":\"text\",\"text\":\"Desc.\"}]}]}}}"))))
       (with-temp-buffer
         (org-mode)
         (org-tickets-import-feature "PROJ-5")
         (goto-char (point-min))
         (should (equal (org-get-heading t t t t) "Big thing"))
         (should (equal (mapcar (lambda (p) (org-entry-get (point) p))
                                '("JIRA_KEY" "JIRA_TYPE" "FIX_VERSION" "LABELS"
                                  "DUE_DATE"))
                        '("PROJ-5" "Feature" "25.3" "x" "2026-12-01")))
         (should (string-match-p ":END:\n\nDesc\\.\n" (buffer-string))))))
    (should (equal fetched '("PROJ-5")))))

(provide 'org-tickets-test-import-fields)

;;; org-tickets-test-import-fields.el ends here
