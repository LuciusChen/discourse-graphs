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
- **Context panel** — See all relations for the current node at a glance
- **Inline overlays** — `[+3/-1]` shows support/oppose counts on headings
- **Query builder** — Find nodes by type and relation patterns
- **Smart relation creation** — Suggests relation types based on node types
- **Denote compatible** — Works with denote file naming conventions
- **Export** — Graphviz DOT and Markdown export

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

## Context Panel

The context panel (`C-c d x`) shows:
```
#+title: [CLM] Social media amplifies divisive content [+2/-1]
#+property: id e5f6g7h8

*  Answers
** Does social media increase polarization? :QUE:
[[dg:a1b2c3d4]]

*  Supported By
** Study shows 40% increase... :EVD:
[[dg:i9j0k1l2]]
[SUPPORTS_NOTE] This study provides quantitative evidence for algorithm-driven amplification
```

- Auto-updates as you navigate between nodes
- Click links to jump to related nodes
- Press `l` to go back in history
- `[TYPE_NOTE]` shows why relations exist

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

## Querying

### Query current node
`C-c d d` then `?` — Shows all relations for the node at point

### Query builder
`C-c d d` then `/` — Build complex queries:
- Filter by source type (e.g., all Claims)
- Filter by relation (e.g., that support something)
- Filter by target type (e.g., supported by Evidence)

### Node index
`C-c d d` then `i` — Browse all nodes, filter by type, sort by score

## Configuration

```elisp
;; Directories to scan for nodes
(setq dg-directories '("~/org/research/" "~/org/notes/"))

;; Scan subdirectories
(setq dg-recursive t)

;; Database location
(setq dg-db-file "~/.emacs.d/discourse-graph.db")

;; Context panel width
(setq dg-context-window-width 45)

;; Auto-update context when moving between nodes
(setq dg-context-auto-update t)

;; Show overlays on headings
(setq dg-overlay-enable t)

;; Use with denote
(setq dg-use-denote t)
```

## Export

### Graphviz DOT
`C-c d d` then `E d` — Export graph structure for visualization

```bash
dot -Tpng discourse-graph.dot -o graph.png
```

### Markdown
`C-c d d` then `E m` — Export nodes as markdown files with wikilinks

## Maintenance

| Command | Description |
|---------|-------------|
| `dg-rebuild-cache` | Rebuild entire database |
| `dg-validate` | Check for broken links |
| `dg-cleanup-dangling` | Remove orphaned relations |
| `dg-stats` | Show graph statistics |

## Workflow Tips

### Literature Review
1. Create a **Question** for your research question
2. As you read papers, create **Source** nodes
3. Extract **Evidence** from sources (link with `DG_INFORMS`)
4. Formulate **Claims** that synthesize evidence
5. Use context panel to see the argument structure

### Building Arguments
1. Start with a **Claim** you want to support
2. Create **Evidence** nodes that support it (`C-c d r`  supports)
3. Note opposing evidence too (`C-c d r`  opposes)
4. Query to see the balance: how much support vs opposition?

### Daily Use
1. Keep context panel open (`C-c d x`)
2. As you navigate, context auto-updates
3. Use `C-c d g` to quickly jump to any node
4. Use query builder to find patterns in your notes

## Comparison with Roam Discourse Graph

| Feature | Roam DG | discourse-graph.el |
|---------|---------|-------------------|
| Node types | ✓ | ✓ |
| Relations | ✓ | ✓ |
| Context panel | ✓ | ✓ |
| Query builder | ✓ | ✓ |
| Block-level nodes | ✓ | ✗ (heading-level) |
| Interactive graph | ✓ | ✗ (static export) |
| Transclusion | ✓ | ✗ (use org-transclusion) |
| Offline/local | ✗ | ✓ |
| Plain text | ✗ | ✓ |
| Customizable | Limited | ✓ (it's Emacs) |

## Acknowledgments

- [Joel Chan](https://joelchan.me/) for the Discourse Graph concept and Roam extension
- [OASIS Lab](https://oasislab.pubpub.org/) for discourse graph research
- The org-roam project for inspiration

## License

GPL-3.0
