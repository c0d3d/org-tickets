# Module Layout

The package is split into logical modules for maintainability.

## Modules

| Module | Responsibility |
|--------|---------------|
| `org-tickets-core.el` | Requires, defcustoms, defvars, the `org-tickets--define-record` macro, data structures (`org-tickets--ticket`, `org-tickets--doc`) |
| `org-tickets-api.el` | Jira REST API client, config resolution, HTTP requests, issue type management |
| `org-tickets-async.el` | Async HTTP layer: `url-retrieve` wrapper, rate limiting, batch execution, modeline progress |
| `org-tickets-attachments.el` | Upload/download/sync attachments (depends on API module) |
| `org-tickets-convert.el` | Org-to-ADF conversion, ADF node constructors |
| `org-tickets-fields.el` | Jira payload construction (`org-tickets--ticket-fields`), create/update field rules, clearing semantics |
| `org-tickets-parse.el` | Parse org buffers into ticket structs, document and ticket extraction |
| `org-tickets-sync.el` | Sync entry point, story creation, block links, fix version/label management |
| `org-tickets-sync-phases.el` | Async sync pipeline: phase 1 (create/update), phase 2 (attachments+links), phase 3 (apply results) |
| `org-tickets-import.el` | Import from Jira, ADF parsing (Jira to org) |
| `org-tickets-adf-import.el` | ADF-to-org conversion (inline/block/list layers) used by import |
| `org-tickets-cmd.el` | Interactive commands, templates |

## Data Structures

Record types are declared with `org-tickets--define-record` (org-tickets-core.el),
**not** `cl-defstruct` — `cl-lib` is banned project-wide (see CLAUDE.md). The
macro generates a keyword constructor `NAME-create`, a `NAME-p` predicate, and
`setf`-able `NAME-SLOT` accessors over a plain `record`, so the call shape
matches `cl-defstruct`:

```elisp
(org-tickets--define-record org-tickets--rate-limit-state
    "Tracks adaptive rate limiting state."
  (throttled-p nil)
  (in-flight 0))          ; slot defaults are evaluated per construction
```

The constructor rejects unknown slot keywords, so a typo in a `:slot` name is
an error rather than a silently dropped field.

## Load Order

`org-tickets.el` is the umbrella. It `require`s every submodule in dependency
order:

```
org-tickets.el → org-tickets-core.el → [all other modules] → org-tickets-cmd.el
```

To pick up source edits in a running Emacs, restart it (or `M-x load-file` the
edited module).

## Adding a New Module

1. Create `org-tickets-<name>.el` with the standard header, internal
   `(require 'org-tickets-...)` for its deps, and `(provide 'org-tickets-<name>)`.
2. Add `(require 'org-tickets-<name>)` to `org-tickets.el`, in dependency order.
3. Add a row to the module table above.

## Adding New Interactive Commands

When adding a new interactive command (function with `;;;###autoload` marker):

1. Add the `;;;###autoload` marker directly above the `defun` in the source file
2. Run `make autoloads` — it regenerates `org-tickets-autoloads.el` from the
   `;;;###autoload` cookies. Never hand-edit that file.
