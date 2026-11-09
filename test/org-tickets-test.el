;;; org-tickets-test.el --- Test aggregator for org-tickets  -*- lexical-binding: t; -*-

;; Aggregates every test file; it holds only `require's.  Load it to run
;; all tests, or load an individual test file for one suite.

;;; Code:

(require 'ert)

(require 'org-tickets)
(require 'org-tickets-test-fixtures)
(require 'org-tickets-test-parse)
(require 'org-tickets-test-sync)
(require 'org-tickets-test-sync-links)
(require 'org-tickets-test-sync-sprint)
(require 'org-tickets-test-sync-due-date)
(require 'org-tickets-test-inheritance)
(require 'org-tickets-test-convert)
(require 'org-tickets-test-convert-nodes)
(require 'org-tickets-test-import)
(require 'org-tickets-test-import-adf)
(require 'org-tickets-test-attachments-upload)
(require 'org-tickets-test-attachments-sync)
(require 'org-tickets-test-macro)
(require 'org-tickets-test-cmd)
(require 'org-tickets-test-async)
(require 'org-tickets-test-sync-flow)
(require 'org-tickets-test-attachments-async)
(require 'org-tickets-test-roundtrip)
(require 'org-tickets-test-headings-push)
(require 'org-tickets-test-headings-pull)
(require 'org-tickets-test-cmd-ticket-at-point)
(require 'org-tickets-test-list-continuation)
(require 'org-tickets-test-ordered-start)
(require 'org-tickets-test-fields)
(require 'org-tickets-test-sync-flow-phase2)
(require 'org-tickets-test-record)
(require 'org-tickets-test-options)
(require 'org-tickets-test-api)
(require 'org-tickets-test-graph)

(provide 'org-tickets-test)

;;; org-tickets-test.el ends here
