# Issue Links

How Jira issue links (e.g., "Blocks") work in this codebase.

## Jira API Semantics

For the "Blocks" link type, Jira defines two directions:

- **outward** label: "blocks"
- **inward** label: "is blocked by"

### GET Response (reading links)

When fetching ticket X, each link in `issuelinks` has either an `outwardIssue` or `inwardIssue` field:

- `outwardIssue: Y` means **X blocks Y** (Y is the blocked ticket)
- `inwardIssue: Z` means **Z blocks X** (Z is the blocker)

This is handled in `org-tickets-import.el` where:
- `outwardIssue` keys go into the ticket's `blocks-list`
- `inwardIssue` keys go into the ticket's `blocked-by-list`

### POST Request (creating links)

`POST /rest/api/3/issueLink` uses the same field semantics:

- `inwardIssue` = the **blocker** (from-key)
- `outwardIssue` = the **blocked** ticket (to-key)

In `org-tickets--create-link`, `from-key` is the blocker and `to-key` is the blocked:

```elisp
(cons "inwardIssue" (list (cons "key" from-key)))   ;; blocker
(cons "outwardIssue" (list (cons "key" to-key)))     ;; blocked
```

## Org Properties

Tickets in org-mode use two properties for block relationships:

- `BLOCKS: PROJ-200` on ticket PROJ-100 means PROJ-100 blocks PROJ-200
- `BLOCKED-BY: PROJ-100` on ticket PROJ-200 means PROJ-200 is blocked by PROJ-100

During sync, `BLOCKED-BY` is also resolved: if PROJ-200 has `BLOCKED-BY: PROJ-100`, a "Blocks" link is created from PROJ-100 to PROJ-200.

Each distinct link is POSTed once per sync. `org-tickets--ticket-link-pairs`
drops self-links and duplicates within one ticket (e.g. a `PARENT` that is
also listed in `BLOCKS`), and phase 2 shares one table of requested links
(`org-tickets--links-requested`) across all tickets, so PROJ-100
`BLOCKS: PROJ-200` plus PROJ-200 `BLOCKED-BY: PROJ-100` sends one request.
A key in both `BLOCKS` and `BLOCKED-BY` of the same ticket names two links
(opposite directions, a cycle); both are sent.

## Parents Are Blocks Links, Not Jira's Parent Field

A child ticket's parent is expressed **only** as a "Blocks" issue link (the
child blocks the parent). org-tickets **never** writes Jira's real `parent`
(issue-hierarchy) field.

- A child ticket (any `org-tickets--child-type-p` type — anything that is not
  a Feature/Improvement, including custom types such as `Merge`)
  nested under a Feature/Improvement heading, **or** carrying an explicit
  `PARENT: KEY`, produces a "Blocks" link from the child to that parent.
  This happens in `org-tickets--async-sync-ticket-links` (`org-tickets-links.el`),
  during phase 2 — not in the create payload. See
  [inheritance.md](inheritance.md) for the type lists.
- `org-tickets--ticket-fields` (`org-tickets-fields.el`) deliberately builds no
  `parent` key, and `org-tickets--create-ticket` accepts no parent argument.

**Why:** setting Jira's parent field requires a Premium subscription and
fails with `400 Bad Request` ("You need to have Premium subscription to set
parent…") on Standard/Free plans, and it is not the relationship this tool
models. **Do not re-add a `parent` field to the create/update payload.** The
regression test `org-tickets-test--ticket-fields-create-omits-jira-parent-field`
(and the payload-omits-parent tests in `org-tickets-test-sync-flow.el`) guard
against reintroducing it.
