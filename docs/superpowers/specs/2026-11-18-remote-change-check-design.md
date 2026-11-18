# Remote change check before sync

## Why

Sync pushes the org buffer over Jira unconditionally, so edits a teammate
made in Jira since my last sync are silently overwritten.

## Behaviour

Before anything is sent, sync checks every ticket that already has a
`JIRA_KEY` for changes made in Jira **by someone other than me** since that
ticket's last sync.

- **Content** = summary and description.  If anyone else changed content on
  any ticket, sync shows one warning listing each ticket and field
  (`PROJ-12: description changed by Alice`) and stops.  Nothing is pushed.
- **Metadata** = everything else (labels, sprint, story points, fix version,
  due date, type, blocks/blocked-by, parent).  If others changed only
  metadata, the remote metadata is written into that heading (headline and
  description untouched), the buffer is re-parsed, and the normal sync runs.
- Tickets with no `JIRA_SYNCED` property are not checked (first sync after
  this ships just records the baseline).

## Approaches

- **A. Pre-flight check pass (chosen).**  A new phase before phase 1 GETs all
  existing tickets with `?expand=changelog`, in parallel, then decides.
  Cancel is all-or-nothing; costs one extra request per ticket.
- **B. Check inside the existing per-ticket GET.**  No extra requests, but a
  conflict only fails that ticket while others may already be pushed — does
  not match "cancel syncing".

## Design

- **Who is "me":** `GET /rest/api/3/myself` once per sync; compare
  `accountId` against each changelog history's `author.accountId`.
- **What changed:** changelog histories with `created` later than the
  heading's `JIRA_SYNCED` and a foreign author.  An item whose `fieldId` is
  `summary` or `description` is content; any other item is metadata.
- **Baseline:** `JIRA_SYNCED` stores the issue's `fields.updated` (Jira server
  time) from the GET phase 1 already makes before each PUT.  It is written
  in phase 3 only for tickets whose push succeeded, so a failed push is
  re-checked next time.  A newly created ticket has no GET, so it gets its
  baseline on its next sync (that sync does not check it).
- **Metadata pull keeps PARENT:** Jira's parent field is never set here (a
  parent is a Blocks link), so the pull keeps the heading's local `PARENT`
  rather than clearing it.
- **Check fails:** if `/myself` or any check GET errors, sync stops with a
  message and nothing is pushed.  A cancel modifies nothing in the buffer.
- **Pulling metadata:** reuse `org-tickets--parse-jira-issue` and
  `org-tickets--write-ticket-properties` (clear-missing) on the heading;
  do not call the headline/description parts of
  `org-tickets--update-org-heading-from-ticket`.
- **Cancel:** `display-warning` with the list, then the existing sync
  cleanup path; no PUT/POST/link requests are fired.
- **Placement:** new module `org-tickets-conflict.el` (sync-phases.el is at
  545 lines), sitting between `inherit` and `sync-phases` in the load order;
  update `docs/dev/modules.md`.

## Non-goals

- Comments, attachments, and worklogs (not in the changelog's field set we act on).
- Merging or diffing content; content conflicts are resolved by hand.
- Paging changelogs beyond the first page Jira returns with `expand`.

## Left to the builder

Exact function names, how the pre-flight results are threaded into phase 1,
and test structure (ERT with stubbed async requests, asserting on buffer
contents and which requests were fired).
