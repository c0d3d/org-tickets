# Project Notes

## Running the Package

### Loading the Package
Add to your Emacs config (~/.emacs.local):

```elisp
(add-to-list 'load-path "~/junk/jira-ticketer")
(require 'org-tickets)
```

### Required Configuration
Set these variables in ~/.emacs.local before loading:

```elisp
(setq org-tickets-base-url "https://yourcompany.atlassian.net")
(setq org-tickets-project-key "PROJ")
(setq org-tickets-project-id "12345")
```

### Authentication
Credentials go in ~/.authinfo (or ~/.authinfo.gpg):

```
machine yourcompany.atlassian.net login your@email.com password YOUR_API_TOKEN
```

Generate an API token from Atlassian account settings.

### Running via CLI

Run interactively:
```bash
emacs --load ~/.emacs.local -f org-tickets-sync-to-jira
```

Run batch mode:
```bash
emacs --batch --load ~/.emacs.local -l ~/junk/jira-ticketer/org-tickets.el -f org-tickets-sync-to-jira
```

## Development Notes

### Build Targets

The Makefile provides these targets:

- `make test` — Recompile any changed source (the target depends on `$(ELCS)`), then run the ERT suite (in `test/`) against the freshly-compiled files
- `make compile` — Byte-compile source files (warnings are errors)
- `make lint` — checkdoc, plus package-lint when it is installed
- `make autoloads` — Generate `org-tickets-autoloads.el` from `;;;###autoload` cookies (gitignored; package.el generates its own on install)
- `make build` — Compile + generate autoloads
- `make install` — Build and copy package to `~/.emacs.d/packages/org-tickets` (override with `INSTALL_DIR=...`)
- `make clean` — Remove `.elc` files and the generated `deps.mk`

`deps.mk` is generated from each source's `(require 'org-tickets-…)` lines, so `.elc` files build in dependency order and editing a module (e.g. a macro) recompiles every module that requires it. Nothing to maintain by hand when adding requires or modules.

**Always run tests via `make test`.** It recompiles changed sources first and puts both `.` and `test/` on the load path.

To run a single test, put both directories on the load path. **First run `make compile` (or `make build`)** — the single-test command below has no `$(ELCS)` prerequisite, so it does not recompile. If a stale `.elc` is present, `require` loads it instead of your edited source: Emacs prints `Source file … newer than byte-compiled file; using older file` and silently runs the OLD code, so your test result is meaningless. This is not a reason to delete `.elc` (see below) — recompiling refreshes it.

```bash
make compile   # refresh .elc so the run uses current source
emacs --batch -L . -L test -l org-tickets-test.el \
  --eval "(ert-run-tests-batch-and-exit \"org-tickets-test--sync-restores-point-to-original-heading\")"
```

### Stale `.elc` Files

Stale `.elc` files are NEVER the solution to any problem. If you find yourself considering deleting `.elc` files to fix an issue, you are 100% wrong. The problem is always in the `.el` source code.

### File Size Limits

**No file should exceed 750 lines.** When a file approaches this limit, proactively split it before it gets there. Don't wait until the file is already too long.

- **Source files:** Split by logical subsystem. Each module should have one clear responsibility.
- **Test files:** Split by the module they test, or by test category (e.g., unit vs integration). If a test file for a single module exceeds 750 lines, split into subcategories (e.g., `org-tickets-test-attachments-upload.el`, `org-tickets-test-attachments-sync.el`).
- **When adding code to an existing file**, check its line count first. If it's near the limit, split before adding.

### Elisp Style

Follow these conventions for readable, maintainable Elisp:

**Never use `cl-lib`.** No file — source or test — may `(require 'cl-lib)` or
call a `cl-` function or macro. Use the native equivalent:

| Instead of | Use |
|------------|-----|
| `cl-remove-if` / `cl-remove-if-not` | `seq-remove` / `seq-filter` |
| `cl-find-if` / `cl-find` | `seq-find` (pass a predicate; there is no `:key`/`:test`) |
| `cl-some` / `cl-every` / `cl-count-if` | `seq-some` / `seq-every-p` / `seq-count` |
| `cl-mapcan` | `mapcan` |
| `cl-coerce X 'list` | `(append X nil)` |
| `cl-incf` / `cl-decf` on a variable | `(setq x (1+ x))` / `(setq x (1- x))` |
| `cl-incf` / `cl-decf` on a place | `(setf PLACE (1+ PLACE))` — `setf` is from `gv.el`, not `cl-lib` |
| `cl-block` + `cl-return-from` | `catch` + `throw`, or restructure to an early `if` |
| `cl-loop` | `dolist` / `mapcar` / `seq-*` |
| `cl-defun` with `&key` | `(defun f (req &rest args))` + `plist-get` |
| `cl-defstruct` | `org-tickets--define-record` (org-tickets-core.el) |
| `cl-letf` on `symbol-function` | `org-tickets-test--with-stubs` (org-tickets-test-fixtures.el) |

`org-tickets--define-record` generates a keyword constructor `NAME-create`, a
`NAME-p` predicate, and `setf`-able `NAME-SLOT` accessors over a plain
`record`, so it is a drop-in for the `cl-defstruct` call shape.

**Reduce nesting.** Use early returns (`cl-return-from`, `unless` guards) to flatten deeply nested code. If a function has more than 3 levels of nesting, refactor it. Prefer:
```elisp
;; Good: early return flattens the body
(cl-block my-func
  (unless condition
    (cl-return-from my-func nil))
  ;; main logic at top level
  (do-work))

;; Bad: deep nesting
(when condition
  (let ((x (compute)))
    (when x
      (let ((y (transform x)))
        (do-work y)))))
```

**Extract helpers for repeated patterns.** If the same `let`-binding + conditional + action pattern appears 3+ times, extract a function or macro. Name it descriptively.

**Use `let*` only when bindings depend on each other.** Use `let` for independent bindings.

**Keep functions short.** A function over 30 lines likely does too many things. Extract subroutines.

**Use `org-tickets--` prefix** for private functions, `org-tickets-` for public/interactive ones.

**Prefer `when`/`unless` over single-branch `if`.** Use `if` only when both branches are needed.

**Use `pcase` for structured matching** instead of chains of `cond`/`string=` when matching against known values.

**Docstrings are required** on all public and private functions. Keep them concise — one line for simple functions, a brief paragraph for complex ones.

## Developer Documentation

Detailed docs for specific subsystems live in `docs/dev/`. Read `docs/dev/README.md` to find what's relevant to your current task. **Only read the files you need** — this keeps context small.

### Layout

```
docs/dev/
  README.md          — Index: what each doc covers and when to read it
  attachments.md     — Attachment upload/download/sync, org-attach gotchas
  modules.md         — Module layout, load order, adding interactive commands
  testing.md         — Test organization, helpers, real Jira API testing
```

### Keeping Docs Up to Date

When making changes that affect developer workflows or subsystem behavior:

- **Adding/renaming a module:** Update `docs/dev/modules.md` and its table.
- **Adding test helpers or changing test patterns:** Update `docs/dev/testing.md`.
- **Changing attachment behavior or adding gotchas:** Update `docs/dev/attachments.md`.
- **Adding a new subsystem doc:** Create the file in `docs/dev/`, add it to `docs/dev/README.md` with a "when to read" description.
- **Removing a subsystem:** Delete its doc file, remove it from `docs/dev/README.md`.

If a change is universally relevant (affects all development), it belongs in this CLAUDE.md. If it's specific to one subsystem, it belongs in `docs/dev/`.

## Verification
- Review that all required configuration is documented
- Confirm the load path references the local project directory
- Ensure `make test` and `make build` still work
