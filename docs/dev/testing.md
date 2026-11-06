# Testing

## Running Tests

```bash
make test
```

This runs all ERT tests directly against source files in batch mode. No intermediate directories are created.

## Byte-Compile Warnings

`make compile` must produce **zero warnings**. Check before committing:

```bash
make clean && make compile 2>&1
```

Common warnings and how to fix them:

| Warning | Fix |
|---------|-----|
| Unused lexical argument | Prefix with `_` (e.g., `_user`) |
| Unused lexical variable | Remove the binding, or prefix with `_` if needed for destructuring |
| Function not known to be defined | Add `(declare-function name "module")` near the top of the file |
| Docstring wider than 80 characters | Rewrap the docstring to fit within 80 columns |
| Wrong usage of unescaped single quotes | Use `\='` instead of `'` in docstrings |

## Test File Organization

Test files mirror source modules:

| Source | Test file |
|--------|-----------|
| `org-tickets-parse.el` | `org-tickets-test-parse.el` |
| `org-tickets-sync.el` | `org-tickets-test-sync.el`, `org-tickets-test-sync-flow.el`, `org-tickets-test-sync-flow-phase2.el`, `org-tickets-test-sync-links.el`, `org-tickets-test-sync-sprint.el`, `org-tickets-test-sync-due-date.el`, `org-tickets-test-inheritance.el` |
| `org-tickets-convert.el` | `org-tickets-test-convert.el`, `org-tickets-test-convert-nodes.el`, `org-tickets-test-list-continuation.el` (continuation-line indentation), `org-tickets-test-ordered-start.el` (ordered list start numbers) |
| `org-tickets-fields.el` | `org-tickets-test-fields.el` |
| `org-tickets-import.el` | `org-tickets-test-import.el` |
| `org-tickets-adf-import.el` | `org-tickets-test-roundtrip.el` (org<->ADF round-trips) |
| Description headings (parse, convert, import) | `org-tickets-test-headings-push.el` (org -> ADF, description boundaries), `org-tickets-test-headings-pull.el` (ADF -> org, pulls, round-trips) |
| `org-tickets-attachments.el` | `org-tickets-test-attachments-upload.el`, `org-tickets-test-attachments-sync.el`, `org-tickets-test-attachments-async.el` |
| `org-tickets-cmd.el` | `org-tickets-test-cmd.el`, `org-tickets-test-cmd-ticket-at-point.el` (commands run from inside a ticket's description headings) |
| `org-tickets-async.el` | `org-tickets-test-async.el` |
| `org-tickets-core.el` | `org-tickets-test-record.el` (the `org-tickets--define-record` macro) |

Test files live in `test/` and are loaded by `test/org-tickets-test.el` (the test runner entry point) via `require`; each test file `provide`s its own feature.

`org-tickets-test-record.el` pins down `org-tickets--define-record`, which every
ticket, document and rate-limit-state in the package is built from. It covers
construction, slot defaults (including that an explicit nil beats a non-nil
default, and that defaults are re-evaluated per construction so no structure
is shared), `setf` mutation, the type predicate against non-records and
lookalikes, constructor rejection of unknown/misspelled/valueless slot
keywords, and print/read round-tripping. Changes to the macro belong there.

When a test file exceeds 750 lines, split by category (e.g., `org-tickets-test-attachments-upload.el`, `org-tickets-test-attachments-sync.el`) and add a `require` for the new file to `test/org-tickets-test.el`.

## Test Helpers

### Fixture helpers (`org-tickets-test-fixtures.el`)

- `org-tickets-test--json` — parse a literal JSON string exactly as the API
  client does (symbol keys, list arrays, `:json-false`). **All API-response
  fixtures must be built with it** — hand-written string-key alists have a
  different shape than production data and have masked real bugs.
- `org-tickets-test--with-stubs` — macro that temporarily replaces function
  definitions, restoring them on exit (including a non-local exit). **This is
  the project's replacement for `cl-letf`, which is banned along with the rest
  of `cl-lib`** (see CLAUDE.md). Takes plain `(SYMBOL FUNCTION)` pairs — no
  `(symbol-function 'foo)` wrapper:

  ```elisp
  (org-tickets-test--with-stubs ((org-tickets--resolve-config #'ignore)
                              (org-tickets--api-request
                               (lambda (_method _endpoint &optional _data) nil)))
    BODY)
  ```

  Every stub's replacement form is evaluated before any function cell is
  written, so a stub expression never observes a half-stubbed world. Symbols
  that were unbound beforehand are left unbound again.
- `org-tickets-test--with-sync-mocks` — macro that stubs the async HTTP layer
  and every side-effectful helper (attachments, links, config), then runs
  BODY. Its argument is a `(method endpoint callback &optional data)`
  lambda; capture `data` to assert on request payloads.
- `org-tickets-test--make-get-response` — fake `GET /issue` response, with
  optional sprint and due date.
- `org-tickets-test--insert-feature` / `org-tickets-test--insert-story` — build
  ticket headings in the current org buffer.
- `org-tickets-test--run-sync` — clear the sync guard and read-only lock, then
  call `org-tickets--sync-to-jira` on the current buffer.

Any test that drives the whole pipeline uses these; keep them here rather
than in one suite so the others can reuse them.

### Attachment test helpers (`org-tickets-test-attachments-upload.el`)

- `org-tickets-test--uuid-attach-path` — converts UUID to org-attach's `first2/rest` dir format
- `org-tickets-test--with-attach-env` — macro that sets up temp attach dir, creates files, org buffer, mocks `org-attach-dir` and `org-tickets--async-upload-attachment`, and cleans up. Binds `uploaded-to` in BODY.

## Testing with Real Jira API

For testing import/fetch with the real API, create a test script:

```elisp
;; /tmp/test-fetch.el
(add-to-list 'load-path "~/path/to/jira-ticketer")
(require 'org-tickets)

(setq org-tickets-base-url "https://yourcompany.atlassian.net")
(setq org-tickets-project-key "PROJ")
(setq org-tickets-project-id "12345")
(setq org-tickets-debug t)

;; Fetch a ticket
(let* ((jira-response (org-tickets--get-ticket "PROJ-11573"))
       (ticket (org-tickets--parse-jira-issue jira-response)))
  (message "Ticket: %s" (org-tickets--ticket-summary ticket)))
```

```bash
emacs --batch -l /tmp/test-fetch.el
```

Note: `org-tickets-import-feature` requires an interactive Emacs session with an org buffer open. It will fail in batch mode because `org-entry-put` requires org-mode context.
