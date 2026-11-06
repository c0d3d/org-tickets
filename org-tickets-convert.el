;;; org-tickets-convert.el --- Conversion functions for org-tickets  -*- lexical-binding: t; -*-

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

;; Conversion functions for org-tickets.
;; Contains ADF building functions.

;;; Code:

(require 'org-tickets-core)

(defvar org-tickets--adf-attachments nil
  "Attachment metadata for current ADF conversion.
Dynamically bound during `org-tickets--build-adf-description'.
Each element is an alist with keys \"id\", \"filename\", and
\"mediaApiFileId\" (the Media Services UUID Jira requires in ADF
media nodes).")

;;;; ADF Conversion Helpers

(defun org-tickets--adf-text-node (text &optional mark-type)
  "Return a one-element list holding an ADF text node for TEXT.
Returns nil when TEXT is nil or empty — the ADF schema forbids empty
text nodes and Jira rejects documents containing them.
When MARK-TYPE is non-nil, attach a single mark of that type."
  (when (and text (> (length text) 0))
    (list (append (list (cons "type" "text")
                        (cons "text" text))
                  (when mark-type
                    (list (cons "marks"
                                (list (list (cons "type" mark-type))))))))))

(defun org-tickets--adf-node (type &optional attrs content)
  "Build one ADF node alist of TYPE.
ATTRS (alist) and CONTENT (list of nodes) are included only when
non-nil, matching the ADF schema's optional fields."
  (append (list (cons "type" type))
          (when attrs (list (cons "attrs" attrs)))
          (when content (list (cons "content" content)))))

(defun org-tickets--adf-add-mark (nodes mark)
  "Return NODES with MARK appended to every text node's marks.
Non-text nodes (hardBreak, mediaInline) pass through unchanged."
  (mapcar
   (lambda (node)
     (if (equal (cdr (assoc "type" node)) "text")
         (let ((marks (cdr (assoc "marks" node)))
               (clean (seq-remove
                       (lambda (cell)
                         (and (consp cell) (equal (car cell) "marks")))
                       node)))
           (append clean (list (cons "marks" (append marks (list mark))))))
       node))
   nodes))

(defun org-tickets--adf-post-blank-spaces (element)
  "Return a string of spaces matching ELEMENT's :post-blank property.
Org stores the whitespace following an inline object here, not in the
adjacent text, so converters must re-emit it."
  (make-string (or (org-element-property :post-blank element) 0) ?\s))

(defun org-tickets--convert-literal-text (element value)
  "Return an ADF text node for literal VALUE plus ELEMENT's post-blank space.
For inline elements carrying no mark, VALUE and the trailing :post-blank
space share a single unmarked text node.  Contrast
`org-tickets--convert-value-code-marked', which must keep the space out of
the marked node so the code styling does not leak onto it."
  (org-tickets--adf-text-node
   (concat (or value "") (org-tickets--adf-post-blank-spaces element))))

(defun org-tickets--adf-code-block (value &optional language)
  "Return a one-element list holding an ADF codeBlock for VALUE.
LANGUAGE defaults to \"text\".  Interior newlines are preserved; the
structural trailing newline is stripped.  Empty code produces a
codeBlock with no content (valid ADF)."
  (let ((text (replace-regexp-in-string "\n+\\'" "" (or value ""))))
    (list (org-tickets--adf-node "codeBlock"
                              (list (cons "language" (or language "text")))
                              (org-tickets--adf-text-node text)))))

(defun org-tickets--convert-inline-marked (element mark-type)
  "Convert ELEMENT's contents to ADF inline nodes carrying MARK-TYPE.
Nested markup is preserved: the mark is layered onto every inner text
node (so /italic/ inside *bold* carries both em and strong), and
non-text nodes like hardBreak pass through.  The trailing space org
stores in :post-blank is re-emitted as an unmarked text node."
  (let ((inner (org-tickets--build-inline-nodes (org-element-contents element)))
        (post (org-tickets--adf-post-blank-spaces element)))
    (append (org-tickets--adf-add-mark inner (list (cons "type" mark-type)))
            (org-tickets--adf-text-node post))))

(defun org-tickets--convert-to-adf-nil (_element)
  "Convert org _ELEMENT (type nil) to ADF content."
  nil)

(defun org-tickets--convert-to-adf-org-data (element)
  "Convert org ELEMENT (type org-data) to ADF content."
  (mapcan #'org-tickets--convert-to-adf-content (org-element-contents element)))

(defun org-tickets--convert-to-adf-section (element)
  "Convert org ELEMENT (type section) to ADF content."
  (mapcan #'org-tickets--convert-to-adf-content (org-element-contents element)))

(defun org-tickets--convert-to-adf-headline (element)
  "Convert org ELEMENT (type headline) to an ADF heading and its body.
Org level 3 (`***') is h1 and each extra star one level deeper, clamped
to h1..h6, so headings sit below the ticket headings that hold them.
A COMMENT headline is dropped with its subtree, like comment blocks."
  (let ((level (max 1 (min 6 (- (org-element-property :level element) 2)))))
    (unless (org-element-property :commentedp element)
      (cons (org-tickets--adf-node
             "heading" (list (cons "level" level))
             (org-tickets--build-inline-nodes
              (org-element-property :title element)))
            (mapcan #'org-tickets--convert-to-adf-content
                    (org-element-contents element))))))

(defun org-tickets--string-to-adf-text-nodes (text last-child-p)
  "Convert a plain-text run TEXT into ADF inline nodes.
Internal newlines become hardBreak nodes so multi-line paragraphs keep
their line structure in Jira.  A line after a newline loses its leading
indentation: that is org layout (e.g. a list item's continuation), and
pushed as text Jira would show it and each pull would indent it again.
When LAST-CHILD-P, the trailing newline org stores as the paragraph
terminator is dropped rather than turned into a hardBreak.  Empty
segments produce no text node."
  (when last-child-p
    (setq text (replace-regexp-in-string "\n+\\'" "" text)))
  (let ((segments (split-string text "\n"))
        (nodes nil)
        (continuation-p nil))
    (while segments
      (let ((seg (pop segments)))
        (dolist (node (org-tickets--adf-text-node
                       (if continuation-p (string-trim-left seg) seg)))
          (push node nodes))
        (setq continuation-p t)
        ;; A remaining segment means this newline is an internal soft break.
        (when segments
          (push (org-tickets--adf-node "hardBreak") nodes))))
    (nreverse nodes)))

(defun org-tickets--build-inline-nodes (contents)
  "Build ADF inline nodes from CONTENTS, a list of org objects and strings.
Internal newlines in plain-text runs become hardBreak nodes; the
structural trailing newline on the final run is dropped.  Leading
whitespace of the first run is org layout (e.g. a list item's second
paragraph) and is dropped too."
  (let ((last-idx (1- (length contents)))
        (idx -1))
    (mapcan (lambda (elem)
              (setq idx (1+ idx))
              (if (stringp elem)
                  (org-tickets--string-to-adf-text-nodes
                   (let ((text (substring-no-properties elem)))
                     (if (= idx 0) (string-trim-left text) text))
                   (= idx last-idx))
                (org-tickets--convert-to-adf-content elem)))
            contents)))

(defun org-tickets--standalone-attachment-link (element)
  "Return the sole attachment: link in paragraph ELEMENT, or nil.
A paragraph qualifies when its only non-whitespace content is a single
attachment: link — the case Jira's own editor renders as a block media
node rather than an inline chip."
  (let ((significant
         (seq-remove (lambda (elem)
                       (and (stringp elem)
                            (string-match-p "\\`[ \t\n]*\\'" elem)))
                     (org-element-contents element))))
    (when (and (= (length significant) 1)
               (eq (org-element-type (car significant)) 'link)
               (string= (org-element-property :type (car significant))
                        "attachment"))
      (car significant))))

(defun org-tickets--convert-standalone-attachment (element)
  "Convert paragraph ELEMENT to a mediaSingle when it is a lone attachment link.
Returns nil unless ELEMENT holds only an attachment: link whose media
UUID is known; the caller then falls back to an ordinary paragraph,
whose link converter degrades to plain text."
  (let* ((link (org-tickets--standalone-attachment-link element))
         (uuid (and link (org-tickets--attachment-media-uuid
                          (org-element-property :path link)
                          org-tickets--adf-attachments))))
    (when uuid
      (list (org-tickets--adf-node
             "mediaSingle"
             (list (cons "layout" "center"))
             (list (org-tickets--adf-node
                    "media" (org-tickets--adf-media-attrs uuid))))))))

(defun org-tickets--convert-to-adf-paragraph (element)
  "Convert org ELEMENT (type paragraph) to ADF content.
A paragraph holding only an attachment: link becomes a block
mediaSingle, which Jira displays in full (e.g. an inline image).
Otherwise internal newlines become hardBreak nodes; org's structural
trailing newline is dropped so it does not render as a spurious blank
line in Jira (e.g. inside a list item)."
  (or (org-tickets--convert-standalone-attachment element)
      (let ((para-content (org-tickets--build-inline-nodes
                           (org-element-contents element))))
        (when para-content
          (list (org-tickets--adf-node "paragraph" nil para-content))))))

(defun org-tickets--convert-to-adf-bold (element)
  "Convert org ELEMENT (type bold) to an ADF text node with a strong mark."
  (org-tickets--convert-inline-marked element "strong"))

(defun org-tickets--convert-to-adf-italic (element)
  "Convert org ELEMENT (type italic) to an ADF text node with an em mark."
  (org-tickets--convert-inline-marked element "em"))

(defun org-tickets--convert-to-adf-strike-through (element)
  "Convert org ELEMENT (type strike-through) to a strike-marked text node."
  (org-tickets--convert-inline-marked element "strike"))

(defun org-tickets--convert-to-adf-underline (element)
  "Convert org ELEMENT (type underline) to an underline-marked text node."
  (org-tickets--convert-inline-marked element "underline"))

(defun org-tickets--convert-value-code-marked (element)
  "Convert an inline ELEMENT with a :value to a code-marked text node.
The code mark covers only the value; the trailing space org stores in
:post-blank is re-emitted as a separate unmarked text node so Jira does
not render the code styling over the trailing space."
  (append (org-tickets--adf-text-node
           (or (org-element-property :value element) "") "code")
          (org-tickets--adf-text-node
           (org-tickets--adf-post-blank-spaces element))))

(defun org-tickets--convert-to-adf-code (element)
  "Convert org ELEMENT (type code or verbatim) to a code-marked text node."
  (org-tickets--convert-value-code-marked element))

(defun org-tickets--attachment-media-uuid (filename attachments)
  "Return the media UUID for FILENAME in ATTACHMENTS, or nil.
Jira renders ADF media nodes only when their id is the Media Services
UUID (the attachment's mediaApiFileId).  The numeric REST attachment id
produces a permanently broken embed, so callers must fall back to plain
text when no UUID is available."
  (let ((att (seq-find (lambda (a)
                         (equal (org-tickets--alist-get "filename" a) filename))
                       attachments)))
    (when att (org-tickets--alist-get "mediaApiFileId" att))))

(defun org-tickets--adf-media-attrs (uuid)
  "Return ADF media node attrs referencing attachment media UUID."
  (list (cons "id" uuid)
        (cons "collection" "")
        (cons "type" "file")))

(defun org-tickets--convert-attachment-link (element)
  "Convert an attachment: link ELEMENT to ADF inline content.
Emits a mediaInline node (a small file chip) when the attachment's
media UUID is known, otherwise plain text."
  (let* ((filename (org-element-property :path element))
         (uuid (org-tickets--attachment-media-uuid
                filename org-tickets--adf-attachments))
         (post-blank (org-tickets--adf-post-blank-spaces element)))
    (if uuid
        (append (list (org-tickets--adf-node
                       "mediaInline" (org-tickets--adf-media-attrs uuid)))
                (org-tickets--adf-text-node post-blank))
      (let ((desc (car (seq-filter #'stringp
                                   (org-element-contents element)))))
        (org-tickets--adf-text-node (concat (or desc filename) post-blank))))))

(defun org-tickets--convert-to-adf-link (element)
  "Convert org ELEMENT (type link) to ADF content.
attachment: links resolve to media nodes (see
`org-tickets--convert-attachment-link').  Regular links get a link mark
layered onto the description nodes, preserving nested formatting;
bare links fall back to the URL."
  (if (string= (org-element-property :type element) "attachment")
      (org-tickets--convert-attachment-link element)
    (let* ((path (or (org-element-property :raw-link element)
                     (org-element-property :path element)))
           (inner (org-tickets--build-inline-nodes
                   (org-element-contents element)))
           (nodes (or inner (org-tickets--adf-text-node path)))
           (link-mark (list (cons "type" "link")
                            (cons "attrs" (list (cons "href" path))))))
      (append (org-tickets--adf-add-mark nodes link-mark)
              (org-tickets--adf-text-node
               (org-tickets--adf-post-blank-spaces element))))))

(defun org-tickets--ordered-list-start (element)
  "Return the number ordered plain-list ELEMENT starts at, or nil.
That is the first item's [@N] counter, else its bullet's number; nil
for a non-numeric bullet without a counter (an alphabetical list)."
  (let* ((item (car (org-element-contents element)))
         (bullet (org-element-property :bullet item)))
    (or (org-element-property :counter item)
        (and (string-match-p "\\`[0-9]" bullet)
             (string-to-number bullet)))))

(defun org-tickets--convert-to-adf-list (element)
  "Convert org ELEMENT (type plain-list) to an ADF list node.
An ordered list not starting at 1 carries its start as the \"order\"
attribute."
  (let* ((ordered-p (eq (org-element-property :type element) 'ordered))
         (start (and ordered-p (org-tickets--ordered-list-start element))))
    (list (org-tickets--adf-node
           (if ordered-p "orderedList" "bulletList")
           (and start (/= start 1) (list (cons "order" start)))
           (mapcan #'org-tickets--convert-to-adf-list-item
                   (org-element-contents element))))))

(defun org-tickets--convert-to-adf-item (element)
  "Convert org ELEMENT (type item) to ADF content."
  (mapcan (lambda (elem)
            (org-tickets--convert-to-adf-content elem))
          (org-element-contents element)))

(defun org-tickets--convert-to-adf-list-item (element)
  "Convert org ELEMENT (type item) to an ADF listItem.
Contents, nested lists included, keep their document order."
  (let ((blocks (mapcan #'org-tickets--convert-to-adf-content
                        (org-element-contents element))))
    (when blocks
      (list (org-tickets--adf-node "listItem" nil blocks)))))

(defun org-tickets--convert-to-adf-line-break (_element)
  "Convert org _ELEMENT (type line-break, from `\\\\') to an ADF hardBreak."
  (list (org-tickets--adf-node "hardBreak")))

(defun org-tickets--convert-to-adf-entity (element)
  "Convert org ELEMENT (type entity, e.g. \\alpha) to its UTF-8 text."
  (org-tickets--convert-literal-text
   element (or (org-element-property :utf-8 element)
               (org-element-property :name element))))

(defun org-tickets--convert-to-adf-timestamp (element)
  "Convert org ELEMENT (type timestamp) to its literal raw value as text."
  (org-tickets--convert-literal-text
   element (org-element-property :raw-value element)))

(defun org-tickets--convert-to-adf-inline-src-block (element)
  "Convert org ELEMENT (type inline-src-block) to a code-marked text node."
  (org-tickets--convert-value-code-marked element))

(defun org-tickets--convert-to-adf-statistics-cookie (element)
  "Convert org ELEMENT (type statistics-cookie, e.g. [1/2]) to literal text."
  (org-tickets--convert-literal-text
   element (org-element-property :value element)))

(defun org-tickets--convert-to-adf-latex-fragment (element)
  "Convert org ELEMENT (type latex-fragment) to its literal source text."
  (org-tickets--convert-literal-text
   element (org-element-property :value element)))

(defun org-tickets--convert-to-adf-export-snippet (element)
  "Convert org ELEMENT (type export-snippet) to a code-marked text node."
  (org-tickets--convert-value-code-marked element))

(defun org-tickets--convert-to-adf-example-block (element)
  "Convert org ELEMENT (type example-block) to an ADF codeBlock."
  (org-tickets--adf-code-block (org-element-property :value element)))

(defun org-tickets--convert-to-adf-fixed-width (element)
  "Convert org ELEMENT (type fixed-width) to an ADF codeBlock."
  (org-tickets--adf-code-block (org-element-property :value element)))

(defun org-tickets--convert-to-adf-latex-environment (element)
  "Convert org ELEMENT (type latex-environment) to an ADF codeBlock."
  (org-tickets--adf-code-block (org-element-property :value element) "latex"))

(defun org-tickets--convert-to-adf-export-block (element)
  "Convert org ELEMENT (type export-block) to an ADF codeBlock.
Uses the export backend (e.g. HTML) as the code language."
  (let ((type (org-element-property :type element)))
    (org-tickets--adf-code-block (org-element-property :value element)
                              (and type (downcase type)))))

(defun org-tickets--convert-to-adf-horizontal-rule (_element)
  "Convert org _ELEMENT (type horizontal-rule) to an ADF rule node."
  (list (org-tickets--adf-node "rule")))

(defun org-tickets--convert-to-adf-quote-block (element)
  "Convert org ELEMENT (type quote-block) to an ADF blockquote."
  (let ((inner (mapcan #'org-tickets--convert-to-adf-content
                       (org-element-contents element))))
    (when inner
      (list (org-tickets--adf-node "blockquote" nil inner)))))

(defun org-tickets--convert-to-adf-verse-block (element)
  "Convert org ELEMENT (type verse-block) to a paragraph preserving lines."
  (let ((nodes (org-tickets--build-inline-nodes (org-element-contents element))))
    (when nodes
      (list (org-tickets--adf-node "paragraph" nil nodes)))))

(defun org-tickets--convert-to-adf-script (element marker subsup-type)
  "Convert sub/superscript ELEMENT to ADF inline nodes.
MARKER is the source character (\"_\" for subscript, \"^\" for
superscript); SUBSUP-TYPE is the ADF subsup mark type (\"sub\" or
\"sup\").  Braced forms like `H_{2}O' get a real subsup mark.  Org
also parses unbraced tokens like `26_02' or `x^2' as sub/superscripts,
which are usually identifiers, so those become literal source text."
  (if (org-element-property :use-brackets-p element)
      (append (org-tickets--adf-add-mark
               (org-tickets--build-inline-nodes (org-element-contents element))
               (list (cons "type" "subsup")
                     (list "attrs" (cons "type" subsup-type))))
              (org-tickets--adf-text-node
               (org-tickets--adf-post-blank-spaces element)))
    (org-tickets--convert-to-adf-script-literal element marker)))

(defun org-tickets--convert-to-adf-script-literal (element marker)
  "Convert unbraced sub/superscript ELEMENT to literal ADF text.
Reconstruct the source: MARKER, the content, and the trailing space
stored in :post-blank."
  (let ((inner (mapconcat (lambda (elem)
                            (if (stringp elem)
                                (substring-no-properties elem)
                              (let ((nodes (org-tickets--convert-to-adf-content elem)))
                                (mapconcat (lambda (node)
                                             (or (cdr (assoc "text" node)) ""))
                                           nodes ""))))
                          (org-element-contents element) "")))
    (org-tickets--adf-text-node
     (concat marker inner (org-tickets--adf-post-blank-spaces element)))))

(defun org-tickets--convert-to-adf-subscript (element)
  "Convert org ELEMENT (type subscript) to ADF inline nodes."
  (org-tickets--convert-to-adf-script element "_" "sub"))

(defun org-tickets--convert-to-adf-superscript (element)
  "Convert org ELEMENT (type superscript) to ADF inline nodes."
  (org-tickets--convert-to-adf-script element "^" "sup"))

(defun org-tickets--convert-to-adf-macro (element)
  "Convert org ELEMENT (type macro) to ADF content.
Defined macros expand to their text; undefined macros produce no node
at all — Jira rejects empty text nodes."
  (let* ((macro-key (or (org-element-property :key element)
                        (org-element-property :macro-name element)))
         (templates (default-value 'org-macro-templates))
         (template (assoc macro-key templates))
         (value (and template (org-macro-expand element templates))))
    (org-tickets--convert-literal-text
     element (and (stringp value) (substring-no-properties value)))))

(defun org-tickets--convert-to-adf-plain-text (element)
  "Convert org ELEMENT (type plain-text) to ADF content."
  (org-tickets--adf-text-node (substring-no-properties element)))

(defun org-tickets--convert-to-adf-src-block (element)
  "Convert org ELEMENT (type src-block) to ADF content."
  (org-tickets--adf-code-block (or (org-element-property :value element) "")
                            (or (org-element-property :language element) "text")))

(defun org-tickets--table-has-header-p (element)
  "Non-nil when org table ELEMENT contains a rule row (|---|).
Org marks a header by separating it with a rule; a table without one
has no header row."
  (seq-some (lambda (row) (eq (org-element-property :type row) 'rule))
            (org-element-contents element)))

(defun org-tickets--convert-to-adf-table (element &optional _is-header)
  "Convert org ELEMENT (type table) to ADF content.
Row 0 becomes a header row only when the table has a rule separator."
  (let* ((has-header (org-tickets--table-has-header-p element))
         (rows (seq-remove (lambda (row)
                             (or (eq (org-element-property :type row) 'rule)
                                 (null (org-element-contents row))))
                           (org-element-contents element)))
         (row-index 0))
    (list (org-tickets--adf-node
           "table"
           (list (cons "layout" "default"))
           (mapcan (lambda (row)
                     (let ((result (org-tickets--convert-to-adf-content
                                    row (and has-header (= row-index 0)))))
                       (setq row-index (1+ row-index))
                       result))
                   rows)))))

(defun org-tickets--convert-to-adf-table-row (element &optional is-header)
  "Convert org ELEMENT (type table-row) to ADF content.
IS-HEADER is passed to child table cells."
  (let ((cells (org-element-contents element)))
    (when cells
      (list (list (cons "type" "tableRow")
                  (cons "content" (mapcan (lambda (cell)
                                            (org-tickets--convert-to-adf-content cell is-header))
                                          cells)))))))

(defun org-tickets--convert-to-adf-table-cell (element &optional is-header)
  "Convert org ELEMENT (type table-cell) to ADF content.
IS-HEADER selects the tableHeader node type per the ADF schema."
  (let* ((text-nodes (mapcan (lambda (elem)
                               (if (stringp elem)
                                   (let ((text (substring-no-properties elem)))
                                     (when (> (length (string-trim text)) 0)
                                       (org-tickets--adf-text-node
                                        (string-trim-right text))))
                                 (org-tickets--convert-to-adf-content elem is-header)))
                             (org-element-contents element)))
         (paragraph (if text-nodes
                        (org-tickets--adf-node "paragraph" nil text-nodes)
                      (org-tickets--adf-node "paragraph"))))
    (list (org-tickets--adf-node (if is-header "tableHeader" "tableCell")
                              nil
                              (list paragraph)))))

(defun org-tickets--convert-to-adf-default (element)
  "Convert org ELEMENT (unknown type) to ADF content."
  (mapcan #'org-tickets--convert-to-adf-content
          (org-element-contents element)))

(defun org-tickets--convert-to-adf-content (element &optional is-header)
  "Convert org ELEMENT to Atlassian Document Format (ADF) content.
IS-HEADER is an optional flag indicating if element is in a table header row.
Returns an ADF content node (list with type and content properties)."
  (pcase (org-element-type element)
    (`nil (org-tickets--convert-to-adf-nil element))
    (`org-data (org-tickets--convert-to-adf-org-data element))
    (`section (org-tickets--convert-to-adf-section element))
    (`headline (org-tickets--convert-to-adf-headline element))
    (`paragraph (org-tickets--convert-to-adf-paragraph element))
    (`bold (org-tickets--convert-to-adf-bold element))
    (`italic (org-tickets--convert-to-adf-italic element))
    ((or `code `verbatim) (org-tickets--convert-to-adf-code element))
    (`link (org-tickets--convert-to-adf-link element))
    (`plain-list (org-tickets--convert-to-adf-list element))
    (`item (org-tickets--convert-to-adf-item element))
    (`line-break (org-tickets--convert-to-adf-line-break element))
    (`subscript (org-tickets--convert-to-adf-subscript element))
    (`superscript (org-tickets--convert-to-adf-superscript element))
    (`strike-through (org-tickets--convert-to-adf-strike-through element))
    (`underline (org-tickets--convert-to-adf-underline element))
    (`entity (org-tickets--convert-to-adf-entity element))
    (`timestamp (org-tickets--convert-to-adf-timestamp element))
    (`inline-src-block (org-tickets--convert-to-adf-inline-src-block element))
    (`statistics-cookie (org-tickets--convert-to-adf-statistics-cookie element))
    (`latex-fragment (org-tickets--convert-to-adf-latex-fragment element))
    (`export-snippet (org-tickets--convert-to-adf-export-snippet element))
    (`example-block (org-tickets--convert-to-adf-example-block element))
    (`fixed-width (org-tickets--convert-to-adf-fixed-width element))
    (`latex-environment (org-tickets--convert-to-adf-latex-environment element))
    (`export-block (org-tickets--convert-to-adf-export-block element))
    (`horizontal-rule (org-tickets--convert-to-adf-horizontal-rule element))
    (`quote-block (org-tickets--convert-to-adf-quote-block element))
    (`verse-block (org-tickets--convert-to-adf-verse-block element))
    (`macro (org-tickets--convert-to-adf-macro element))
    (`plain-text (org-tickets--convert-to-adf-plain-text element))
    (`src-block (org-tickets--convert-to-adf-src-block element))
    (`table (org-tickets--convert-to-adf-table element is-header))
    (`table-row (org-tickets--convert-to-adf-table-row element is-header))
    (`table-cell (org-tickets--convert-to-adf-table-cell element is-header))
    (_ (org-tickets--convert-to-adf-default element))))

(defun org-tickets--build-adf-description (content &optional attachments)
  "Build ADF document structure from CONTENT string.
Parses CONTENT as Org text and converts to ADF format.
ATTACHMENTS is an optional list of Jira attachment metadata alists
with keys \"id\", \"filename\", and \"mediaApiFileId\", used to
resolve attachment: links to ADF media nodes."
  (if (or (null content) (string= content ""))
      nil
    (let ((org-tickets--adf-attachments attachments))
      (with-temp-buffer
        (insert content)
        (org-mode)
        (let ((ast (org-element-parse-buffer)))
          (let ((adf-content (org-tickets--convert-to-adf-content ast)))
            (when adf-content
              (append (list (cons "type" "doc")
                            (cons "version" 1))
                      (list (cons "content" adf-content))))))))))

(provide 'org-tickets-convert)

;;; org-tickets-convert.el ends here
