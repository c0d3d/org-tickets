# Sprint Lifecycle

Sprint assignment in org-tickets follows a strict one-way lifecycle after
initial ticket creation. Understanding this contract prevents accidental
overwrites of sprint assignments made in the Jira UI.

## Lifecycle Rules

| Phase | What happens |
|---|---|
| New ticket (no JIRA_KEY) | `org-tickets-default-sprint` is sent to Jira as the sprint. The SPRINT drawer property is set to `org-tickets-default-sprint`. |
| After creation | `org-tickets--sync-sprint-from-jira` overwrites SPRINT with the canonical name from Jira. |
| Existing ticket sync | Sprint is never sent to Jira. SPRINT drawer is updated from Jira. |
| Jira sprint differs from org | `org-tickets--sync-sprint-from-jira` overwrites the org SPRINT property. |
| Jira has no sprint | Org SPRINT property is left unchanged. |

## Key Invariants

- The sync flow (phase 1 in `org-tickets-sync-phases.el`) builds payloads with
  `org-tickets--ticket-fields` directly: creates carry `org-tickets-default-sprint`,
  updates carry no sprint.

- `org-tickets--create-ticket` and `org-tickets--update-ticket` take an
  `org-tickets--ticket` record and send its `sprint` slot (resolved to an ID),
  overriding the default sprint. Only interactive commands such as
  `org-tickets-create-story` use them.

## Configuration

Set `org-tickets-default-sprint` in your Emacs config before loading the package:

```elisp
;; Use a sprint ID (preferred — no API lookup required)
(setq org-tickets-default-sprint 3453)

;; Or use a sprint name (requires Jira Agile API call to resolve)
(setq org-tickets-default-sprint "Sprint 42")

;; Or nil to create tickets without a sprint
(setq org-tickets-default-sprint nil)
```

Sprint IDs are preferred over names. Name resolution fetches the active/future
sprint list from Jira and silently skips the sprint if the name is not found.

## Moving Tickets Between Sprints

Use the Jira UI to move a ticket to a different sprint. On the next
`org-tickets-sync-to-jira`, `org-tickets--sync-sprint-from-jira` will detect
the change and update the org SPRINT drawer to match Jira.

**Do not edit the SPRINT drawer manually to move sprints.** The value will be
overwritten from Jira on the next sync, and — per the lifecycle contract above —
the local value is never pushed back to Jira.
