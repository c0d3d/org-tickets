;;; org-tickets-test-record.el --- Tests for org-tickets--define-record  -*- lexical-binding: t; -*-

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

;; Tests for `org-tickets--define-record', the native replacement for
;; `cl-defstruct' (cl-lib is banned project-wide; see CLAUDE.md).
;;
;; The macro is load-bearing: every ticket, document and rate-limit-state
;; in the package flows through the constructors, accessors and setters it
;; generates, so its contract is pinned down here in detail.  Tests assert
;; on observable behaviour of the generated functions -- construct, read,
;; write, type-test, reject bad input -- never on the expansion's shape.

;;; Code:

(require 'ert)

(require 'org-tickets)
(require 'org-tickets-test-fixtures)

;;;; Record types used only by these tests

(org-tickets--define-record org-tickets-test--point
    "A two-slot record with no slot defaults."
  x
  y)

(org-tickets--define-record org-tickets-test--defaults
    "A record exercising slot defaults."
  (plain 42)
  (computed (+ 1 2))
  (fresh-list (list 'a))
  (no-default))

(org-tickets--define-record org-tickets-test--single
    "A record with exactly one slot."
  only)

(defvar org-tickets-test--record-eval-count 0
  "Counts evaluations of a slot default form.")

(org-tickets--define-record org-tickets-test--counted
    "A record whose default increments `org-tickets-test--record-eval-count'."
  (tick (setq org-tickets-test--record-eval-count
              (1+ org-tickets-test--record-eval-count))))

;;;; Construction and slot access

(ert-deftest org-tickets-test--record-round-trips-all-slots ()
  "Every supplied slot reads back through its accessor."
  (let ((p (org-tickets-test--point-create :x 3 :y 4)))
    (should (= 3 (org-tickets-test--point-x p)))
    (should (= 4 (org-tickets-test--point-y p)))))

(ert-deftest org-tickets-test--record-keyword-order-is-irrelevant ()
  "Slot keywords may be supplied in any order."
  (let ((a (org-tickets-test--point-create :x 1 :y 2))
        (b (org-tickets-test--point-create :y 2 :x 1)))
    (should (= (org-tickets-test--point-x a) (org-tickets-test--point-x b)))
    (should (= (org-tickets-test--point-y a) (org-tickets-test--point-y b)))
    (should (equal a b))))

(ert-deftest org-tickets-test--record-omitted-slots-are-nil ()
  "A slot with no default and no supplied value reads as nil."
  (let ((p (org-tickets-test--point-create :x 1)))
    (should (= 1 (org-tickets-test--point-x p)))
    (should-not (org-tickets-test--point-y p))))

(ert-deftest org-tickets-test--record-constructor-accepts-no-arguments ()
  "Calling the constructor with no arguments fills every slot with its default."
  (let ((p (org-tickets-test--point-create))
        (d (org-tickets-test--defaults-create)))
    (should-not (org-tickets-test--point-x p))
    (should-not (org-tickets-test--point-y p))
    (should (= 42 (org-tickets-test--defaults-plain d)))))

(ert-deftest org-tickets-test--record-supports-single-slot-type ()
  "A one-slot record constructs and reads back correctly."
  (let ((s (org-tickets-test--single-create :only "v")))
    (should (equal "v" (org-tickets-test--single-only s)))
    (should (org-tickets-test--single-p s))))

(ert-deftest org-tickets-test--record-slots-hold-arbitrary-values ()
  "Slots store any Lisp object, including keywords and nested records."
  (let* ((inner (org-tickets-test--point-create :x 1 :y 2))
         (outer (org-tickets-test--point-create :x inner :y :some-keyword)))
    (should (eq inner (org-tickets-test--point-x outer)))
    (should (eq :some-keyword (org-tickets-test--point-y outer)))))

;;;; Slot defaults

(ert-deftest org-tickets-test--record-applies-slot-defaults ()
  "Unsupplied slots take their declared default value."
  (let ((d (org-tickets-test--defaults-create)))
    (should (= 42 (org-tickets-test--defaults-plain d)))
    (should (= 3 (org-tickets-test--defaults-computed d)))
    (should (equal '(a) (org-tickets-test--defaults-fresh-list d)))
    (should-not (org-tickets-test--defaults-no-default d))))

(ert-deftest org-tickets-test--record-explicit-nil-overrides-default ()
  "An explicitly supplied nil wins over a non-nil default.
This is the distinction `plist-member' buys over `plist-get': a slot
passed as nil must not silently fall back to its default."
  (let ((d (org-tickets-test--defaults-create :plain nil)))
    (should-not (org-tickets-test--defaults-plain d))))

(ert-deftest org-tickets-test--record-supplied-value-overrides-default ()
  "A supplied non-nil value wins over the default."
  (let ((d (org-tickets-test--defaults-create :plain 7)))
    (should (= 7 (org-tickets-test--defaults-plain d)))))

(ert-deftest org-tickets-test--record-defaults-are-evaluated-per-construction ()
  "Each construction evaluates default forms afresh, so no structure is shared.
A default of (list 'a) must not hand every instance the same cons cell."
  (let ((a (org-tickets-test--defaults-create))
        (b (org-tickets-test--defaults-create)))
    (should (equal (org-tickets-test--defaults-fresh-list a)
                   (org-tickets-test--defaults-fresh-list b)))
    (should-not (eq (org-tickets-test--defaults-fresh-list a)
                    (org-tickets-test--defaults-fresh-list b)))
    (setcar (org-tickets-test--defaults-fresh-list a) 'mutated)
    (should (equal '(a) (org-tickets-test--defaults-fresh-list b)))))

(ert-deftest org-tickets-test--record-default-not-evaluated-when-slot-supplied ()
  "A default form is not evaluated when its slot is supplied.
Defaults may have side effects or be expensive; supplying the slot must
skip the form entirely."
  (setq org-tickets-test--record-eval-count 0)
  (org-tickets-test--counted-create :tick 'supplied)
  (should (= 0 org-tickets-test--record-eval-count))
  (org-tickets-test--counted-create)
  (should (= 1 org-tickets-test--record-eval-count))
  (org-tickets-test--counted-create)
  (should (= 2 org-tickets-test--record-eval-count)))

;;;; Mutation through setf

(ert-deftest org-tickets-test--record-accessors-are-setf-able ()
  "Each accessor is a valid `setf' place."
  (let ((p (org-tickets-test--point-create :x 1 :y 2)))
    (setf (org-tickets-test--point-x p) 10)
    (setf (org-tickets-test--point-y p) 20)
    (should (= 10 (org-tickets-test--point-x p)))
    (should (= 20 (org-tickets-test--point-y p)))))

(ert-deftest org-tickets-test--record-setf-touches-only-its-own-slot ()
  "Writing one slot leaves the others untouched."
  (let ((d (org-tickets-test--defaults-create)))
    (setf (org-tickets-test--defaults-plain d) 'changed)
    (should (eq 'changed (org-tickets-test--defaults-plain d)))
    (should (= 3 (org-tickets-test--defaults-computed d)))
    (should (equal '(a) (org-tickets-test--defaults-fresh-list d)))
    (should-not (org-tickets-test--defaults-no-default d))))

(ert-deftest org-tickets-test--record-setf-can-store-nil ()
  "A slot can be set back to nil."
  (let ((p (org-tickets-test--point-create :x 1)))
    (setf (org-tickets-test--point-x p) nil)
    (should-not (org-tickets-test--point-x p))))

(ert-deftest org-tickets-test--record-instances-are-independent ()
  "Mutating one instance does not affect another."
  (let ((a (org-tickets-test--point-create :x 1 :y 1))
        (b (org-tickets-test--point-create :x 1 :y 1)))
    (setf (org-tickets-test--point-x a) 99)
    (should (= 99 (org-tickets-test--point-x a)))
    (should (= 1 (org-tickets-test--point-x b)))))

(ert-deftest org-tickets-test--record-setf-evaluates-record-form-once ()
  "The record form in a `setf' place is evaluated a single time.
A double evaluation would run caller side effects twice."
  (let* ((p (org-tickets-test--point-create :x 0 :y 0))
         (calls 0)
         (getter (lambda () (setq calls (1+ calls)) p)))
    (setf (org-tickets-test--point-x (funcall getter)) 5)
    (should (= 1 calls))
    (should (= 5 (org-tickets-test--point-x p)))))

;;;; Type predicate

(ert-deftest org-tickets-test--record-predicate-accepts-own-type ()
  "The predicate is non-nil for an instance of its own type."
  (should (org-tickets-test--point-p (org-tickets-test--point-create)))
  (should (org-tickets-test--defaults-p (org-tickets-test--defaults-create))))

(ert-deftest org-tickets-test--record-predicate-rejects-other-record-types ()
  "The predicate distinguishes between record types."
  (let ((point (org-tickets-test--point-create))
        (defaults (org-tickets-test--defaults-create)))
    (should-not (org-tickets-test--point-p defaults))
    (should-not (org-tickets-test--defaults-p point))))

(ert-deftest org-tickets-test--record-predicate-rejects-non-records ()
  "The predicate is nil for every non-record object, without signalling.
A bare `aref' on the type slot would error on nil or a number, so the
predicate must guard with `recordp' first."
  (dolist (value (list nil t 0 1.5 "string" 'symbol :keyword
                       '(a b) [1 2 3] (make-hash-table)))
    (should-not (org-tickets-test--point-p value))))

(ert-deftest org-tickets-test--record-predicate-rejects-lookalike-vector ()
  "A vector whose first element is the type name is not a record."
  (should-not (org-tickets-test--point-p (vector 'org-tickets-test--point 1 2))))

;;;; Constructor argument validation

(ert-deftest org-tickets-test--record-constructor-rejects-unknown-slot ()
  "An unknown slot keyword signals an error naming the offending slot."
  (let ((err (should-error (org-tickets-test--point-create :x 1 :zzz 2)
                           :type 'error)))
    (should (string-match-p "unknown" (cadr err)))
    (should (string-match-p ":zzz" (cadr err)))))

(ert-deftest org-tickets-test--record-constructor-rejects-misspelled-slot ()
  "A near-miss slot name is rejected rather than silently dropped.
This is the whole point of validating: a typo must not quietly produce a
record with a nil slot."
  (should-error (org-tickets--ticket-create :keyy "PROJ-1"))
  (should-error (org-tickets--ticket-create :summry "s"))
  (should-error (org-tickets--ticket-create :fix_version "1.0")))

(ert-deftest org-tickets-test--record-constructor-rejects-non-keyword-argument ()
  "A positional (non-keyword) argument is rejected."
  (should-error (org-tickets-test--point-create 1 2))
  (should-error (org-tickets-test--point-create 'x 1)))

(ert-deftest org-tickets-test--record-constructor-rejects-missing-value ()
  "A trailing keyword with no value signals an error."
  (let ((err (should-error (org-tickets-test--point-create :x 1 :y) :type 'error)))
    (should (string-match-p "missing value" (cadr err)))))

(ert-deftest org-tickets-test--record-error-message-lists-known-slots ()
  "The unknown-slot error names the record type and its valid slots,
so the message alone is enough to find the typo."
  (let ((err (should-error (org-tickets-test--point-create :bogus 1) :type 'error)))
    (should (string-match-p "org-tickets-test--point" (cadr err)))
    (should (string-match-p ":x" (cadr err)))
    (should (string-match-p ":y" (cadr err)))))

;;;; Object identity and printing

(ert-deftest org-tickets-test--record-is-a-record-object ()
  "Instances are genuine records, typed by the record name."
  (let ((p (org-tickets-test--point-create :x 1 :y 2)))
    (should (recordp p))
    (should (eq 'org-tickets-test--point (type-of p)))))

(ert-deftest org-tickets-test--record-equal-compares-by-value ()
  "`equal' compares records slot by slot; `eq' still means identity."
  (let ((a (org-tickets-test--point-create :x 1 :y 2))
        (b (org-tickets-test--point-create :x 1 :y 2))
        (c (org-tickets-test--point-create :x 1 :y 3)))
    (should (equal a b))
    (should-not (eq a b))
    (should-not (equal a c))))

(ert-deftest org-tickets-test--record-survives-print-and-read ()
  "A record round-trips through `prin1-to-string' and `read'."
  (let* ((p (org-tickets-test--point-create :x 1 :y "two"))
         (restored (read (prin1-to-string p))))
    (should (equal p restored))
    (should (= 1 (org-tickets-test--point-x restored)))
    (should (equal "two" (org-tickets-test--point-y restored)))))

;;;; The package's own record types

(ert-deftest org-tickets-test--ticket-record-behaves ()
  "`org-tickets--ticket' constructs, reads, writes and type-tests correctly."
  (let ((tk (org-tickets--ticket-create :key "PROJ-1" :type "Story"
                                     :summary "S" :labels '("a" "b"))))
    (should (org-tickets--ticket-p tk))
    (should (equal "PROJ-1" (org-tickets--ticket-key tk)))
    (should (equal "Story" (org-tickets--ticket-type tk)))
    (should (equal '("a" "b") (org-tickets--ticket-labels tk)))
    ;; Unsupplied slots default to nil.
    (should-not (org-tickets--ticket-description tk))
    (should-not (org-tickets--ticket-clear-labels tk))
    (setf (org-tickets--ticket-key tk) "PROJ-2")
    (should (equal "PROJ-2" (org-tickets--ticket-key tk)))
    (should (equal "S" (org-tickets--ticket-summary tk)))))

(ert-deftest org-tickets-test--doc-record-behaves ()
  "`org-tickets--doc' constructs, reads and type-tests correctly."
  (let* ((tk (org-tickets--ticket-create :key "PROJ-1" :type "Feature"))
         (blank (org-tickets--ticket-create :key "PROJ-2"))
         (doc (org-tickets--doc-create :tickets (list tk blank))))
    (should (org-tickets--doc-p doc))
    (should-not (org-tickets--ticket-p doc))
    (should (equal (list tk blank) (org-tickets--doc-tickets doc)))
    (should (equal (list tk) (org-tickets--doc-features doc)))
    (should-not (org-tickets--doc-children doc))))

(ert-deftest org-tickets-test--rate-limit-state-record-behaves ()
  "`org-tickets--rate-limit-state' defaults `in-flight' to 0 and is setf-able."
  (let ((state (org-tickets--rate-limit-state-create)))
    (should (org-tickets--rate-limit-state-p state))
    (should (= 0 (org-tickets--rate-limit-state-in-flight state)))
    (should-not (org-tickets--rate-limit-state-throttled-p state))
    (should-not (org-tickets--rate-limit-state-max-concurrent state))
    (setf (org-tickets--rate-limit-state-in-flight state)
          (1+ (org-tickets--rate-limit-state-in-flight state)))
    (should (= 1 (org-tickets--rate-limit-state-in-flight state)))
    (setf (org-tickets--rate-limit-state-throttled-p state) t)
    (should (org-tickets--rate-limit-state-throttled-p state))))

(ert-deftest org-tickets-test--package-record-types-are-distinct ()
  "The package's record predicates do not confuse its three types."
  (let ((tk (org-tickets--ticket-create))
        (doc (org-tickets--doc-create))
        (state (org-tickets--rate-limit-state-create)))
    (should-not (org-tickets--ticket-p doc))
    (should-not (org-tickets--ticket-p state))
    (should-not (org-tickets--doc-p tk))
    (should-not (org-tickets--doc-p state))
    (should-not (org-tickets--rate-limit-state-p tk))
    (should-not (org-tickets--rate-limit-state-p doc))))

(ert-deftest org-tickets-test--ticket-record-covers-every-declared-slot ()
  "Every `org-tickets--ticket' slot accepts a value and reads it back.
Guards against a slot being dropped or its accessor index drifting."
  (let* ((slots '(key type summary description fix-version labels
                     story-points blocks blocked-by parent attachments
                     sprint due-date marker clear-labels
                     clear-story-points))
         (args (apply #'append
                      (mapcar (lambda (slot)
                                (list (intern (concat ":" (symbol-name slot)))
                                      (format "value-of-%s" slot)))
                              slots)))
         (tk (apply #'org-tickets--ticket-create args)))
    (dolist (slot slots)
      (let ((accessor (intern (format "org-tickets--ticket-%s" slot))))
        (should (fboundp accessor))
        (should (equal (format "value-of-%s" slot) (funcall accessor tk)))))))

(ert-deftest org-tickets-test--alist-get-reads-symbol-keyed-json ()
  "A string key finds its value in a parsed (symbol-keyed) JSON response."
  (let ((api-response (org-tickets-test--json "{\"key\": \"PROJ-123\", \"id\": \"12345\"}")))
    (should (null (assoc "key" api-response)))
    (should (string= (org-tickets--alist-get "key" api-response) "PROJ-123"))))

(ert-deftest org-tickets-test--ensure-list-normalizes-shapes ()
  "Vectors become lists, lists pass through, nil stays nil, atoms are wrapped."
  (should (equal (org-tickets--ensure-list [1 2 3]) '(1 2 3)))
  (should (equal (org-tickets--ensure-list '((a . 1) (b . 2))) '((a . 1) (b . 2))))
  (should (equal (org-tickets--ensure-list nil) nil))
  (should (equal (org-tickets--ensure-list "x") '("x"))))

(ert-deftest org-tickets-test--ensure-list-wraps-dotted-pair ()
  "A dotted pair is one value, not a list, so it is wrapped whole."
  (should (equal (org-tickets--ensure-list '(a . b)) '((a . b)))))

(ert-deftest org-tickets-test--alist-get-missing-and-nil-values ()
  "A never-interned key and a key holding nil both read as nil."
  (let ((key (concat "org-tickets-test-" "never-interned-" "key-q7")))
    (should-not (intern-soft key))
    (should-not (org-tickets--alist-get key '((id . "1"))))
    (should-not (intern-soft key)))
  (should-not (org-tickets--alist-get
               "created" (org-tickets-test--json "{\"created\": null}"))))

(ert-deftest org-tickets-test--attachment-created-reads-timestamp ()
  "The creation timestamp comes from Jira metadata; absent means nil."
  (should (equal (org-tickets--attachment-created
                  (org-tickets-test--json
                   "{\"id\": \"1\", \"created\": \"2026-01-02T03:04:05.000+0000\"}"))
                 "2026-01-02T03:04:05.000+0000"))
  (should-not (org-tickets--attachment-created
               (org-tickets-test--json "{\"id\": \"1\"}"))))

(provide 'org-tickets-test-record)
;;; org-tickets-test-record.el ends here
