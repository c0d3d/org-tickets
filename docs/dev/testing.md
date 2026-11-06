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
| `org-tickets-core.el` | `org-tickets-test-record.el` (the `org-tickets--define-record` macro), `org-tickets-test-options.el` (the `org-tickets-needs-sizing-label` and `org-tickets-fix-version-months` options) |
| `org-tickets-api.el` (config, credentials, request encoding, HTTP response parsing, issue types) | `org-tickets-test-api.el` |
| `org-tickets-async.el` | `org-tickets-test-async.el` (async requests, batching, rate limiting, progress) |
| `org-tickets-parse.el` | `org-tickets-test-parse.el` |
| `org-tickets-fields.el` | `org-tickets-test-fields.el` |
| `org-tickets-convert.el` | `org-tickets-test-convert.el`, `org-tickets-test-convert-nodes.el`, `org-tickets-test-macro.el` (org macros in descriptions), `org-tickets-test-list-continuation.el` (continuation-line indentation), `org-tickets-test-ordered-start.el` (ordered list start numbers) |
| `org-tickets-import.el` | `org-tickets-test-import.el` (issue -> ticket -> org, pulling into a heading) |
| `org-tickets-adf-import.el` | `org-tickets-test-import-adf.el` (ADF -> org text), `org-tickets-test-roundtrip.el` (org<->ADF round-trips) |
| Description headings (parse, convert, import) | `org-tickets-test-headings-push.el` (org -> ADF, description boundaries), `org-tickets-test-headings-pull.el` (ADF -> org, pulls, round-trips) |
| `org-tickets-attachments.el` | `org-tickets-test-attachments-upload.el`, `org-tickets-test-attachments-sync.el`, `org-tickets-test-attachments-async.el` |
| `org-tickets-links.el` | `org-tickets-test-sync-links.el` (Blocks link creation and per-ticket link sync) |
| `org-tickets-inherit.el` | `org-tickets-test-inheritance.el` (DUE_DATE/FIX_VERSION inheritance), `org-tickets-test-sync-due-date.el` (due date in payloads and external parents) |
| `org-tickets-sync-phases.el` | `org-tickets-test-sync-flow.el` (whole pipeline, phase ordering, buffer protection, BLOCKED-BY write-back), `org-tickets-test-sync-flow-phase2.el` (attachment thunks) |
| `org-tickets-sync.el` | `org-tickets-test-sync.el` (org property helpers, payloads), `org-tickets-test-sync-sprint.el` (sprint resolution and listing, fix version payloads) |
| `org-tickets-cmd.el` | `org-tickets-test-cmd.el`, `org-tickets-test-cmd-ticket-at-point.el` (commands run from inside a ticket's description headings) |

Test files live in `test/` and are loaded by `test/org-tickets-test.el` (the test runner entry point), which holds only `require`s; each test file `provide`s its own feature and passes when loaded on its own. Put a test in the file for the module it exercises, not the one that happens to share its fixtures.

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
- Configuration: wrap the test in `org-tickets-test--with-fake-config`. It
  binds the defcustoms (`org-tickets-base-url` = `https://test.atlassian.net`,
  `org-tickets-project-key` = `PROJ`, `org-tickets-project-id` = `12345`),
  starts from an empty `org-tickets--credentials-cache` and stubs
  `auth-source-search` with a fixed login, so even `org-tickets--resolve-config`
  runs for real and no test reads `~/.authinfo`. Every harness below uses it.

### Fake Jira (`org-tickets-test-fixtures.el`)

Pick the layer the code under test talks to:

| Code under test calls | Fake |
|---|---|
| `url-retrieve` (async HTTP layer, attachments) | `--with-url-responses` |
| `org-tickets--async-request` | `--fake-jira-handler` (stub it in, or pass it to `--with-sync-mocks`) |
| `org-tickets--api-request` (synchronous commands) | `--with-fake-api` + `--fake-jira-handler` |
| `org-tickets--sync-to-jira` (whole pipeline) | `--with-sync-mocks` + `--run-sync` |

- `--with-url-responses RESPONSES CALLS &rest BODY` — `url-retrieve` answers
  from RESPONSES (full HTTP strings), in order and synchronously, in a fresh
  unibyte buffer. Pass `:deferred` instead of a list to only log requests and
  answer each later with `--url-respond CALL RESPONSE` (out-of-order
  completion, 429 retries, concurrency caps). CALLS, unless nil, is a variable
  each request is pushed onto as `(:url :method :headers :data :callback)`.
  Also stubs `run-at-time`/`force-mode-line-update` and applies
  `--with-fake-config`.
- `--fake-jira-handler &rest ARGS` (macro) — returns a fake
  `org-tickets--async-request`. `:get` is the response to every GET or a
  function of the endpoint (default `--make-get-response`); `:post-keys` are
  handed out in order to issue creates (`POST /rest/api/3/issue`), the last
  repeating (default `("PROJ-NEW")`); `:log VAR` pushes each request onto VAR
  as `(METHOD ENDPOINT DATA)`. Everything else answers empty. Assert on the
  log instead of keeping per-test counters:
  - `--requests LOG METHOD &optional ENDPOINT` — matching requests, oldest
    first (ENDPOINT is exact).
  - `--payload-field DATA FIELD` — a field of a create/update payload; match
    payloads by `summary`, not by internal ids.
  - `--logged-links LOG` — the `(BLOCKER BLOCKED TYPE)` issue links POSTed.
- `--with-fake-api HANDLER &rest BODY` — routes the synchronous
  `org-tickets--api-request` through HANDLER (via `--sync-api`), pre-resolves
  the Story issue type and clears the default sprint.
- `--with-sync-mocks HANDLER [:real (FN ...)] &rest BODY` — runs the sync
  pipeline against HANDLER (nil = a default `--fake-jira-handler`). Stubs
  issue-type/sprint-cache setup, both attachment batch functions,
  `org-tickets--async-sync-ticket-links` and
  `org-tickets--build-adf-description` (returns nil: no pipeline test sees a
  pushed description). **The synchronous `org-tickets--get-ticket` is routed
  through HANDLER** as `GET /rest/api/3/issue/KEY`, so parent lookups for
  due-date/fix-version inheritance hit the same fake and appear in its log.
  `:real (FN ...)` leaves the named functions unstubbed, e.g.
  `:real (org-tickets--async-sync-ticket-links)` to send real link requests
  through HANDLER.
- `--run-sync` — clear the sync guard and read-only lock, then call
  `org-tickets--sync-to-jira` with `org-tickets--progress-install` stubbed
  (it writes the global default of `mode-line-misc-info`, which would leak
  between tests). Only a test of the re-entrancy guard calls
  `org-tickets--sync-to-jira` directly.
- `--make-get-response &optional SPRINT DUE-DATE` — fake `GET /issue`
  response.
- Headings: `--insert-ticket LEVEL TITLE &rest PROPS` appends a heading at
  `point-max` with PROPS (`"NAME" VALUE` pairs, nil values skipped);
  `--insert-feature TITLE KEY &rest PROPS` and
  `--insert-story TITLE KEY PARENT-KEY &rest PROPS` are wrappers.

Any test that drives the whole pipeline uses these; keep them here rather
than in one suite so the others can reuse them.

### ADF and ticket helpers (`org-tickets-test-fixtures.el`)

No test file may `require` another test file; shared helpers live in the
fixtures file.

- Push side (org -> ADF): `--adf-blocks ORG`, `--adf-outline ORG`
  (`(LEVEL-OR-TYPE . TEXT)` pairs), `--adf-first-paragraph ORG`,
  `--inline-summary ORG`, `--adf-texts NODES`, `--block-type`,
  `--block-text`, `--adf-heading-level BLOCK`.
- Pull side (ADF -> org): `--adf-doc &rest BLOCKS`, `--adf-heading LEVEL TEXT
  &optional MARKS`, `--adf-para TEXT` build API-shaped ADF; `--pull
  ADF-OR-JSON` imports either to org text.
- `--roundtrip ORG` / `--roundtrip-n ORG N` — push then pull (N times).
- Ticket buffers: `--ticket-text STARS TYPE TITLE BODY &optional KEY`,
  `--parse-tickets TEXT`, `--description-of TEXT TITLE`, `--pushed-outline TEXT TITLE`,
  `--reported-item` (shared sample list item), `--parent-types`,
  `--with-org-buffer-at TEXT TARGET` (macro), `--prop-of KEY PROP`.
- `--with-attach-env` — macro that sets up a temp attach dir, creates files,
  an org buffer, mocks `org-attach-dir` and `org-tickets--async-upload-attachment`,
  and cleans up. Binds `uploaded-to` in BODY. `--uuid-attach-path` converts a
  UUID to org-attach's `first2/rest` dir format.

(All names carry the `org-tickets-test` prefix.)

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
