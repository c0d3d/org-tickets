# Property Inheritance

A child ticket with no value of its own takes its parent's. The inherited
properties are listed in `org-tickets--inherited-properties`
(`org-tickets-sync.el`):

| Property | Jira field |
|---|---|
| `DUE_DATE` | `duedate` |
| `FIX_VERSION` | `fixVersions` |

Both are payload fields, which is what makes the *timing* below matter.

## Parent and Child Types

One list in `org-tickets-core.el` decides which headings participate:

```elisp
org-tickets--parent-issue-types  ;; "Feature" "New Feature" "Improvement" "Epic"
```

Everything else is a child. `org-tickets--child-type-p` is the *complement* of
`org-tickets--parent-type-p`, not an allowlist — any non-empty `JIRA_TYPE` that
is not a parent type inherits its parent's properties and gets a "Blocks"
link to it. Custom project issue types (`Merge`, `Spike`, …) therefore work
with no code change.

**Test membership with `org-tickets--parent-type-p` / `org-tickets--child-type-p`;
never compare against `"Story"` directly, and do not reintroduce a list of
child types.** Enumerating child types is what left a `Task` with no parent
link, no inherited properties, and — on the sequential phase-1 path — no
Jira issue at all, and later did the same to the custom `Merge` type. The
failure is silent, so it is only ever noticed in Jira. To *exclude* a type
from child treatment, add it to `org-tickets--parent-issue-types`.

For the same reason, phase 1's sequential path syncs features and then
`org-tickets--doc-non-feature-tickets` — everything that is *not* a feature,
derived by exclusion. Asking it for child tickets would silently drop a
ticket of any unlisted type from both batches; it would never be created
in Jira, and the sync would still report success.

## Where Inheritance Runs

Two passes, for two different moments:

| Pass | When | Why it exists |
|---|---|---|
| `org-tickets--inherit-parent-properties-in-buffer` | Phase 0, **before** `org-tickets--parse-document` | The inherited value must be in the ticket struct so `org-tickets--ticket-fields` puts it in the same create/update payload. |
| `org-tickets--apply-due-date-inheritance` | Phase 3, after `org-tickets--apply-due-date-updates` | Picks up a parent *due date* that only became known during the run, because phase 1 fetched it from Jira. Due-date only: nothing fetches `fixVersions` from Jira. |

**The phase-0 pass must stay before the parse.** Inheritance used to run
only in phase 3, after every create/update request had already been sent:
the value landed in the org drawer but Jira kept an empty due date until
the *next* sync. `org-tickets-test--new-story-sends-inherited-due-date-on-first-sync`
and `org-tickets-test--new-story-sends-inherited-fix-version` pin the payloads.

The phase-3 pass resolves a child's key with
`(or (org-tickets--ticket-key child) (org-tickets--ticket-buffer-key child))`.
A ticket created during this run was parsed before its key existed, so the
struct slot is still nil and only the buffer has the key — the same
fallback `org-tickets--async-sync-ticket-links` needs, for the same reason.

## Inheritance Rules

- **Own value wins.** A heading that already has a non-empty property is
  never overwritten, by either pass.
- **Jira wins over the parent.** Phase 3 applies Jira's fetched due date
  before the inheritance pass, so a date set in the Jira UI is not
  clobbered by the parent's.
- **A changed parent value does not re-propagate.** Once a child has a
  value, it keeps it. Clear the child's property to re-inherit.
- **Cascades.** The phase-0 pass walks headings top-down, so a heading
  that just inherited is the source for its own children.
- **Source must be a ticket.** Only headings with a JIRA_TYPE are
  inheritance sources; a plain org heading carrying a DUE_DATE is ignored.
- **PARENT first, then nearest ancestor.** The ticket named by the
  heading's PARENT property is used first — it need not be an ancestor, and
  it is the ticket the "Blocks" link goes to, so the two always agree. If it
  has no value, the outline is searched upward for an ancestor ticket that
  does.
- **A parent outside the buffer is read from Jira.** Both passes GET it
  synchronously (once per key per pass) for the properties in
  `org-tickets--remote-inherited-fields` (`DUE_DATE`, and `FIX_VERSION` from
  the first of the parent's `fixVersions`). A failed
  fetch is logged and the child is left unset. `org-tickets-test--with-sync-mocks`
  routes that GET through the test's request handler.

## `org-tickets-create-story`

Creates the Story in Jira immediately, so it sends the feature's fix
version, due date and labels in the create payload rather than waiting for
the next sync. The feature is read from the buffer when present, otherwise
from Jira (`org-tickets--story-parent-values`). A feature absent from the
buffer gets the story heading appended at top level, with `PARENT` set.

## Tests

`org-tickets-test-inheritance.el` covers both passes, both properties, and
the child-type behaviour (parent link, sequential-path creation),
end-to-end through a stubbed sync. `org-tickets-test-sync-due-date.el` covers
plain due-date plumbing: parsing, payload, org writeback.
