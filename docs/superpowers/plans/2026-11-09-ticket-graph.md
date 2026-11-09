# Ticket Dependency Graph Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `M-x org-tickets-graph` renders the current ticket org file's tickets and dependencies as an SVG beside the file, with features on top and dependency loops in red.

**Architecture:** A new module `org-tickets-graph.el` in three layers, each a task: a pure graph model built from `org-tickets--parse-document` plus loop detection; a pure Graphviz DOT text renderer; and an interactive command that pipes the DOT text through the `dot` program, writes the SVG, displays it and reports loops.

**Tech Stack:** Emacs Lisp (Emacs ≥ 29.1, Org ≥ 9.6), ERT, Graphviz `dot` (external program, not a Lisp dependency).

**Spec:** Approved in conversation on 2026-11-09 (no separate design doc — sized as a small change). The approved description is reproduced verbatim in "Requirements" below; it is the binding authority.

## Requirements (approved description)

- Command `M-x org-tickets-graph` in a ticket org file writes `<file>.svg` beside the org file (`tickets.org` → `tickets.svg`) and opens it in another Emacs window. Unsaved (non-file) buffer → asks to save first. If `dot` is missing → says so. Program comes from `org-tickets-graph-dot-program` (default `"dot"`).
- Nodes: every ticket in the buffer, a rounded rectangle labeled with key (bold), heading, and due date when there is one. Unsynced tickets show "(new)" with a dashed border. Headings shortened to about 28 characters with "…" (adjustable), after stripping a "Type:" prefix the way import does.
- Features and Improvements (and New Feature / Epic — all parent types): gold, double outline, larger, pinned to the top row, labeled with their type ("FEATURE · PROJ-100").
- Arrows from blocker to blocked so everything flows up toward its feature; from BLOCKS, BLOCKED-BY and each story's parent (PARENT property, or the feature it sits under). Duplicate links drawn once. A link to a ticket not in the file shows as a small grey dashed box with just its key.
- Every arrow that is part of a loop is thick red, including a ticket that blocks itself. The echo area reports what it found, e.g. "1 cycle: PROJ-102 → PROJ-103 → PROJ-102", or "no cycles".

## Global Constraints

- Read `CLAUDE.md` first; its Elisp Style rules are requirements: no `cl-lib`; ≤ 3 nesting levels; functions ≲ 30 lines; `let*` only for dependent bindings; `when`/`unless` over one-branch `if`; `pcase` for known values; docstring on every function and test; `org-tickets--` private prefix, `org-tickets-` public.
- No file over 750 lines. No new Lisp dependencies.
- Tests assert behavior (inputs → outputs), never internals; use helpers in `test/org-tickets-test-fixtures.el` (`org-tickets-test--ticket-text`, `org-tickets-test--with-stubs`, …). No test reads `~/.authinfo` or the network; no test needs `dot` except one rendering test that skips (`ert-skip`) when `dot` is absent. Every test file passes standalone.
- Every shell running make/emacs needs `export MACOSX_DEPLOYMENT_TARGET=27.0`. Verify each task with `make test` (0 unexpected) and `make lint` (no checkdoc warnings). Never delete `.elc`.
- Commit each task with exactly: `GIT_AUTHOR_NAME="Neil Locketz" GIT_AUTHOR_EMAIL="neil@nlocketz.com" GIT_COMMITTER_NAME="Neil Locketz" GIT_COMMITTER_EMAIL="neil@nlocketz.com" git commit -m "<message>"` — no Co-Authored-By trailer. Never write real employer identifiers into tracked files; use `PROJ-` placeholders.
- Ticket levels: parent types at outline level 1, other tickets at level 1–2 (`org-tickets--check-ticket-level`, enforced by the parser).
- Parsing (`org-tickets--parse-document`) creates heading markers; release them (set to nil) when the graph is built.

## Review Focus

1. **Unsynced parents:** a story under a feature that has no JIRA_KEY yet must still get its parent arrow (to the "(new)" node). Pinned in Task 1.
2. **Odd characters in headings** (`&`, `<`, `>`, `"`) must not break the DOT/HTML label. Pinned in Task 2.
3. **Paths with spaces** in the org file name must render. Pinned in Task 3.
4. **Re-running** the command when the SVG is already open must show the new graph, not a stale buffer. Pinned in Task 3.
5. **Empty file** (no tickets) must produce a valid, empty graph rather than an error. Pinned in Tasks 2 and 3.

---

### Task 1: Graph model and loop detection

**Files:** Create `org-tickets-graph.el` (header/commentary/provide like other modules; requires `org-tickets-core`, `org-tickets-parse`, `org-tickets-import` for `--strip-type-prefix`). Create `test/org-tickets-test-graph.el` (requires fixtures; add `(require 'org-tickets-test-graph)` to `test/org-tickets-test.el`). Add `(require 'org-tickets-graph)` to `org-tickets.el` after `org-tickets-import`.

**Interfaces (produces):**
- `(org-tickets--graph-model)` — call with point anywhere in an org buffer; returns a plist `(:nodes NODES :edges EDGES)`. Parses with `org-tickets--parse-document`, releases markers.
  - NODES: list of plists in document order, then external nodes: `(:id ID :key KEY-or-nil :type TYPE :title TITLE :due DUE-or-nil :parent-p BOOL :new-p BOOL :external-p BOOL)`. ID is the key, or `"new-N"` (N = 1, 2, … in document order) for unkeyed tickets. TITLE is the summary after `org-tickets--strip-type-prefix` (untruncated). External nodes (keys referenced but not in the buffer) have `:external-p t`, `:key`/`:id` = the key, other fields nil.
  - EDGES: list of `(FROM . TO)` node-id pairs meaning FROM blocks TO; no duplicates; sources: each ticket's BLOCKS (`self . target`), BLOCKED-BY (`source . self`), and parent (`self . parent`) where parent is the explicit PARENT key, else the nearest outline-ancestor ticket heading (resolved by heading position, so an unkeyed parent's `"new-N"` id is used).
- `(org-tickets--graph-cycles EDGES)` — returns a list of cycles, each a list of node ids in loop order (strongly connected components with ≥ 2 nodes, plus single nodes with a self-edge). Iterative or recursive Tarjan/Kosaraju is the implementer's choice (no cl-lib; respect nesting limits by extracting helpers).
- `(org-tickets--graph-cycle-edges EDGES)` — subset of EDGES whose both ends lie in the same cycle (includes self-edges).

- [ ] **Step 1: Failing tests** (behavioral, on org text built with `org-tickets-test--ticket-text`):
  - `graph-model-nodes-in-document-order`: a Feature PROJ-100 (due 2026-12-01) with stories PROJ-101 and an unkeyed story → node ids `("PROJ-100" "PROJ-101" "new-1")`; PROJ-100 `:parent-p t`, `:due "2026-12-01"`; the unkeyed one `:new-p t`.
  - `graph-model-strips-type-prefix`: heading "Story: Login form" of type Story → `:title "Login form"`.
  - `graph-model-edges-from-blocks-blocked-by-and-parent`: PROJ-101 BLOCKS PROJ-102, PROJ-103 BLOCKED-BY PROJ-102, both stories under PROJ-100 → edges include `("PROJ-101" . "PROJ-102")`, `("PROJ-102" . "PROJ-103")`, `("PROJ-101" . "PROJ-100")`, `("PROJ-103" . "PROJ-100")`.
  - `graph-model-deduplicates-edges`: PROJ-101 BLOCKS PROJ-102 *and* PROJ-102 BLOCKED-BY PROJ-101 → exactly one `("PROJ-101" . "PROJ-102")`.
  - `graph-model-unsynced-parent-gets-edge` (Review Focus 1): unkeyed Feature with a keyed story → edge `("PROJ-201" . "new-1")`.
  - `graph-model-external-keys-become-external-nodes`: BLOCKS PROJ-999 not in buffer → node `:id "PROJ-999" :external-p t` and edge to it.
  - `graph-cycles-finds-two-node-loop`, `graph-cycles-finds-self-loop`, `graph-cycles-none-for-dag`, `graph-cycle-edges-only-loop-members` (loop A⇄B plus C→A: cycle edges are A→B and B→A only).
- [ ] **Step 2:** Run `make compile` then `emacs --batch -L . -L test -l org-tickets-test-graph.el -f ert-run-tests-batch-and-exit` → FAIL (void-function).
- [ ] **Step 3:** Implement the three functions as specified.
- [ ] **Step 4:** Graph tests pass; `make test`, `make lint` clean.
- [ ] **Step 5:** Commit "Graph: model tickets and dependency loops".

### Task 2: DOT text

**Files:** `org-tickets-graph.el`, `test/org-tickets-test-graph.el`.

**Interfaces:**
- Consumes Task 1's model plist and `org-tickets--graph-cycle-edges`.
- Produces `(defcustom org-tickets-graph-title-width 28 …)` (integer, `:group 'org-tickets`), and `(org-tickets--graph-dot MODEL)` → a complete DOT string. Exact style (option C, approved):
  - Graph: `digraph tickets {`, `rankdir=TB; nodesep=0.4; ranksep=0.6;`
  - Default node: `shape=box, style="rounded,filled", fillcolor="#ffffff", color="#888888", fontname="Helvetica", fontsize=12`; default edge: `arrowsize=0.8, color="#666666", dir=back`.
  - Each edge `(FROM . TO)` is emitted as `"TO" -> "FROM"`. Graphviz ranks TO above FROM, and the default `dir=back` puts the arrowhead on TO, so the drawn arrow points from blocker FROM up to blocked TO.
  - Parent-type node: `fillcolor="#fff2cc", color="#bf9000", penwidth=2.5, peripheries=2, fontsize=15, margin="0.3,0.15"`; all parent nodes in one `{ rank=min; … }`.
  - New node: `style="rounded,filled,dashed"`. External node: `style="rounded,dashed", fillcolor="#ffffff", color="#aaaaaa", fontcolor="#888888", fontsize=10`, label = key only.
  - Cycle edge: `color="#d62728", penwidth=2.5`.
  - Labels are Graphviz HTML labels: `<<B>KEY</B><BR/>TITLE<BR/><FONT POINT-SIZE="10">due YYYY-MM-DD</FONT>>`; parent nodes' first line is `<B>TYPE-UPCASED · KEY</B>`; new nodes show `(new)` in place of the key; the due line only when present. TITLE truncated to `org-tickets-graph-title-width` characters with `…` (total length = width when truncated). Text is HTML-escaped (`&` `<` `>` `"`).
- [ ] **Step 1: Failing tests:** `graph-dot-parent-node-style-and-rank`; `graph-dot-label-key-title-due`; `graph-dot-truncates-long-title` (width honored, ends with `…`); `graph-dot-new-node-dashed-labelled-new`; `graph-dot-external-node-style`; `graph-dot-edge-points-blocker-to-blocked` (model edge `("PROJ-101" . "PROJ-100")` → text `"PROJ-100" -> "PROJ-101"`); `graph-dot-cycle-edges-red`; `graph-dot-escapes-html` (Review Focus 2: title `A & <B> "c"`); `graph-dot-empty-model-is-valid` (Review Focus 5: starts `digraph tickets {`, ends `}`, no nodes). Where `dot` is installed, also assert `graph-dot-…` output is accepted: run `dot -Tsvg` via `call-process-region` in one test and `ert-skip` when `(executable-find "dot")` is nil.
- [ ] **Steps 2–5:** RED, implement (extract label/style helpers to stay within nesting/length rules), GREEN, `make test`/`make lint`, commit "Graph: render DOT with feature, new, external and loop styles".

### Task 3: Command, rendering, docs

**Files:** `org-tickets-graph.el`, `test/org-tickets-test-graph.el`, `README.md` (new "Dependency Graph" section after "Ticket Levels"), `docs/dev/modules.md` (module table row + layering), `docs/dev/testing.md` (table row).

**Interfaces:**
- Produces `(defcustom org-tickets-graph-dot-program "dot" …)` (string) and `;;;###autoload (defun org-tickets-graph () (interactive) …)`:
  - `user-error` unless `(derived-mode-p 'org-mode)`; `user-error` "Save the buffer to a file first" unless `buffer-file-name`.
  - `user-error` naming the program and the variable when `(executable-find org-tickets-graph-dot-program)` is nil.
  - Writes `(concat (file-name-sans-extension buffer-file-name) ".svg")` by piping `(org-tickets--graph-dot (org-tickets--graph-model))` to `PROGRAM -Tsvg -o OUT` with `call-process-region`; non-zero exit → `user-error` with dot's stderr text.
  - Displays OUT with `find-file-other-window`; if a buffer already visits OUT, it is reverted without confirmation so the new graph shows (Review Focus 4).
  - Messages `"org-tickets: wrote FILE — no cycles"` or `"org-tickets: wrote FILE — N cycle(s): A → B → A; …"` (each cycle in loop order, repeating its first node).
  - Returns OUT.
- [ ] **Step 1: Failing tests:** `graph-command-requires-file` (unsaved org buffer → user-error); `graph-command-missing-dot` (program bound to a nonexistent name → user-error mentioning `org-tickets-graph-dot-program`); `graph-command-writes-svg-beside-file` (skip without dot; temp dir **with a space in its name** (Review Focus 3), org file with a feature, a story and a loop → `tickets.svg` exists, contains `<svg` and the red `#d62728`, message mentions "1 cycle"); `graph-command-rerun-refreshes-open-svg` (skip without dot; run twice with a change in between → the visiting buffer shows the new content); `graph-command-empty-file` (skip without dot; no tickets → SVG written, "no cycles"). Stub `find-file-other-window` only where a test must not open windows; prefer asserting on the file and the returned path.
- [ ] **Steps 2–4:** RED, implement, GREEN; `make clean && make build`, `make test`, `make lint`.
- [ ] **Step 5:** Docs: README section (what it draws, styles, loops in red, output path, `dot` requirement, the two defcustoms); modules.md row; testing.md row. Commit "Graph: org-tickets-graph command".
