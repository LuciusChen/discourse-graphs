# discourse-graph.el

An Emacs org-mode implementation of the [Discourse Graph](https://discoursegraphs.com/) protocol for knowledge synthesis.

![Discourse Graph](/assets/screenshot.jpg "Discourse Graph")

## What is a Discourse Graph?

Discourse Graphs are an information model that organizes knowledge into semantic units:

- **Questions** — Research questions to explore
- **Claims** — Assertions or arguments
- **Evidence** — Supporting data or observations
- **Sources** — References and citations

These units are connected through typed relationships:

- **supports** — Evidence/Claim supports a Claim
- **opposes** — Evidence/Claim opposes a Claim
- **informs** — Provides background, context, or source reference (use for Evidence → Source)
- **answers** — Claim answers a Question

This approach, developed by [Joel Chan](https://joelchan.me/) for Roam Research, enables structured literature reviews and knowledge synthesis.

## Features

- **SQLite-backed storage** — Fast queries even with thousands of nodes
- **Context panel with transclusion** — See related nodes with their full content inline
- **Inline overlays** — `[+3/-1]` shows support/oppose counts on headings
- **Argumentation analysis** — Dynamic blocks for synthesis, gaps, and unanswered objections
- **Customizable attributes** — Formula DSL for computing node metrics
- **Smart relation creation** — Suggests relation types based on node types
- **Denote compatible** — Works with denote file naming conventions
- **Export** — Graphviz SVG and Markdown export

## Requirements

- Emacs 29.1+ (for built-in SQLite support)
- transient 0.4.0+

## Installation

### Manual

```elisp
;; Add to load-path
(add-to-list 'load-path "/path/to/discourse-graph/")
(require 'discourse-graph)

;; Configure
(setq dg-directories '("~/org/research/"))

;; Enable
(discourse-graph-mode 1)
```

### use-package

```elisp
(use-package discourse-graph
  :load-path "/path/to/discourse-graph/"
  :config
  (setq dg-directories '("~/org/research/"))
  (discourse-graph-mode 1))
```

## Quick Start

1. Enable the mode: `M-x discourse-graph-mode`
2. Open the menu: `C-c d d`
3. Create your first node: `c` then select type
4. Build the cache: `!` (rebuild cache)
5. Open context panel: `x`

## Node Format

Nodes are org headings with special properties:

```org
* Does social media increase polarization?
:PROPERTIES:
:ID: a1b2c3d4
:DG_TYPE: question
:END:

* Social media algorithms amplify divisive content
:PROPERTIES:
:ID: e5f6g7h8
:DG_TYPE: claim
:DG_ANSWERS: a1b2c3d4
:END:

* Study shows 40% increase in partisan content exposure
:PROPERTIES:
:ID: i9j0k1l2
:DG_TYPE: evidence
:DG_SUPPORTS: e5f6g7h8
:DG_SUPPORTS_NOTE: This study provides quantitative evidence for algorithm-driven amplification
:DG_INFORMS: m3n4o5p6
:END:
```

### Relation Context Notes

You can add context notes to explain **why** a relation exists. These appear in the Context panel:

- `DG_SUPPORTS_NOTE` — Explanation for supports relation
- `DG_OPPOSES_NOTE` — Explanation for opposes relation
- `DG_INFORMS_NOTE` — Explanation for informs relation
- `DG_ANSWERS_NOTE` — Explanation for answers relation

## Key Bindings

| Key | Command | Description |
|-----|---------|-------------|
| `C-c d d` | `dg-menu` | Open main menu |
| `C-c d c` | `dg-create-node` | Create a new node |
| `C-c d r` | `dg-link` | Add relation (smart defaults) |
| `C-c d x` | `dg-context-toggle` | Toggle context panel |
| `C-c d g` | `dg-goto-node` | Jump to a node |
| `C-c d !` | `dg-rebuild-cache` | Rebuild database |

All commands are also available via `C-c d d` (transient menu).

## Menu Structure

Press `C-c d d` to open the main menu:

```
┌─────────────────────────────────────────────────────────────┐
│ Discourse Graph                                             │
├─────────────────────────────────────────────────────────────┤
│ Create          │ Relations        │ Navigate               │
│  c Create node  │  r Add relation  │  g Go to node          │
│  C Convert head │  D Remove rel    │  x Toggle context      │
│  q Question     │                  │  b Go back             │
│  l Claim        │                  │  p Graph preview       │
│  e Evidence     │                  │                        │
│  s Source       │                  │                        │
├─────────────────────────────────────────────────────────────┤
│ Analysis        │ Export                                    │
│  S Synthesis    │  E s SVG                                  │
│  A Analyze Q    │  E m Markdown                             │
│  ? Query node   │                                           │
├─────────────────────────────────────────────────────────────┤
│ Maintain        │ Display                                   │
│  ! Rebuild      │  o Toggle overlays                        │
│  v Validate     │  d Detailed overlay                       │
│                 │  D Simple overlay                         │
│                 │  W Configure...                           │
└─────────────────────────────────────────────────────────────┘
```

## Context Panel

The context panel (`C-c d x`) displays related nodes with their **full content** (transclusion style):

```org
#+title: [CLM] Social media amplifies divisive content [+2/-1]
#+property: id e5f6g7h8

* → Answers
** Does social media increase polarization? :QUE:
[[dg:a1b2c3d4]]
#+begin_quote
This is the main research question we're exploring...
#+end_quote

* ← Supported By
** Study shows 40% increase... :EVD:
[[dg:i9j0k1l2]]
[SUPPORTS_NOTE] This study provides quantitative evidence for algorithm-driven amplification
#+begin_quote
Randomized controlled trial with 500 participants...
#+end_quote
```

Features:
- **Transclusion** — Full node content displayed in quote blocks
- **Auto-updates** as you navigate between nodes
- **Foldable** — Use `TAB` to collapse/expand individual nodes
- **Click links** to jump to related nodes
- **Press `b`** to go back in history
- **`[TYPE_NOTE]`** shows why relations exist

## Creating Relations

### Method 1: From menu
1. Move to a node
2. `C-c d r` (or `C-c d d` then `r`)
3. Select relation type (smart suggestions based on node types)
4. Select target node
5. Save file (`C-x C-s`)

### Method 2: On a link
1. Place cursor on an `id:` or `dg:` link
2. `C-c d r`
3. Select relation type
4. Relation is added using the link target

### Adding Context Notes
Use `C-u C-c d r` to add a relation with a context note explaining **why** the relation exists.

### Method 3: Manual
Add properties directly:

```org
:DG_SUPPORTS: target-id
:DG_SUPPORTS_NOTE: Explanation of why this supports the claim
:DG_OPPOSES: target-id
:DG_ANSWERS: target-id
:DG_INFORMS: target-id
```

## Converting Existing Headings

To convert an existing org heading to a discourse graph node:

1. Move to the heading
2. `C-c d d C` (or `M-x dg-convert-to-node`)
3. Select node type

This will:
- Create an ID if one doesn't exist
- Add the `DG_TYPE` property
- Update the database on save

## Analysis

### Synthesis Dashboard
`C-c d d` then `S` — Open argumentation analysis dashboard with:
- Research health overview
- Unanswered objections
- Structural gaps in arguments

### Analyze Question
`C-c d d` then `A` — Create detailed analysis for a specific question, showing:
- All answers ranked by argument strength
- Supporting and opposing evidence for each answer
- Structural gaps (missing sources, unanswered objections)

### Query Relations
`C-c d d` then `?` — Shows all relations for the node at point

### Dynamic Blocks

Use org-mode dynamic blocks for live analysis. Press `C-c C-c` on a block to update.

```org
#+BEGIN: dg-synthesis :id "question-node-id"
;; Or use :question "Question title text"
;; Analyzes all answers with evidence structure
;; Shows: Answer | Status | +Ev | -Ev | Gaps
#+END:

#+BEGIN: dg-unanswered-opposition :limit 20
;; Claims with objections that lack adequate responses
#+END:

#+BEGIN: dg-argument-gaps :limit 30
;; Claims missing evidence or sources
#+END:

#+BEGIN: dg-overview
;; Research health statistics:
;; - Questions (open/answered)
;; - Claims (with structural gaps)
;; - Evidence and Sources counts
#+END:
```

#### Argument Strength Assessment

The synthesis analysis categorizes answers by structural strength:

| Status | Meaning |
|--------|---------|
| ✓ Supported | Has supporting evidence, no unanswered opposition |
| ⚡ Contested | Has both support and opposition |
| ⚠ Challenged | Opposition outweighs support |
| ✗ Unsupported | No supporting evidence |

#### Structural Gaps

The system detects these argument weaknesses:

- **no-support** — Claim has no supporting evidence
- **no-source** — Evidence lacks source citations
- **unanswered-opposition** — Objections without adequate responses

## Configuration

```elisp
;; Directories to scan for nodes
(setq dg-directories '("~/org/research/" "~/org/notes/"))

;; Scan subdirectories
(setq dg-recursive t)

;; Database location
(setq dg-db-file "~/.emacs.d/discourse-graph.db")

;; Context panel width
(setq dg-context-window-width 0.3)

;; Auto-update context when moving between nodes
(setq dg-context-auto-update t)

;; Show overlays on headings
(setq dg-overlay-enable t)

;; Maximum lines to display per node in context panel (nil for unlimited)
(setq dg-context-max-lines 30)

;; Overlay format function
;; Options: #'dg-default-overlay-format or #'dg-detailed-overlay-format
(setq dg-overlay-format-function #'dg-default-overlay-format)

;; Synthesis dashboard file location
(setq dg-synthesis-file "~/org/research/synthesis.org")

;; Use with denote
(setq dg-use-denote t)
```

### Customizing Attributes

You can customize how attributes are computed using formula DSL:

```elisp
(setq dg-discourse-attributes
  '((claim
     . ((evidence-score . "{count:Supported By:evidence} - {count:Opposed By:evidence}")
        (robustness . "{count:Supported By:evidence} + {count:Supported By:claim}*0.5 - {count:Opposed By:evidence}")
        (overlay . evidence-score)))
    (question
     . ((answer-count . "{count:Answered By:claim}")
        (overlay . answer-count)))
    ;; ... more types
    ))
```

Formula syntax:
- `{count:RELATION:TYPE}` — Count relations
- `{sum:RELATION:TYPE:ATTR}` — Sum attribute from related nodes
- `{avg:RELATION:TYPE:ATTR}` — Average attribute
- Math operations: `+ - * /` and parentheses

## Export

### SVG
`C-c d d` then `E s` — Export entire graph as SVG

The SVG uses CSS variables for colors, making it suitable for light/dark mode:

```css
:root {
  --fg: light-dark(#333, #ccc);
  --bg: light-dark(#fff, #333);
}
```

### Markdown
`C-c d d` then `E m` — Export nodes as markdown files with wikilinks

## Maintenance

| Command | Description |
|---------|-------------|
| `dg-rebuild-cache` | Rebuild entire database |
| `dg-validate` | Check for broken links and missing files |

## Workflow Tips

### Literature Review
1. Create a **Question** for your research question
2. As you read papers, create **Source** nodes
3. Extract **Evidence** from sources (link with `DG_INFORMS`)
4. Formulate **Claims** that synthesize evidence
5. Use `S` (Synthesis) to see the argument structure

### Building Arguments
1. Start with a **Claim** you want to support
2. Create **Evidence** nodes that support it (`C-c d r` → supports)
3. Note opposing evidence too (`C-c d r` → opposes)
4. Use `dg-synthesis` dblock to see the balance of evidence

### Identifying Gaps
1. Open Synthesis dashboard (`C-c d d S`)
2. Check "Unanswered Objections" — claims needing more support
3. Check "Structural Gaps" — arguments missing evidence or sources
4. Address gaps by adding evidence or sources

### Daily Use
1. Keep context panel open (`C-c d x`)
2. As you navigate, context auto-updates
3. Use `C-c d g` to quickly jump to any node
4. Periodically run Synthesis to check research health

## Comparison with Roam Discourse Graph

| Feature | Roam DG | discourse-graph.el |
|---------|---------|-------------------|
| Node types | ✓ | ✓ |
| Relations | ✓ | ✓ |
| Context panel | ✓ | ✓ |
| Transclusion | ✓ | ✓ (in context panel) |
| Argumentation analysis | ✗ | ✓ |
| Custom attributes | ✗ | ✓ |
| Block-level nodes | ✓ | ✗ (heading-level) |
| Interactive graph | ✓ | ✗ (static export) |
| Offline/local | ✗ | ✓ |
| Plain text | ✗ | ✓ |
| Customizable | Limited | ✓ (it's Emacs) |

## Acknowledgments

- [Joel Chan](https://joelchan.me/) for the Discourse Graph concept and Roam extension
- [OASIS Lab](https://oasislab.pubpub.org/) for discourse graph research
- The org-roam project for inspiration

## License

GPL-3.0
