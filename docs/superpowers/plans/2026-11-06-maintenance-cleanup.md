# Maintenance Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the verified bugs, then remove dead code, hand-rolled org parsing, leaky abstractions and weak tests from org-tickets without changing user-visible behavior beyond the bug fixes.

**Architecture:** Five tiers run in order (bugs → simplify → org-native parsing → abstractions → tests). Every task leaves `make test` fully green and is one commit. Tier 1 tasks write the failing test first; later tiers are refactors guarded by the existing suite plus the tests named in each task.

**Tech Stack:** Emacs Lisp (Emacs ≥ 29.1, Org ≥ 9.6), ERT, GNU Make.

**Spec:** `docs/superpowers/specs/2026-11-06-maintenance-cleanup-design.md`

## Global Constraints

- Read `CLAUDE.md` first; its Elisp Style rules are requirements: no `cl-lib` (anywhere, tests included); ≤ 3 nesting levels; functions ≲ 30 lines; `let*` only for dependent bindings; `when`/`unless` over one-branch `if`; `pcase` for known values; docstring on every function; `org-tickets--` private prefix.
- No file over 750 lines. No new dependencies.
- Tests assert behavior (inputs/outputs/observable effects), never internals. API-shaped fixtures go through `org-tickets-test--json`. Stub with `org-tickets-test--with-stubs`.
- Never delete `.elc` to fix anything. `deps.mk` orders compilation.
- Every shell running make needs `export MACOSX_DEPLOYMENT_TARGET=27.0` (macOS 27 libgccjit bug).
- Verify every task with: `make test` → last line `Ran N tests, N results as expected, 0 unexpected`; and `make lint` → no checkdoc warnings.
- Commit every task with exactly:
  `GIT_AUTHOR_NAME="Neil Locketz" GIT_AUTHOR_EMAIL="neil@nlocketz.com" GIT_COMMITTER_NAME="Neil Locketz" GIT_COMMITTER_EMAIL="neil@nlocketz.com" git commit -m "<message>"` — no Co-Authored-By trailer.
- Never write real employer identifiers into tracked files (real project keys, project IDs, ticket numbers, work emails). Use `PROJ-`/`12345` placeholders.
- Keep docs current: `docs/dev/modules.md` when modules move, `docs/dev/testing.md` when tests/helpers move.
- Owner-fixed design: parent types at outline level 1, other tickets level 1–2 (`org-tickets--check-ticket-level`); description headings `***`+ map absolutely (`***` = h1).

## Review Focus

1. **Narrowed buffers** — commands and sync run with the buffer narrowed to one ticket; lookups must not silently miss tickets outside the region nor write outside it. Pinned in Task 5 (`--with-ticket-at-key` under narrowing) and Task 13 (`org-find-property` lookup).
2. **Cursor and scroll position** after every interactive command and sync — no command may leave point on another ticket. Pinned in Task 5.
3. **Ticket keys appearing in body text** (`See PROJ-1`, `PROJ-12` vs `PROJ-1`) — lookups and BLOCKS updates must match the property exactly. Pinned in Tasks 2 and 13.
4. **Org syntax inside src/example blocks** (`#+JIRA_ISSUE_TYPES:`, `[[attachment:x]]`, `* ` lines) — must not be treated as live syntax. Pinned in Tasks 5 and 13.
5. **Whitespace-only property values** (`:LABELS:   `, `:PARENT:  `) — treated as empty everywhere. Pinned in Task 12.

---

## Tier 0

### Task 0: Commit the in-flight work

Uncommitted work from this session (description headings, ticket-at-point commands, list continuation, ordered-list start, ticket-level requirement, Makefile deps) is the baseline.

- [ ] **Step 1:** `make test` and `make lint` pass (573 tests).
- [ ] **Step 2:** Commit in two commits: (a) `Makefile .gitignore CLAUDE.md` — "Build: derive .elc dependencies from requires"; (b) everything else — "Description headings, ticket-at-point commands, list fixes, ticket level rule".

---

## Tier 1 — Bugs

### Task 1: Templates write to the new heading

**Files:** Modify `org-tickets-cmd.el` (template section). Test `test/org-tickets-test-cmd.el`.

**Interfaces:** Produces `(org-tickets--insert-ticket-template STARS TYPE SUMMARY PROPS)` — inserts `STARS SUMMARY` as a new heading at point and puts each `(PROP . VALUE)` of alist PROPS on *that* heading, skipping nil/empty-string values except the keys listed below that must exist empty. Feature, Improvement and Story commands become thin callers. Story template's interactive spec gains `\nsFix Version (optional): `.

- [ ] **Step 1: Failing tests**
  - `org-tickets-test--feature-template-at-existing-heading`: buffer `"* Other\n"`, point at `point-min`, call `(org-tickets-insert-feature-template "New" "" "")`; assert heading "New" has `JIRA_TYPE` "New Feature", `LABELS` "" and `BLOCKS` "" present; heading "Other" has no `JIRA_TYPE`.
  - Same for `insert-improvement-template` (`JIRA_TYPE` "Improvement") and `insert-story-template` (`JIRA_TYPE` "Story", `PARENT` "P-1").
  - `org-tickets-test--story-template-prompts-fix-version`: `(interactive-form 'org-tickets-insert-story-template)` string contains `"Fix Version"`.
- [ ] **Step 2:** Run `make test`; the three heading tests FAIL (properties land on "Other").
- [ ] **Step 3:** Implement `org-tickets--insert-ticket-template`; rewrite the three commands on it (keep existing property sets and the existing empty-string skips for FIX_VERSION/DUE_DATE).
- [ ] **Step 4:** `make test` green.
- [ ] **Step 5:** Commit "Templates: put properties on the inserted heading".

### Task 2: BLOCKS update matches keys exactly

**Files:** `org-tickets-parse.el` (`--resolve-blocked-by-in-org`). Test `test/org-tickets-test-parse.el`.

**Interfaces:** Produces `(org-tickets--ensure-blocks-entry BLOCKER-KEY KEY)` — adds KEY to BLOCKER-KEY's BLOCKS csv unless already a member (exact `member` on `split-string … "," t`). `--resolve-blocked-by-in-org` loops and calls it (≤ 3 nesting levels).

- [ ] **Step 1: Failing test** `org-tickets-test--blocked-by-adds-key-that-is-a-prefix-of-existing`: PROJ-1 has `BLOCKED-BY: PROJ-5`, PROJ-5 has `BLOCKS: PROJ-12`; after resolve, PROJ-5 BLOCKS = `"PROJ-12,PROJ-1"`. Also `…-is-idempotent`: run twice → `"PROJ-12,PROJ-1"`.
- [ ] **Step 2:** FAIL (BLOCKS stays `"PROJ-12"`).
- [ ] **Step 3:** Implement as above.
- [ ] **Step 4:** Green. **Step 5:** Commit "BLOCKS: match keys exactly".

### Task 3: Accept Jira keys with digits/underscores

**Files:** `org-tickets-parse.el` (`--valid-ticket-key-p`). Test `test/org-tickets-test-parse.el`.

- [ ] **Step 1: Failing test** `org-tickets-test--valid-ticket-key-forms`: non-nil for `"PROJ-1" "AB2-12" "A_B-7"`; nil for `"2AB-1" "ab-1" "PROJ-" "PROJ-1x" "-1" nil`.
- [ ] **Step 2:** FAIL on `AB2-12`.
- [ ] **Step 3:** Regex `"\\`[A-Z][A-Z0-9_]*-[0-9]+\\'"`.
- [ ] **Step 4:** Green. **Step 5:** Commit "Accept project keys with digits".

### Task 4: List items keep block order and paragraph breaks

**Files:** `org-tickets-convert.el` (`--convert-to-adf-list-item`, `--build-inline-nodes`, delete `--plain-list-p`); `org-tickets-adf-import.el` (`--adf-list-item-to-org`). Test `test/org-tickets-test-list-continuation.el`.

**Interfaces:** `--convert-to-adf-list-item` converts item contents in document order through the dispatcher (nested plain-lists already dispatch to `--convert-to-adf-list`). `--build-inline-nodes` drops leading whitespace from the paragraph's first plain-text run. `--adf-list-item-to-org` joins two consecutive non-list blocks with `"\n\n"`, otherwise `"\n"`.

- [ ] **Step 1: Failing tests**
  - `org-tickets-test--list-item-content-after-nested-list-keeps-order`: block types of the first listItem of `"- a\n  - nested\n\n  after nested\n- b"` are `("paragraph" "bulletList" "paragraph")`, last paragraph text `"after nested"`.
  - `org-tickets-test--list-item-second-paragraph-not-indented`: second paragraph of `"- a\n\n  second para"` has text `"second para"`.
  - Round-trip fixpoints (3 cycles) for `"- a\n\n  second para"` and `"- a\n  - nested\n\n  after nested\n- b"`.
- [ ] **Step 2:** FAIL.
- [ ] **Step 3:** Implement as in Interfaces.
- [ ] **Step 4:** Green (all existing round-trip and continuation tests included). **Step 5:** Commit "Lists: keep item block order and paragraph breaks".

### Task 5: Commands and sync never move the user's point

**Files:** `org-tickets-parse.el` (`--with-ticket-at-key`); `org-tickets-sync.el` (`--inherit-due-date`, callers); `org-tickets-api.el` (`--load-issue-types-from-document`); `org-tickets-cmd.el` (`org-tickets-refresh-issue-types`). Tests `test/org-tickets-test-cmd.el`, `test/org-tickets-test-sync.el`.

**Interfaces:** `org-tickets--with-ticket-at-key` wraps its body in `save-excursion` (docstring updated; drop now-redundant outer `save-excursion` callers). `--load-issue-types-from-document` reads the keyword with `(org-collect-keywords '("JIRA_ISSUE_TYPES"))` — no point movement, ignores src blocks. `org-tickets-refresh-issue-types` signals `user-error` unless `(derived-mode-p 'org-mode)`.

- [ ] **Step 1: Failing tests**
  - `org-tickets-test--block-link-keeps-point`, `…set-fix-version-keeps-point`, `…update-story-sizing-keeps-point`: two tickets, point inside the second's body, run `org-tickets-add-block-link`/`org-tickets-set-fix-version`/`org-tickets-update-story-sizing` against the *first* key with network stubs (`org-tickets--api-request` → nil, `org-tickets--async-create-link` → call callback); assert `(point)` unchanged.
  - `org-tickets-test--with-ticket-at-key-narrowed`: buffer narrowed to ticket B; `(org-tickets--with-ticket-at-key "A" t)` returns nil and point/narrowing unchanged (Review Focus 1).
  - `org-tickets-test--load-issue-types-keeps-point-and-skips-src`: buffer with the keyword inside `#+BEGIN_SRC org … #+END_SRC` only → returns nil; with a real keyword line → returns the parsed alist; point unchanged in both.
  - `org-tickets-test--refresh-issue-types-requires-org-buffer`: in a `fundamental-mode` temp buffer → `user-error`, buffer still empty.
- [ ] **Step 2:** FAIL.
- [ ] **Step 3:** Implement; `--inherit-due-date` uses `--with-ticket-at-key` instead of a bare `goto-char`.
- [ ] **Step 4:** Green. **Step 5:** Commit "Preserve point in key lookups and issue-type loading".

### Task 6: Test hygiene bugs

**Files:** `test/org-tickets-test-headings-pull.el`, `test/org-tickets-test-attachments-upload.el`, `test/org-tickets-test-sync-sprint.el`, `test/org-tickets-test.el`, `test/org-tickets-test-attachments-sync.el`.

- [ ] **Step 1:** headings-pull: add `(require 'org-tickets-test-roundtrip)`. Verify: `emacs --batch -L . -L test -l org-tickets-test-headings-pull.el -f ert-run-tests-batch-and-exit` → 0 unexpected.
- [ ] **Step 2:** `attach-remove-no-attach-dir` / `-file-not-found`: stub `org-tickets--get-attachments` (→ nil) and `org-tickets--delete-attachment`; assert the specific error message (`"not found in attachment directory or Jira"`). Move them to `test/org-tickets-test-cmd.el`.
- [ ] **Step 3:** `sprint-sent-as-id-in-create`: let-bind `org-tickets--issue-type-ids`, stub `ensure-issue-types` with `#'ignore`. `sprint-cache-is-cleared-between-syncs` and the sprint-cache test in `test/org-tickets-test.el`: let-bind `org-tickets--sprint-cache` to a non-nil value, then assert cleared.
- [ ] **Step 4:** `ensure-org-attach-id-no-inheritance`: `with-temp-buffer` + `(let ((org-id-track-globally nil)) …)`; no `find-file`.
- [ ] **Step 5:** Each changed file passes standalone (command above); `make test` green. Commit "Tests: isolate global state and network".

---

## Tier 2 — Dead code and simplification (behavior unchanged; existing suite is the guard)

### Task 7: convert.el

**Files:** `org-tickets-convert.el`.

- [ ] **Step 1:** Delete `--convert-to-adf-item`, `--convert-to-adf-nil`, `-org-data`, `-section`, `-default` and the bold/italic/strike-through/underline wrappers; dispatcher arms: `` (`nil nil) ``, `org-data`/`section`/unknown fall to `_` (map over contents), mark types call `--convert-inline-marked` inline, one `(or `code `verbatim `inline-src-block `export-snippet)` arm, one arm each for the example-block/fixed-width and statistics-cookie/latex-fragment pairs.
- [ ] **Step 2:** Table header flag out of the dispatcher: `--convert-to-adf-content (element)` (no `is-header`); `--convert-to-adf-table` calls `--convert-to-adf-table-row ROW HEADER-P` directly, which calls `--convert-to-adf-table-cell CELL HEADER-P`; row and cell nodes built with `--adf-node`.
- [ ] **Step 3:** `--build-adf-description`: `unless`/`string-empty-p`, single `let`, `(list …)` not `append`.
- [ ] **Step 4:** Green. Commit "convert: fold wrappers into the dispatcher".

### Task 8: api.el, async.el, fields.el

**Files:** those three.

**Interfaces:** `--resolve-sprint-value` returns nil for nil/`""` first, so callers drop their guards. Produces `(org-tickets--with-sprint-field FIELDS SPRINT)` → FIELDS with the sprint field replaced. `--parse-sprint-from-jira-response`: `(when (consp data) (alist-get-name (car data)))`.

- [ ] **Step 1: Test first** (no coverage exists): `org-tickets-test--parse-sprint-from-response` with JSON fixtures: array of two sprints → first name; `[]` → nil; `null` → nil.
- [ ] **Step 2:** Apply: empty-sprint early return + drop 3 guards; `--with-sprint-field` for create/update; sprint parse simplification; numeric-id branch `(and (numberp id) id)` with `string-match-p "\\`[0-9]+\\'"`; fold the nested `let` in `--get-sprints-for-project`; `--rate-limit-effective-max` one-liner; `--rate-limit-enqueue (state thunk)` for both queue appends; split `--ticket-fields` into `--create-only-fields` and `--clearable-fields`.
- [ ] **Step 3:** Docstrings: sprint cache shape `(("name" . ID) …)`; describe arguments instead of "as before"; drop "(Track C)"; fields.el json-null comment → pointer to `--encode-request-data`.
- [ ] **Step 4:** Green. Commit "api/async/fields: remove duplicated sprint and queue logic".

### Task 9: attachments.el and cmd.el

**Files:** those two; tests that stub removed functions.

**Interfaces:** Produces `(org-tickets--browse-url KEY)` (signals the base-url `user-error`), `(org-tickets--attachment-names KEY)` → `(LOCAL . REMOTE)`, `(org-tickets--local-attachment-current-p PATH SIZE)`. Removes `--ensure-org-attach-id`, `--ensure-org-attach-id-for-current-heading` (callers use `org-id-get-create`), `org-tickets-setup`.

- [ ] **Step 1:** Apply the above; drop the empty-thunks branches (async-batch already handles `nil`); extract download filtering/thunk building so each batch function is ≤ 3 levels and ≲ 30 lines; simplify `--get-attachments` to one expression; `--delete-attachment` docstring "Returns nil on success; signals on failure."; remove the history sentence from `attach-remove`'s docstring.
- [ ] **Step 2:** Update test stubs of removed functions to stub `org-id-get-create` or nothing.
- [ ] **Step 3:** Green. Commit "attachments/cmd: one ID path, shared helpers".

### Task 10: sync.el and sync-phases.el

**Files:** those two.

**Interfaces:** Produces `(org-tickets--link-thunk FROM TO)` → a `(lambda (done) …)` creating a Blocks link; `(org-tickets--at-ticket-marker TICKET &rest BODY)` macro (runs BODY at a live marker inside `save-excursion`, else returns nil); `(org-tickets--ticket-parent-key TICKET)` → PARENT property or the outline ancestor's key.

- [ ] **Step 1:** Delete `--apply-default-sprint-to-new` and its call; inline `--collect-phase-1-results`; rebuild `--async-sync-ticket-links` with `--link-thunk` (`append` + `seq-remove` self-links); use the marker macro at its four sites; split `--make-attachment-thunk` into `--attachment-upload-step` and `--attachment-refresh-step`; one `finish` closure in `--fire-ticket-put`; remove redundant `when`s; `--insert-story-heading` docstring and branch order.
- [ ] **Step 2:** Green. Commit "sync: shared link/marker helpers, drop dead sprint pass".

### Task 11: import.el, adf-import.el, core.el

**Files:** those three; tests constructing removed slots.

- [ ] **Step 1:** Remove ticket slots `id`, `org-node` and async state slot `retry-after-time` (+ setters and the test assertions/args that only touch them).
- [ ] **Step 2:** import.el: `--first-fix-version-name` and similar via `org-tickets--ensure-list`; heading level `(if (equal type "Story") "** " "* ")`; drop `mapconcat` nil guards and the `fboundp 'org-entry-delete` guard; `let` for independent bindings; extract `--write-ticket-properties (TICKET)` used by `--issue-to-org` and `--update-org-heading-from-ticket`. adf-import.el: delete `--adf-doc-to-org`; drop `(when attrs …)` guards.
- [ ] **Step 3:** Green. Commit "import: shared property writer, remove dead slots".

### Task 12: Non-empty property helpers

**Files:** `org-tickets-parse.el`, `org-tickets-sync.el`, `org-tickets-sync-phases.el`.

**Interfaces:** Move `org-tickets--heading-property (PROPERTY)` to parse.el and make it return nil for empty *or whitespace-only* values. Produces `(org-tickets--csv-property PROPERTY)` → list (empty list for nil/blank). `--all-features-exist-p` = `(seq-every-p #'org-tickets--ticket-has-key-p …)`.

- [ ] **Step 1: Failing test** `org-tickets-test--whitespace-only-properties-are-empty` (Review Focus 5): ticket with `:LABELS:   `, `:PARENT:  `, `:SPRINT:  ` parses with labels nil, parent nil, sprint nil.
- [ ] **Step 2:** FAIL (whitespace kept).
- [ ] **Step 3:** Use the helpers in `--parse-ticket-at-point` (now `let`, no `node` alias, `--valid-parent-property` extracted), `--find-parent-ticket-key`, `--ticket-buffer-key` and the ~20 `(> (length x) 0)` sites listed in the spec.
- [ ] **Step 4:** Green. Commit "Shared non-empty property helpers".

---

## Tier 3 — Org-native parsing

### Task 13: Lookup, description region, links, heading iteration

**Files:** `org-tickets-parse.el`, `org-tickets-import.el`, `org-tickets-sync-phases.el`, `org-tickets-sync.el`. Tests: parse, headings-push/pull, sync-phases-related tests.

**Interfaces:**
- `(org-tickets--find-ticket-by-key KEY)` = `(org-find-property "JIRA_KEY" KEY)` (heading position).
- `(org-tickets--description-region)` → `(BEG . END)` for the ticket heading at point, no point movement: BEG is the end of the `:END:` line from `org-get-property-block` (or contents-begin), END is `--description-end`. `--get-ticket-description` takes no argument and trims that region; `--update-org-heading-from-ticket` deletes/reinserts it (keep the existing newline semantics). Update the tests that pass an element.
- `--description-attachment-filenames` uses `org-element-map` over `link` objects of type "attachment" in a temp org buffer.
- `--parse-document` and `--inherit-parent-properties-in-buffer` iterate with `org-map-entries`.

- [ ] **Step 1: Failing tests**
  - `org-tickets-test--find-ticket-by-key-returns-heading` → `(org-at-heading-p)` at the result; `…-ignores-body-mentions`: `See PROJ-1` in another ticket's body does not match (Review Focus 3).
  - `org-tickets-test--attachment-links-in-src-blocks-ignored`: `[[attachment:a.png]]` only inside `#+BEGIN_SRC` → no filenames (Review Focus 4).
- [ ] **Step 2:** FAIL. **Step 3:** Implement. **Step 4:** Green (every heading/pull/import test included).
- [ ] **Step 5:** Commit "Use org APIs for lookup, drawers, links and heading iteration".

---

## Tier 4 — Abstractions

### Task 14: Break the sync ⇄ sync-phases cycle

**Files:** Create `org-tickets-links.el` (link creation: `--async-create-link` moved from api.el, `--link-done-callback`, `--link-thunk`, `--async-sync-ticket-links`), `org-tickets-inherit.el` (`--heading-property`-based inheritance: `--fetch-parent-issue` … `--inherit-due-date`, the remote parent cache with `(org-tickets--with-parent-cache &rest BODY)`). Move `--set-org-*`, `--ticket-buffer-key`, `--resolve-blocked-by-in-org` into sync-phases.el. Update `org-tickets.el` requires, `docs/dev/modules.md`, Makefile needs nothing (deps are derived).

- [ ] **Step 1:** Moves only; delete every `declare-function`/`defvar` forward declaration that the moves make unnecessary. No file may `require` a module that requires it back.
- [ ] **Step 2:** Verify no cycles: `grep -h "^(require 'org-tickets" org-tickets-*.el` per file matches `deps.mk` with no back edges. Green. Commit "Split links and inheritance out of sync".

### Task 15: Issue accessors in one place

**Files:** `org-tickets-api.el` (new section), callers in sync.el/sync-phases.el/import.el/inherit.el.

**Interfaces:** Each takes a full issue response: `org-tickets--issue-due-date`, `--issue-fix-version`, `--issue-sprint`, `--issue-attachments`. Delete `--fields-due-date`, `--extract-*-from-response`, `--parse-sprint-from-jira-response`, and move `--first-fix-version-name`'s logic into `--issue-fix-version`.

- [ ] **Step 1: Test** `org-tickets-test--issue-accessors` on one JSON issue fixture (all four fields present) and one with all four absent → nils.
- [ ] **Step 2:** Implement and switch callers. Green. Commit "One set of Jira issue accessors".

### Task 16: One attachment shape

**Files:** `org-tickets-attachments.el` (accessors), `org-tickets-import.el` (`--parse-attachments` removed; ticket `attachments` holds raw Jira alists), `org-tickets-convert.el` (`--attachment-media-uuid`), `org-tickets-adf-import.el`/import id-map.

**Interfaces:** Accessors on raw Jira attachment alists: `--attachment-filename`, `--attachment-id`, `--attachment-content-url`, `--attachment-size`, `--attachment-created`, `--attachment-media-id`. No other code reads attachment keys directly (`grep -n '"filename"\|'"'"'filename\|"mediaApiFileId"\|"size"\|"created"'` hits only the accessors).

- [ ] **Step 1:** Implement; convert touched test fixtures to `org-tickets-test--json`.
- [ ] **Step 2:** Green. Commit "Attachments: one shape, accessors only".

### Task 17: Ticket-record create/update

**Files:** `org-tickets-api.el`, sync.el/inherit.el/sync-phases.el callers; tests stubbing these.

**Interfaces:** `(org-tickets--create-ticket TICKET)` → new key; `(org-tickets--update-ticket TICKET)` → PUT of `--ticket-fields`. Sprint/attachments/due-date come from the record's slots. `org-tickets-update-story-sizing` uses `(org-tickets--update-ticket (org-tickets--ticket-create :key K :story-points P :clear-story-points (not P)))` instead of a hand-built PUT.

- [ ] **Step 1:** Rewrite inheritance `create-story` tests to stub `org-tickets--api-request` and assert the captured payload (`duedate`, `fixVersions`) instead of positional args.
- [ ] **Step 2:** Implement; update callers. Green. Commit "create/update take ticket records".

### Task 18: Config accessors and document I/O out of api.el

**Files:** `org-tickets-api.el`, `org-tickets-core.el`, `org-tickets-parse.el` (issue-type keyword read/write), async.el/attachments.el/fields.el/cmd.el references; test fixtures binding mirror vars.

**Interfaces:** Remove `org-tickets--jira-base-url`, `--project-key`, `--project-id` mirrors and the `--require-config` macro. Produce `(org-tickets--base-url)`, `(org-tickets--project-key)`, `(org-tickets--project-id)` (return the defcustom or `user-error`), `(org-tickets--credentials)` → `(USER . TOKEN)` cached per host in `org-tickets--credentials-cache`. `--fetch-issue-types` returns the alist only; `--ensure-issue-types` and `org-tickets-refresh-issue-types` call parse.el's `--load-issue-types`/`--save-issue-types` (document I/O).

- [ ] **Step 1: Failing test** `org-tickets-test--base-url-change-takes-effect`: one request with base URL A, `setq org-tickets-base-url` B, next request's URL starts with B (stub `url-retrieve`).
- [ ] **Step 2:** FAIL. **Step 3:** Implement; replace mirror-var bindings in tests with defcustom bindings.
- [ ] **Step 4:** Green. Commit "Read config directly; API layer no longer writes buffers".

### Task 19: Sync-result record and small reshapes

**Files:** `org-tickets-sync-phases.el`, `org-tickets-core.el`, `org-tickets-adf-import.el`, `org-tickets-import.el`, `org-tickets-api.el`.

**Interfaces:**
- `org-tickets--define-record org-tickets--sync-result (key ticket attachments sprint due-date is-new error)`; phase-1 thunks always set `ticket`; `--phase-1-result-description` reads `(org-tickets--ticket-description (org-tickets--sync-result-ticket r))`; `--apply-plist-updates` takes an accessor.
- `(org-tickets--parse-adf-description ADF &optional ID-MAP)` binds `org-tickets--adf-attachment-id-map` itself; callers stop binding it.
- `--get-sprints-for-project` → `(org-tickets--fetch-board-sprints BOARD-ID)` always returning `(NAME . ID)`.
- `org-tickets--doc` keeps only `tickets`; `--doc-features`/`--doc-children` become `seq-filter` functions (blank type: neither).

- [ ] **Step 1:** Implement; update tests that build result plists or `doc-create` with features/children.
- [ ] **Step 2:** Green. Commit "Records for sync results; explicit ADF id-map".

---

## Tier 5 — Tests

### Task 20: One shared helper set in fixtures

**Files:** `test/org-tickets-test-fixtures.el` (gains helpers), every test file that defines/borrows them, `docs/dev/testing.md` (helper list).

**Interfaces (fixtures):** `--adf-blocks ORG`, `--adf-outline ORG`, `--adf-texts NODES`, `--adf-heading-level BLOCK`, `--adf-first-paragraph ORG`, `--inline-summary ORG`, `--adf-doc &rest BLOCKS`, `--adf-heading LEVEL TEXT &optional MARKS`, `--adf-para TEXT`, `--pull ADF-OR-JSON`, `--roundtrip ORG`, `--roundtrip-n ORG N`, `--ticket-text STARS TYPE TITLE BODY &optional KEY`, `--with-org-buffer-at TEXT TARGET &rest BODY`, `--prop-of KEY PROP`, `--parse-tickets TEXT`, `--description-of TEXT TITLE`, `--parent-types`.

- [ ] **Step 1:** Move/merge; delete duplicates (`--flatten-adf-text` ×2, `--adf-top-content`, `--blocks`, `--block-level`, `--due-date-of`, `--fix-version-of`, `--adf-paragraph-description`, `--pull-list`, `--normalized-adf`). No test file `require`s another test file except fixtures.
- [ ] **Step 2:** Every test file passes standalone (loop over `test/org-tickets-test-*.el` with the single-file command); `make test` green. Commit "Tests: one shared helper set".

### Task 21: Production-shaped fixtures

**Files:** fixtures (`--make-get-response` via JSON), and the hand-built API alists listed in the spec/tests reports across parse, import, convert, sync, sync-due-date, sync-sprint, sync-links, sync-flow-phase2, attachments-*.

- [ ] **Step 1: Coverage check first** — make the pagination test use JSON `"isLast": false/true`; temporarily delete the `:json-false` guard in `--get-sprints`/`--fetch-board-sprints` and confirm the test FAILS; restore.
- [ ] **Step 2:** Convert the rest; delete `parse-jira-issue-with-json-vectors` and the dotted-pair sprint case.
- [ ] **Step 3:** Green. Commit "Tests: JSON fixtures everywhere".

### Task 22: Sync harness

**Files:** fixtures, sync-flow, sync-links, inheritance, async, attachments-async.

**Interfaces:** `(org-tickets-test--with-fake-config &rest BODY)`; `(org-tickets-test--fake-jira-handler &rest ARGS)` with `:get` (response or function of endpoint), `:post-keys` (popped per create), `:log` (symbol collecting `(METHOD ENDPOINT DATA)`); `with-sync-mocks` takes `:real (FN …)` to leave named functions unstubbed and documents its `get-ticket` routing; `--run-sync` also neutralizes `org-tickets--progress-install`'s global mode-line write; `(org-tickets-test--insert-ticket LEVEL TITLE &rest PROPS)` (to `point-max`), with `--insert-feature`/`--insert-story` as wrappers and `--insert-child` deleted; one `url-retrieve` fake (`with-url-responses`, plus `:deferred`).

- [ ] **Step 1:** Implement; replace the 16 run-sync copies, the per-test request counters, sync-links' hand-rolled harness (129/173), and match payloads by `summary` not `issuetype` shape.
- [ ] **Step 2:** Green. Commit "Tests: one sync harness".

### Task 23: Remove weak tests, move misplaced ones

**Files:** all test files; `docs/dev/testing.md` table (add `org-tickets-api.el`, `org-tickets-sync-phases.el`, macro, options rows; new modules from Task 14).

- [ ] **Step 1:** Delete the vacuous/duplicate/implementation-detail tests enumerated in the two test reviews (keep the stronger twin named there). Strengthen: UTF-8 encoding asserts unibyte + decodes; hyperlink exact `[[url][KEY]]`; inlineCard-vs-link pinned to emitted shape; `condition-case`+`(should nil)` → `should-error`; one-char search targets lengthened; `ensure-list` asserted with `equal`; progress counters → exact rendered string; batching tests assert request order not batch-call counts; drop the `x-*-selection` stubs.
- [ ] **Step 2:** Move tests to the file for the module they test; `test/org-tickets-test.el` holds only `require`s; rename "Task A1…A6" headers and drop placeholder author boilerplate; add missing docstrings.
- [ ] **Step 3:** Green; every test file passes standalone; no test file > 750 lines. Commit "Tests: remove weak tests, organize by module".

---

## Final

- [ ] Whole-branch review (subagent-driven-development's final reviewer), `make clean && make build && make test && make lint` green, `docs/dev/*` current.
