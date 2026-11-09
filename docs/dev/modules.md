# Module Layout

The package is split into logical modules for maintainability.

## Modules

| Module | Responsibility |
|--------|---------------|
| `org-tickets-core.el` | Requires, defcustoms, defvars, config accessors (`--base-url`, `--project-key`, `--project-id`: read the defcustom on every call, `user-error` when unset), the `org-tickets--define-record` macro, data structures (`org-tickets--ticket`, `org-tickets--doc`), alist/list utilities, Jira attachment accessors |
| `org-tickets-api.el` | Jira REST API client: per-host credentials cache (`--credentials`), `--resolve-config` (validate config, warm credentials), HTTP requests, issue type fetching (returns the alist; never touches buffers) |
| `org-tickets-async.el` | Async HTTP layer: `url-retrieve` wrapper, rate limiting, batch execution, modeline progress |
| `org-tickets-attachments.el` | Upload/download/sync attachments (depends on API module) |
| `org-tickets-convert.el` | Org-to-ADF conversion, ADF node constructors |
| `org-tickets-fields.el` | Jira payload construction (`org-tickets--ticket-fields`), create/update field rules, clearing semantics |
| `org-tickets-parse.el` | Parse org buffers into ticket structs, document and ticket extraction, `#+JIRA_ISSUE_TYPES` read/write (`--load-issue-types`, `--save-issue-types`) |
| `org-tickets-adf-import.el` | ADF-to-org conversion (inline/block/list layers) used by import |
| `org-tickets-import.el` | Import from Jira, ADF parsing (Jira to org) |
| `org-tickets-graph.el` | Ticket dependency graph model (`--graph-model`: nodes and blocker-to-blocked edges from BLOCKS, BLOCKED-BY and parents) loop detection (`--graph-cycles`, `--graph-cycle-edges`), DOT rendering (`--graph-dot`) and the `org-tickets-graph` command (pipes DOT to `org-tickets-graph-dot-program`, writes `<file>.svg`, echoes loops) |
| `org-tickets-links.el` | "Blocks" link creation (`--async-create-link`, per-ticket link thunks), ticket-marker helpers (`--at-ticket-marker`, `--ticket-buffer-key`, `--ticket-parent-key`) |
| `org-tickets-inherit.el` | DUE_DATE/FIX_VERSION inheritance from the PARENT or ancestor ticket, remote parent cache (`--with-parent-cache`) |
| `org-tickets-sync-phases.el` | Async sync pipeline: setup/teardown (`--sync-cleanup`), phase 1 (create/update), phase 2 (attachments+links), phase 3 (apply results: `--set-org-*`, `--resolve-blocked-by-in-org`) |
| `org-tickets-sync.el` | Sync entry point, issue type loading (`--ensure-issue-types`: document first, else fetch and save), story creation, block links, fix version/label/story sizing commands |
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

Each module `require`s only modules below it; there are no require cycles
(`deps.mk`, generated from the `require` lines, orders compilation).  One
call dependency still runs upward: `api` requires `fields`, and `fields`
calls `org-tickets--resolve-sprint-value` in `api` through a
`declare-function` rather than a `require`.  The sync stack layers as:

```
links, inherit → sync-phases → sync → cmd
```

`sync-phases` never calls back into `sync`; shared helpers live in the
lower module that both use.

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
