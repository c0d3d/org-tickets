# org-tickets

Manage Jira tickets directly from Org-mode files.

## Overview

org-tickets allows you to track and manage Jira tickets using Org-mode. Features include:

- **Two-way sync**: Sync tickets between your org files and Jira
- **Attachment management**: Upload/download attachments between org-attach and Jira
- **Block relationships**: Track which stories block others
- **Story points**: Manage story sizing with automatic sizing-label management (`org-tickets-needs-sizing-label`)
- **Fix versions**: Track release versions (e.g., Aug2026, May2025)
- **Org-to-Jira conversion**: Automatic conversion of org content to Jira's Atlassian Document Format (ADF)

## Installation

### Via MELPA

```elisp
(require 'package)
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-refresh-contents)
(package-install 'org-tickets)
```

### Manual Installation

```bash
# Clone this repository
git clone https://github.com/c0d3d/org-tickets.git ~/.emacs.d/packages/org-tickets
```

Then add to your config:

```elisp
(add-to-list 'load-path "~/.emacs.d/packages/org-tickets")
(require 'org-tickets)
```

### Building from Source

```bash
make compile    # Byte-compile the package
make install    # Install to ~/.emacs.d/packages/
make test       # Run the test suite
```

## Configuration

Customize the `org-tickets` group (`M-x customize-group RET org-tickets`), or
set the options in your init file:

```elisp
(setopt org-tickets-base-url "https://yourcompany.atlassian.net"
        org-tickets-project-key "PROJ"
        org-tickets-project-id "12345")
```

Optional workflow settings:

| Option | Default | Purpose |
|--------|---------|---------|
| `org-tickets-needs-sizing-label` | `"NeedsSizing"` | Label kept on unsized tickets; `nil` disables it |
| `org-tickets-fix-version-months` | `("Feb" "May" "Aug" "Nov")` | Months allowed in `MONTHYYYY` Fix Versions |
| `org-tickets-default-sprint` | `nil` | Sprint ID or name for newly created tickets |
| `org-tickets-story-points-field` | `"customfield_10016"` | Your instance's story points field |
| `org-tickets-sprint-field` | `"customfield_10020"` | Your instance's sprint field |

### Authentication

Credentials are fetched from your `~/.authinfo` or `~/.authinfo.gpg` file:

```
machine yourcompany.atlassian.net login your@email.com password YOUR_API_TOKEN
```

Generate an API token from your Atlassian account settings.

Credentials are re-read from auth-source at the start of each command, so a
changed token takes effect on the next sync, import or refresh; changing
`org-tickets-base-url` to another host uses that host's entry.

## Usage

### Creating Tickets

Use the interactive commands to create org templates:

- `M-x org-tickets-insert-feature-template` - Insert a Feature template
- `M-x org-tickets-insert-improvement-template` - Insert an Improvement template
- `M-x org-tickets-insert-story-template` - Insert a Story template under a parent

### Syncing to Jira

With an org buffer containing ticket headings:

```elisp
M-x org-tickets-sync-to-jira
```

This will:
1. Create new tickets in Jira for headings without `JIRA_KEY` property
2. Update existing tickets if they've changed
3. Sync block relationships
4. Sync attachments (bidirectional)

### Managing Relationships

```elisp
M-x org-tickets-add-block-link
```

Add a "blocks" relationship between two stories.

### Sizing Stories

```elisp
M-x org-tickets-update-story-sizing
```

Update story points and automatically manage the sizing label (`org-tickets-needs-sizing-label`).

### Attachments

```elisp
M-x org-tickets-attach-add     ; Add attachment to current ticket
M-x org-tickets-attach-list    ; List attachments
M-x org-tickets-attach-open    ; Open attachment directory
M-x org-tickets-attach-remove  ; Remove attachment (from both Jira and local)
```

## Org Document Structure

Example org file with ticket structure:

```org
#+JIRA_ISSUE_TYPES: Story=10001,New Feature=10002,Improvement=10003

* Feature: User Authentication
:PROPERTIES:
:JIRA_TYPE: New Feature
:JIRA_KEY: PROJ-123
:FIX_VERSION: Aug2026
:END:
Description of the feature.

** Story: Login Form
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-124
:PARENT: PROJ-123
:BLOCKS: PROJ-125
:STORY_POINTS: 5
:END:
Story description.

** Story: Password Reset
:PROPERTIES:
:JIRA_TYPE: Story
:JIRA_KEY: PROJ-125
:PARENT: PROJ-123
:BLOCKED-BY: PROJ-124
:STORY_POINTS: 3
:END:
Story description.
```

### Ticket Levels

Features (and the other parent types: New Feature, Improvement, Epic)
must be top-level `*` headings; Stories and other tickets must be at
level 1 or 2.  Sync and pull stop with an error naming any ticket that
is deeper, since its description headings could not nest inside it.

### Dependency Graph

`M-x org-tickets-graph` draws the tickets in the current org file as a
dependency graph.  It writes an SVG beside the file (`tickets.org`
becomes `tickets.svg`) and opens it in another window; running it again
refreshes the open image.  The buffer must be saved to a file, and
[Graphviz](https://graphviz.org) must be installed.

- Every ticket is a rounded box with its key in bold, its heading
  (without a `Type:` prefix) and its due date when it has one.
- Parent types (Feature, New Feature, Improvement, Epic) are larger,
  gold, double-outlined and pinned to the top row, labeled like
  `FEATURE · PROJ-100`.
- Tickets without a key show `(new)` and have a dashed border.
- Arrows run from the blocker to the blocked ticket, so work flows up
  toward its feature.  They come from `BLOCKS`, `BLOCKED-BY` and each
  story's parent (its `PARENT` property, else the feature it sits
  under).  A link to a ticket that is not in the file shows as a small
  grey dashed box with just its key.
- Every arrow that is part of a dependency loop, including a ticket
  that blocks itself, is thick red.  The echo area lists the loops
  (`A → B → A`) or says there are none.

Two options adjust it:

```elisp
(setq org-tickets-graph-dot-program "dot") ; Graphviz program to run
(setq org-tickets-graph-title-width 28)    ; characters of heading shown
```

### Description Headings

Headlines under a ticket that have no `JIRA_TYPE` are part of its
description and push as Jira headings: `***` is h1, `****` is h2, and so
on down to h6.  The description ends at the first heading below it
that is itself a ticket.
`COMMENT` headlines (and their subtrees) are private notes: push skips
them, and pulling remote changes replaces the rest of the description
but keeps them, after the pulled text.  Plain `#` comment lines are not
kept; pull replaces them along with the description.
Commands such as `org-tickets-copy-link`, `org-tickets-pull-remote-changes`
and the attachment commands act on the owning ticket when run from
inside a description heading.

```org
** Story: Login Form
:PROPERTIES:
:JIRA_TYPE: Story
:END:
Intro text.
*** Requirements
**** Edge cases
```

### Ticket Properties

| Property | Description |
|----------|-------------|
| `JIRA_TYPE` | Ticket type: "New Feature", "Improvement", or "Story" |
| `JIRA_KEY` | Jira ticket key (e.g., "PROJ-123") |
| `FIX_VERSION` | Release version (e.g., "Aug2026") |
| `LABELS` | Comma-separated labels |
| `STORY_POINTS` | Numeric story points |
| `BLOCKS` | Comma-separated keys this ticket blocks |
| `BLOCKED-BY` | Comma-separated keys blocking this ticket |
| `PARENT` | Parent ticket key (for Stories under Features) |

## Commands

| Command | Description |
|---------|-------------|
| `org-tickets-sync-to-jira` | Sync all tickets in current buffer to Jira |
| `org-tickets-add-block-link` | Add a "blocks" link between tickets |
| `org-tickets-set-fix-version` | Set Fix Version for a ticket |
| `org-tickets-update-story-sizing` | Update story points |
| `org-tickets-insert-feature-template` | Insert Feature template |
| `org-tickets-insert-improvement-template` | Insert Improvement template |
| `org-tickets-insert-story-template` | Insert Story template |
| `org-tickets-attach-add` | Add attachment to ticket |
| `org-tickets-attach-list` | List ticket attachments |
| `org-tickets-attach-open` | Open attachment directory |
| `org-tickets-attach-remove` | Remove attachment |
| `org-tickets-refresh-issue-types` | Force refresh issue type IDs |

## Development

Run tests:

```bash
make test
```

Lint (checkdoc, plus package-lint when installed):

```bash
make lint
```

## License

GPLv3 - See LICENSE file for details.
