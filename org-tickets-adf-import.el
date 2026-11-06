;;; org-tickets-adf-import.el --- ADF-to-org conversion for org-tickets  -*- lexical-binding: t; -*-

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

;; ADF-to-org conversion for org-tickets.
;; Structured ADF (Atlassian Document Format) importer, built as three
;; layers: inline rendering, block rendering, and list layout with
;; string indents.

;;; Code:

(require 'org-tickets-core)

(defvar org-tickets--adf-attachment-id-map nil
  "Alist mapping Jira attachment IDs to filenames.
Dynamically bound during ADF import to resolve mediaInline/media
nodes to [[attachment:filename]] org links.
Each element is (ID . FILENAME).")

(defun org-tickets--resolve-media-to-attachment (attrs)
  "Resolve ADF media ATTRS to an [[attachment:filename]] link.
Looks up the media ID in `org-tickets--adf-attachment-id-map', then
falls back to the alt attribute (which Jira sets to the filename)."
  (let* ((id (org-tickets--alist-get "id" attrs))
         (alt (org-tickets--alist-get "alt" attrs))
         (filename (when id (cdr (assoc id org-tickets--adf-attachment-id-map)))))
    (cond
     (filename (format "[[attachment:%s]]" filename))
     (alt (format "[[attachment:%s]]" alt))
     (t (format "[media: %s]" (or id "unknown"))))))

(defun org-tickets--ensure-list (value)
  "Return VALUE as a proper list.
JSON arrays are lists in this codebase, but tolerate vectors from
other parser configurations."
  (cond
   ((null value) nil)
   ((vectorp value) (append value nil))
   ((proper-list-p value) value)
   (t (list value))))

(defun org-tickets--adf-type (node)
  "Return NODE's ADF type string, or nil when NODE has none."
  (and (consp node) (org-tickets--alist-get "type" node)))

(defun org-tickets--adf-node-content (node)
  "Return NODE's content as a proper list."
  (org-tickets--ensure-list (org-tickets--alist-get "content" node)))

(defun org-tickets--adf-attrs (node)
  "Return NODE's ADF attrs alist, or nil when NODE has none."
  (org-tickets--alist-get "attrs" node))

;;;; Inline Layer

(defun org-tickets--adf-apply-marks (text marks)
  "Wrap TEXT in org markup for each ADF mark in MARKS.
Supported: code, strong, em/emphasis, underline, strike, subsup, link."
  (let ((result text))
    (dolist (mark marks result)
      (pcase (org-tickets--alist-get "type" mark)
        ("code" (setq result (format "~%s~" result)))
        ("strong" (setq result (format "*%s*" result)))
        ((or "em" "emphasis") (setq result (format "/%s/" result)))
        ("underline" (setq result (format "_%s_" result)))
        ("strike" (setq result (format "+%s+" result)))
        ("subsup"
         (let ((marker (if (equal (org-tickets--alist-get
                                   "type" (org-tickets--adf-attrs mark))
                                  "sup")
                           "^" "_")))
           (setq result (format "%s{%s}" marker result))))
        ("link"
         (let ((href (org-tickets--alist-get
                      "href" (org-tickets--adf-attrs mark))))
           (when href
             (setq result (format "[[%s][%s]]" href result)))))))))

(defun org-tickets--adf-inline-to-org (node)
  "Render one inline ADF NODE to an org string."
  (pcase (org-tickets--adf-type node)
    ("text" (org-tickets--adf-apply-marks
             (or (org-tickets--alist-get "text" node) "")
             (org-tickets--ensure-list (org-tickets--alist-get "marks" node))))
    ("hardBreak" "\n")
    ("mediaInline" (org-tickets--resolve-media-to-attachment
                    (org-tickets--adf-attrs node)))
    ((or "emoji" "mention")
     (or (org-tickets--alist-get "text" (org-tickets--adf-attrs node)) ""))
    ("inlineCard"
     (let ((url (org-tickets--alist-get "url" (org-tickets--adf-attrs node))))
       (if url (format "[[%s]]" url) "")))
    (_ (org-tickets--adf-inlines-to-org (org-tickets--adf-node-content node)))))

(defun org-tickets--adf-inlines-to-org (nodes)
  "Render inline NODES to one org string."
  (mapconcat #'org-tickets--adf-inline-to-org nodes ""))

;;;; Block Layer

(defun org-tickets--adf-heading-to-org (node)
  "Render an ADF heading NODE as an org headline.
Level N becomes N+2 stars (h1 is `***'), the inverse of
`org-tickets--convert-to-adf-headline'.  Line breaks in the title become
spaces so the rest of the title does not fall into the section."
  (let* ((attrs (org-tickets--adf-attrs node))
         (level (or (org-tickets--alist-get "level" attrs) 1)))
    (concat (make-string (+ level 2) ?*) " "
            (string-replace "\n" " " (org-tickets--adf-inlines-to-org
                                     (org-tickets--adf-node-content node))))))

(defun org-tickets--adf-empty-heading-p (node)
  "Non-nil when NODE is a heading with no content.
An empty org headline cannot survive description trimming, and there is
nothing in it to keep."
  (and (equal (org-tickets--adf-type node) "heading")
       (null (org-tickets--adf-node-content node))))

(defun org-tickets--escape-headline-lines (text)
  "Prefix headline-looking lines in TEXT with a space.
A description line matching `^\\*+ ' would otherwise become a real
org heading, corrupting document structure and truncating the
description on the next parse."
  (replace-regexp-in-string "^\\(\\*+ \\)" " \\1" text))

(defun org-tickets--adf-top-block-to-org (node)
  "Render top-level block NODE; only heading nodes may emit org headlines."
  (let ((text (org-tickets--adf-block-to-org node)))
    (if (equal (org-tickets--adf-type node) "heading")
        text
      (org-tickets--escape-headline-lines text))))

(defun org-tickets--adf-code-block-to-org (node)
  "Render an ADF codeBlock NODE as an org src block."
  (let* ((attrs (org-tickets--adf-attrs node))
         (lang (org-tickets--alist-get "language" attrs)))
    (concat "#+BEGIN_SRC" (if lang (concat " " lang) "") "\n"
            (org-tickets--adf-inlines-to-org (org-tickets--adf-node-content node))
            "\n#+END_SRC")))

(defun org-tickets--adf-blockquote-to-org (node)
  "Render an ADF blockquote NODE as an org quote block."
  (concat "#+BEGIN_QUOTE\n"
          (org-tickets--adf-blocks-to-org (org-tickets--adf-node-content node))
          "\n#+END_QUOTE"))

(defun org-tickets--adf-table-cell-to-org (cell)
  "Flatten CELL to a single line; escape | so the org table stays valid."
  (replace-regexp-in-string
   "|" "\\\\vert{}"
   (replace-regexp-in-string
    "\n" " " (org-tickets--adf-blocks-to-org (org-tickets--adf-node-content cell)))))

(defun org-tickets--adf-table-row-to-org (row)
  "Render one ADF tableRow ROW as an org table row."
  (concat "| "
          (mapconcat #'org-tickets--adf-table-cell-to-org
                     (org-tickets--adf-node-content row) " | ")
          " |"))

(defun org-tickets--org-table-rule-row (ncols)
  "Return an org table rule row string for NCOLS columns.
The row begins with \"|-\" so org parses it as an hline, not a data row."
  (concat "|" (mapconcat (lambda (_) "---")
                         (make-list (max 1 (or ncols 1)) nil)
                         "+")
          "|"))

(defun org-tickets--adf-table-row-is-header-p (row)
  "Non-nil when every cell in ADF tableRow ROW is a tableHeader node."
  (let ((cells (org-tickets--adf-node-content row)))
    (and cells
         (seq-every-p (lambda (cell)
                        (equal (org-tickets--adf-type cell) "tableHeader"))
                      cells))))

(defun org-tickets--adf-table-to-org (node)
  "Render an ADF table NODE as an org table.
When the first row is a header row (all tableHeader cells), emit an org
rule row after it so the exported org re-parses as a header table,
keeping pull+push symmetric with the exporter."
  (let* ((rows (org-tickets--adf-node-content node))
         (ncols (and rows (length (org-tickets--adf-node-content (car rows)))))
         (header-p (and rows (org-tickets--adf-table-row-is-header-p (car rows))))
         (lines (mapcar #'org-tickets--adf-table-row-to-org rows)))
    (when (and header-p (cdr lines))
      ;; Splice a rule row (|-...) after the header so org sees an hline.
      (setq lines (cons (car lines)
                        (cons (org-tickets--org-table-rule-row ncols)
                              (cdr lines)))))
    (mapconcat #'identity lines "\n")))

(defun org-tickets--adf-media-single-to-org (node)
  "Render ADF mediaSingle/mediaGroup NODE to attachment links."
  (mapconcat (lambda (media)
               (if (equal (org-tickets--adf-type media) "media")
                   (org-tickets--resolve-media-to-attachment
                    (org-tickets--adf-attrs media))
                 ""))
             (org-tickets--adf-node-content node) ""))

;;;; List Layout

(defun org-tickets--indent-lines (text indent &optional skip-first)
  "Prefix each line of TEXT with INDENT.
When SKIP-FIRST is non-nil, the first line is left as-is (it follows
a list marker that already provides the indentation)."
  (let ((lines (split-string text "\n")))
    (if skip-first
        (mapconcat #'identity
                   (cons (car lines)
                         (mapcar (lambda (l) (concat indent l)) (cdr lines)))
                   "\n")
      (mapconcat (lambda (l) (concat indent l)) lines "\n"))))

(defun org-tickets--adf-list-item-to-org (item cont-indent)
  "Render listItem ITEM.
The first block continues the marker line; every further block (and
every continuation line) is prefixed with CONT-INDENT.  Nested lists
receive CONT-INDENT as their base indent."
  (let ((first t)
        (parts nil))
    (dolist (block (org-tickets--adf-node-content item))
      (let ((plain (not (member (org-tickets--adf-type block)
                                '("bulletList" "orderedList")))))
        (push (concat (cond (first "")
                            (plain "\n\n")
                            (t "\n"))
                      (org-tickets--adf-item-block-to-org block cont-indent first))
              parts)
        (setq first nil)))
    (apply #'concat (nreverse parts))))

(defun org-tickets--adf-item-block-to-org (block cont-indent first)
  "Render BLOCK of a listItem, indented by CONT-INDENT.
FIRST non-nil leaves a non-list block's first line unindented."
  (pcase (org-tickets--adf-type block)
    ("bulletList" (org-tickets--adf-list-to-org block cont-indent nil))
    ("orderedList" (org-tickets--adf-list-to-org block cont-indent t))
    (_ (org-tickets--indent-lines
        (org-tickets--adf-block-to-org block) cont-indent first))))

(defun org-tickets--adf-list-to-org (node indent ordered-p)
  "Render an ADF list NODE.
INDENT prefixes each marker line; ORDERED-P selects \"N. \" markers,
numbered from the node's \"order\" attribute (default 1).
Continuation indent is INDENT plus the marker's own width, so org
sees nested content as belonging to the item."
  (let* ((attrs (org-tickets--adf-attrs node))
         (idx (1- (or (and ordered-p (org-tickets--alist-get "order" attrs))
                      1))))
    (mapconcat
     (lambda (item)
       (setq idx (1+ idx))
       (let* ((marker (if ordered-p (format "%d. " idx) "- "))
              (cont-indent (concat indent (make-string (length marker) ?\s))))
         (concat indent marker
                 (org-tickets--adf-list-item-to-org item cont-indent))))
     (org-tickets--adf-node-content node) "\n")))

(defun org-tickets--adf-block-to-org (node)
  "Render one block-level ADF NODE to org text (no trailing newline)."
  (pcase (org-tickets--adf-type node)
    ("paragraph" (org-tickets--adf-inlines-to-org (org-tickets--adf-node-content node)))
    ("heading" (org-tickets--adf-heading-to-org node))
    ("bulletList" (org-tickets--adf-list-to-org node "" nil))
    ("orderedList" (org-tickets--adf-list-to-org node "" t))
    ("codeBlock" (org-tickets--adf-code-block-to-org node))
    ("blockquote" (org-tickets--adf-blockquote-to-org node))
    ("rule" "-----")
    ("table" (org-tickets--adf-table-to-org node))
    ((or "mediaSingle" "mediaGroup") (org-tickets--adf-media-single-to-org node))
    ((or "panel" "expand") (org-tickets--adf-blocks-to-org
                            (org-tickets--adf-node-content node)))
    (_ (org-tickets--adf-inlines-to-org (org-tickets--adf-node-content node)))))

(defun org-tickets--adf-blocks-to-org (nodes)
  "Render block NODES joined by single newlines."
  (mapconcat #'org-tickets--adf-block-to-org nodes "\n"))

;;;; Entry Point

(defun org-tickets--parse-adf-description (adf)
  "Parse Jira ADF description ADF into Org text.
Returns nil when ADF is nil or has no content.  Accepts both a full
doc node and a bare content wrapper."
  (when adf
    (let* ((content (seq-remove #'org-tickets--adf-empty-heading-p
                                (org-tickets--adf-node-content adf)))
           (text (mapconcat #'org-tickets--adf-top-block-to-org content "\n\n")))
      (and (> (length text) 0) text))))

(provide 'org-tickets-adf-import)
;;; org-tickets-adf-import.el ends here
