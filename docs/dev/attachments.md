# Attachments Subsystem

## org-attach Inheritance

**Always use `org-tickets--get-ticket-attach-dir` instead of calling `org-attach-dir` directly.**

This wrapper (in `org-tickets-attachments.el`) disables `org-attach-use-inheritance` to prevent child headings from inheriting parent attachment directories. Without this, org-mode's default `selective` inheritance causes child stories to see parent attachment files as their own, uploading them to the wrong Jira ticket.

### What goes wrong without the wrapper

1. Parent feature has `:ID:` property and attachment files
2. Child story has no `:ID:`
3. `org-attach-dir` with default inheritance returns the parent's directory
4. `org-tickets--upload-attachments` uploads parent's files to the child's Jira ticket

### The fix

`org-tickets--get-ticket-attach-dir` let-binds `org-attach-use-inheritance` to `nil`:

```elisp
(defun org-tickets--get-ticket-attach-dir (create-if-not-exists)
  (require 'org-attach)
  (let ((org-attach-use-inheritance nil))
    (org-attach-dir create-if-not-exists)))
```

All code that needs an attachment directory must call this wrapper. Never call `org-attach-dir` directly.

## Attachment Metadata Shape

Attachments travel everywhere as the **raw Jira metadata alists** from the
issue's `attachment` field (symbol keys from json.el: `id`, `filename`,
`content`, `size`, `created`, `mediaApiFileId`) — sync phase 1, the
description builder, and the ticket record's `attachments` slot on import all
hold the same shape. `org-tickets--issue-attachments` (org-tickets-api.el)
extracts the list from an issue response.

Never read attachment keys directly. Use the accessors in
`org-tickets-core.el` (core so `convert.el` and `import.el` can use them
without requiring `attachments.el`): `org-tickets--attachment-filename`,
`-id`, `-content-url`, `-size`, `-created`, `-media-id`. They go through
`org-tickets--alist-get`, so string-key alists work too.

## Attachment Flow

### Upload (org → Jira)
1. `org-tickets--sync-to-jira` calls `org-tickets--sync-attachments` per ticket
2. `org-tickets--upload-attachments` finds the heading, gets its own attach dir
3. Compares local files against Jira attachments (by filename)
4. Uploads only files not already in Jira

### Multipart upload gotcha

Jira's `POST /rest/api/3/issue/{key}/attachments` endpoint **only** accepts a
`multipart/form-data` body whose form field is literally named `file`, plus the
`X-Atlassian-Token: no-check` header. A raw-body upload is rejected and no
attachment is created.

`org-tickets--async-upload-attachment` builds the multipart payload itself
(`org-tickets--multipart-file-body`) as a **unibyte** string, so binary
attachments survive intact, and sends it through the rate-limited
`org-tickets--async-enqueue` with an explicit `multipart/form-data; boundary=…`
`Content-Type`. Every header must be unibyte too: url.el signals
`Multibyte text in HTTP request` when a multibyte header (e.g. a boundary built
with `format-time-string`) is concatenated with a binary body. The regression test
`org-tickets-test--async-upload-attachment-sends-multipart-form` pins this contract.

### Download redirects

Jira answers attachment content requests with a redirect to a signed media URL.
`org-tickets--http-fetch-to-file` binds `url-max-redirections` to 0 and follows
the `Location` itself **without** the request headers, because url.el would
otherwise resend the `Authorization` header to the redirect host.

### Download (Jira → org)
1. `org-tickets--download-attachments` ensures the heading has an `:ID:`
2. Creates the attach dir if needed
3. Downloads files not already present locally

## Inline Embedding in Descriptions

`[[attachment:filename]]` org links embed the file in the Jira description.

### The media UUID gotcha

ADF media nodes render **only** when their `id` attr is the Media Services
UUID — the attachment's `mediaApiFileId` from the issue GET response. The
numeric REST attachment id produces a permanently broken embed, so the
converter (`org-tickets--attachment-media-uuid`) resolves links through
`mediaApiFileId` and falls back to plain text when no UUID is available.
Never emit a media node with the numeric id.

### Node choice

- Attachment link **alone in its paragraph** → block `mediaSingle` > `media`
  (Jira displays the image in full, like its own editor does).
- Attachment link **mid-sentence** → `mediaInline` (a small file chip).

Both paths live in `org-tickets-convert.el`; the import side
(`org-tickets-adf-import.el`) maps either node back to `[[attachment:filename]]`
via the UUID→filename map.

### Same-sync embedding (phase-2 description refresh)

Phase 1 PUTs the description using the attachment list from its GET, but new
files upload in phase 2 — so a freshly attached file cannot embed during the
phase-1 PUT (its link degrades to plain text). After uploads,
`org-tickets--make-attachment-thunk` checks for attachment links that phase 1
could not resolve (`org-tickets--unresolved-attachment-links-p`) and, if any,
re-GETs the issue and re-PUTs just the description
(`org-tickets--async-refresh-description-embeds`) so the new upload's
`mediaApiFileId` lands in the same sync. Tickets whose links all resolved in
phase 1 skip the extra round trip.

## Heading Search

**Always use `org-tickets--find-ticket-by-key` (from `org-tickets-parse.el`) to locate a ticket heading by key.** Never use bare `re-search-forward (regexp-quote ticket-key)` — it matches the key anywhere in the buffer, including in body text of other tickets that cross-reference it.

`org-tickets--find-ticket-by-key` is `org-find-property` on `JIRA_KEY`: it returns the position of the matching heading (point lands on the headline, not in its drawer), or nil. It respects narrowing.

Pattern:
```elisp
(let ((pos (org-tickets--find-ticket-by-key ticket-key)))
  (when pos
    (goto-char pos)
    ;; point is now on the correct heading
    ...))
```

### Pre-creation attachments
Files can be attached to headings before they have a `JIRA_KEY`. `org-id-get-create` creates an `:ID:` for the heading so org-attach can manage files. When the ticket is later created during sync, the files are uploaded automatically.

## Duplicate Filenames

If a ticket has multiple Jira attachments sharing the same filename (e.g.
re-uploaded revisions of the same file), downloading collapses them to a
single local file: `org-tickets--dedup-attachments-by-filename` keeps only the
entry with the newest `created` timestamp per filename before the download
step runs, so the local file always ends up as the latest version.
