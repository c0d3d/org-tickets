# Maintenance Cleanup — Design

Date: 2026-11-06. Source: four read-only reviews (source A: core/api/async/
attachments/fields/cmd; source B: convert/adf-import/parse/import/sync/
sync-phases; tests A; tests B), with the top bug claims reproduced in batch
Emacs. The owner approved all five tiers.

## Goals

1. Fix real bugs, each pinned by a regression test written first.
2. Remove dead code and needless complexity without changing behavior.
3. Stop hand-parsing org structure where org/org-element already does it.
4. Reshape leaky or duplicated abstractions so each concept has one owner
   and one data shape.
5. Make the test suite assert behavior through shared, production-shaped
   fixtures, with no vacuous, duplicate, or state-leaking tests.

Non-goals: new features, new dependencies, changing the absolute heading
mapping (`***` = h1), changing the "Parent is a Blocks link" model.

## Constraints (owner decisions already made)

- Tickets: parent types (Feature, New Feature, Improvement, Epic) at level
  1 only; every other ticket at level 1 or 2 (enforced by
  `org-tickets--check-ticket-level`). Description headings are `***`+.
- Skip: replacing the `clear-labels`/`clear-story-points` flags with a
  sentinel, and a general "buffer helpers" module.

## Tier 1 — Bugs (verified unless marked "likely")

| # | Where | Bug |
|---|-------|-----|
| B1 | cmd.el templates | `insert` then `org-entry-put (point)` writes properties onto the *following* heading when point was at the start of one (verified: `* Other` received JIRA_TYPE). |
| B2 | parse.el `--resolve-blocked-by-in-org` | Substring test: `PROJ-1` never added to `BLOCKS: PROJ-12` (verified). |
| B3 | parse.el `--valid-ticket-key-p` | Rejects keys with digits/underscores in the project part, e.g. `AB2-12` (verified). |
| B4 | convert.el `--convert-to-adf-list-item`; adf-import.el `--adf-list-item-to-org` | Content after a nested list is moved above it; a second paragraph's first line is pushed indented; pull joins item blocks with one newline so paragraphs merge (verified). |
| B5 | parse.el `--with-ticket-at-key` callers (7 in sync.el), `--inherit-due-date` | Point moves; interactive commands jump the cursor. |
| B6 | api.el `--load-issue-types-from-document` | `goto-char (point-min)` without `save-excursion`; first sync of a session restores point to the top. Also matches the keyword inside src blocks. |
| B7 | cmd.el `org-tickets-refresh-issue-types` | Writes `#+JIRA_ISSUE_TYPES` into any current buffer (e.g. `*scratch*`). |
| B8 | tests | `headings-pull` fails standalone (missing require); `attach-remove-no-attach-dir`/`-file-not-found` reach the real `--get-attachments` (authinfo/network); `sprint-sent-as-id-in-create` leaks `org-tickets--issue-type-ids`; `sprint-cache-is-cleared-between-syncs` and `test.el` sprint-cache test depend on/leak global cache; `ensure-org-attach-id-no-inheritance` uses `find-file` and can register IDs globally. |

## Tier 2 — Dead code and simplification (no behavior change)

- Dead: `--adf-doc-to-org`, `--apply-default-sprint-to-new`,
  `--convert-to-adf-item`, `--plain-list-p` (after B4), ticket slots `id`
  and `org-node`, rate-limit slot `retry-after-time`, `org-tickets-setup`.
- Wrappers: convert.el nil/org-data/section/default and bold/italic/
  strike/underline one-liners; code-like and block-like arms that share a
  converter; `--collect-phase-1-results`.
- Duplicates: two "ensure org ID" functions (both reduce to
  `org-id-get-create`); empty-sprint guard ×3; sprint override block ×2;
  browse-URL construction ×2; local+remote attachment names ×2;
  queue-append ×2; "already downloaded" size check ×2; link thunk ×3;
  `(and x (> (length x) 0))` ×~20; ticket-marker access ×4; Feature vs
  Improvement template.
- Over-long / over-nested (CLAUDE.md): `--ticket-fields` (59 lines),
  `--issue-to-org` and `--update-org-heading-from-ticket` (~60),
  `--parse-ticket-at-point` (44), `--async-sync-ticket-links` (45, depth
  6), `--make-attachment-thunk` (depth ~10), attachment batch functions
  (~40, depth >3), `--resolve-blocked-by-in-org` (depth ~8).
- Stale docs: sprint-cache shape, `--delete-attachment` return, "as
  before"/"Track C"/history references, fields.el json-null comment,
  `--sync-in-progress`/run-sync docstrings, story template promising an
  unprompted FIX-VERSION.

## Tier 3 — Org-native parsing

- `#+JIRA_ISSUE_TYPES` read via `org-collect-keywords`.
- `--find-ticket-by-key` via `org-find-property` (today returns a position
  inside the drawer).
- One description region owner using `org-get-property-block` instead of
  two hand-rolled drawer skips (parse.el, import.el).
- Attachment link discovery via `org-element-map` (regex matches inside
  src blocks).
- The two heading loops (parse-document, inheritance) via
  `org-map-entries`.

## Tier 4 — Abstractions

- A-cycle: sync.el ⇄ sync-phases.el call each other (7
  `declare-function`s + a shared private cache). Split out
  `org-tickets-links.el` (link creation) and `org-tickets-inherit.el`
  (parent inheritance + remote parent cache); phase-3 buffer writers move
  to sync-phases.el; sync.el keeps commands + entry point.
- A-issue: Jira issue field readers live in three files with three
  spellings → one set of `org-tickets--issue-*` accessors in api.el.
- A-attach: attachments exist as raw Jira alists *and* reshaped symbol
  alists → raw Jira alists everywhere, read only through accessors.
- A-ticket-api: `--create-ticket` (9 positional args) and `--update-ticket`
  (plist) both rebuild a ticket record → both take a ticket record.
- A-config: API layer writes buffers; internal mirrors of defcustoms go
  stale → accessors that read the defcustoms; credentials cached per host;
  issue-type document I/O moves out of api.el.
- A-result: phase-1 results are ad-hoc plists with an optional `:ticket`
  → an `org-tickets--sync-result` record that always carries its ticket.
- Small: ADF attachment id-map passed as an argument (not a dynamic var
  bound by callers); table header flag removed from the generic converter
  dispatcher; `--get-sprints-for-project` mode flag removed
  (`--fetch-board-sprints`); `org-tickets--doc` stores only `tickets`.

## Tier 5 — Tests

- Shared helpers move into `test/org-tickets-test-fixtures.el`; no test
  file requires another test file.
- One helper per concept (ADF blocks/outline/texts/inline summary, ADF doc
  builders, ticket text builder, buffer-at macro, property-of-key).
- All API-shaped fixtures built with `org-tickets-test--json`.
- `with-sync-mocks` stubs only transport/config by default with an opt-in
  list for the rest; one fake Jira handler with a request log; the run-sync
  boilerplate (16 copies) replaced; the mode-line progress leak fixed.
- Delete vacuous, duplicate, and implementation-detail tests; strengthen
  weak assertions; move misplaced tests; strip plan-era headers; complete
  the docs/dev/testing.md table.
