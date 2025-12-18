;;; discourse-graph.el --- Discourse Graph for org-mode with SQLite -*- lexical-binding: t; -*-

;; Copyright (C) 2024-2025
;; Author:
;; Version: 1.0.0
;; Package-Requires: ((emacs "29.1") (transient "0.4.0"))
;; Keywords: org, notes, knowledge-management
;; URL: https://github.com/

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Discourse Graph is a knowledge synthesis tool for Emacs org-mode.
;; It implements the discourse graph protocol for organizing research notes
;; into semantic units (Questions, Claims, Evidence, Sources) with typed
;; relationships (supports, opposes, informs, answers).
;;
;; Based on the Discourse Graph protocol by Joel Chan for Roam Research.
;; See: https://github.com/joelchan/roam-discourse-graph
;;
;; Features:
;; - SQLite-backed storage for scalability
;; - Compatible with denote file naming and linking
;; - Discourse Context sidebar with expandable summaries
;; - Computed attributes (support count, evidence score)
;; - Interactive query builder with save/load
;; - Transient-based menu system
;; - Context overlay showing relation counts
;; - Export to Graphviz SVG and Markdown
;;
;; Quick Start:
;;   (require 'discourse-graph)
;;   (setq dg-directories '("~/org/research/"))
;;   (discourse-graph-mode 1)
;;   M-x dg-menu  or  C-c d d
;;
;; Node Types:
;;   - Question (QUE): Research questions to explore
;;   - Claim (CLM): Assertions or arguments
;;   - Evidence (EVD): Supporting data or observations
;;   - Source (SRC): References and citations
;;
;; Relation Types:
;;   - supports: Evidence/Claim supports a Claim
;;   - opposes: Evidence/Claim opposes a Claim
;;   - informs: Provides background, context, or source reference
;;              (use for Evidence → Source connections)
;;   - answers: Claim answers a Question

;;; Code:

(require 'org)
(require 'org-element)
(require 'seq)
(require 'transient)

(defconst dg-version "1.0.0"
  "Version of discourse-graph.")

;;; ============================================================
;;; Custom Group
;;; ============================================================

(defgroup discourse-graph nil
  "Discourse Graph for org-mode knowledge synthesis."
  :group 'org
  :prefix "dg-")

;;; ============================================================
;;; Configuration Variables
;;; ============================================================

(defcustom dg-directories (list org-directory)
  "List of directories to scan for discourse graph nodes."
  :type '(repeat directory)
  :group 'discourse-graph)

(defcustom dg-recursive t
  "Whether to recursively scan subdirectories."
  :type 'boolean
  :group 'discourse-graph)

(defcustom dg-db-file
  (expand-file-name "discourse-graph.db" user-emacs-directory)
  "Path to SQLite database file."
  :type 'file
  :group 'discourse-graph)

(defcustom dg-id-length 8
  "Length of generated hash IDs (when not using denote)."
  :type 'integer
  :group 'discourse-graph)

(defcustom dg-use-denote nil
  "Whether to use denote for file creation and linking.
When non-nil, uses denote's ID format and linking conventions."
  :type 'boolean
  :group 'discourse-graph)

(defcustom dg-denote-keywords-as-type t
  "When using denote, add node type as a keyword in filename.
E.g., 20231215T120000--my-claim__claim.org"
  :type 'boolean
  :group 'discourse-graph)

(defcustom dg-node-types
  '((question . (:short "QUE" :color "lightblue"   :desc "Research question"))
    (claim    . (:short "CLM" :color "lightyellow" :desc "Assertion or thesis"))
    (evidence . (:short "EVD" :color "lightgreen"  :desc "Supporting data"))
    (source   . (:short "SRC" :color "lightgray"   :desc "Reference material")))
  "Node types with metadata.
Each entry is (TYPE . (:short ABBREV :color COLOR :desc DESCRIPTION))."
  :type '(alist :key-type symbol
                :value-type (plist :key-type keyword
                                   :value-type string))
  :group 'discourse-graph)

(defcustom dg-relation-types
  '((supports  . (:inverse "Supported By" :color "green"  :style "solid"))
    (opposes   . (:inverse "Opposed By"   :color "red"    :style "dashed"))
    (informs   . (:inverse "Informed By"  :color "blue"   :style "solid"))
    (answers   . (:inverse "Answered By"  :color "purple" :style "solid")))
  "Relation types with metadata.
Each entry is (TYPE . (:inverse INVERSE-NAME :color COLOR :style STYLE)).
INVERSE-NAME is the human-readable name when viewing from the target's perspective."
  :type '(alist :key-type symbol
                :value-type (plist :key-type keyword
                                   :value-type string))
  :group 'discourse-graph)

(defcustom dg-context-auto-update t
  "Automatically update context buffer when cursor moves to new node."
  :type 'boolean
  :group 'discourse-graph)

(defcustom dg-context-window-width 0.3
  "Width of context window as fraction of frame width (0.0-1.0)."
  :type 'float
  :group 'discourse-graph)

(defcustom dg-title-templates
  '((question . "QUE: %s")
    (claim    . "CLM: %s")
    (evidence . "EVD: %s")
    (source   . "SRC: %s"))
  "Title format templates for each node type.
Use %s as placeholder for the actual title.
Set to nil to disable auto-formatting."
  :type '(alist :key-type symbol :value-type string)
  :group 'discourse-graph)

(defcustom dg-auto-format-title nil
  "Whether to automatically format titles using templates."
  :type 'boolean
  :group 'discourse-graph)

(defcustom dg-overlay-enable t
  "If non-nil, show relation count overlay after node headings."
  :type 'boolean
  :group 'discourse-graph)


(defcustom dg-export-link-style 'wikilink
  "Link style for markdown export.
`wikilink' for [[Title]] style, `markdown' for [Title](file.md) style."
  :type '(choice (const wikilink) (const markdown))
  :group 'discourse-graph)

;;; ============================================================
;;; Internal Variables
;;; ============================================================

(defvar dg--db nil
  "SQLite database connection.")

(defvar dg--context-buffer-name "*DG Context*"
  "Name of the discourse context buffer.")

(defvar dg--current-node-id nil
  "ID of currently displayed node in context buffer.")

(defvar dg--context-timer nil
  "Timer for debouncing context updates.")

(defvar dg--nav-history nil
  "Navigation history stack for discourse graph exploration.")

(defvar dg--nav-history-max 20
  "Maximum size of navigation history.")

;;; ============================================================
;;; Database Management
;;; ============================================================

(defun dg--db ()
  "Get database connection, initializing if needed.
Creates the database file and schema if they don't exist."
  (unless (and dg--db (sqlitep dg--db))
    (condition-case err
        (progn
          ;; Ensure directory exists
          (let ((dir (file-name-directory dg-db-file)))
            (unless (file-exists-p dir)
              (make-directory dir t)))
          (setq dg--db (sqlite-open dg-db-file))
          (dg--init-schema))
      (error
       (setq dg--db nil)
       (user-error "Failed to open database: %s" (error-message-string err)))))
  dg--db)

(defun dg--init-schema ()
  "Initialize database schema."
  ;; Nodes table
  (sqlite-execute (dg--db) "
    CREATE TABLE IF NOT EXISTS nodes (
      id           TEXT PRIMARY KEY,
      type         TEXT NOT NULL,
      title        TEXT NOT NULL,
      file         TEXT NOT NULL,
      pos          INTEGER NOT NULL,
      outline_path TEXT,
      is_file_node INTEGER DEFAULT 0,
      mtime        REAL NOT NULL
    )")
  ;; Relations table with context support
  (sqlite-execute (dg--db) "
    CREATE TABLE IF NOT EXISTS relations (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      source_id   TEXT NOT NULL,
      target_id   TEXT NOT NULL,
      rel_type    TEXT NOT NULL,
      context_id  TEXT,
      context_note TEXT,
      UNIQUE(source_id, target_id, rel_type)
    )")
  ;; Migration: add context_note column if missing (for old databases)
  (dg--migrate-schema)
  ;; Indexes for performance
  (sqlite-execute (dg--db) "CREATE INDEX IF NOT EXISTS idx_nodes_type ON nodes(type)")
  (sqlite-execute (dg--db) "CREATE INDEX IF NOT EXISTS idx_nodes_file ON nodes(file)")
  (sqlite-execute (dg--db) "CREATE INDEX IF NOT EXISTS idx_rel_source ON relations(source_id)")
  (sqlite-execute (dg--db) "CREATE INDEX IF NOT EXISTS idx_rel_target ON relations(target_id)")
  (sqlite-execute (dg--db) "CREATE INDEX IF NOT EXISTS idx_rel_type ON relations(rel_type)"))

(defun dg--migrate-schema ()
  "Migrate database schema if needed."
  ;; Check if context_note column exists in relations table
  (let* ((columns (sqlite-select (dg--db) "PRAGMA table_info(relations)"))
         (col-names (mapcar (lambda (row) (nth 1 row)) columns)))
    (unless (member "context_note" col-names)
      (sqlite-execute (dg--db) "ALTER TABLE relations ADD COLUMN context_note TEXT")
      (message "Discourse Graph: migrated database schema (added context_note)"))))

(defun dg-close-db ()
  "Close database connection."
  (interactive)
  (when (and dg--db (sqlitep dg--db))
    (sqlite-close dg--db)
    (setq dg--db nil)
    (message "Discourse Graph: database closed")))

;;; ============================================================
;;; ID Generation
;;; ============================================================

(defun dg-generate-id (&optional content)
  "Generate a unique ID.
If `dg-use-denote' is non-nil and denote is available, use denote format.
Otherwise generate a short hash from CONTENT or random data."
  (if (and dg-use-denote (featurep 'denote))
      ;; Denote-style timestamp ID
      (format-time-string "%Y%m%dT%H%M%S")
    ;; Hash-based ID
    (let* ((input (or content
                      (format "%s-%s-%s"
                              (emacs-pid)
                              (float-time)
                              (random t))))
           (full-hash (secure-hash 'sha256 input)))
      (substring full-hash 0 dg-id-length))))

;;; ============================================================
;;; Denote Compatibility
;;; ============================================================

(defun dg--denote-available-p ()
  "Check if denote is available and enabled."
  (and dg-use-denote (featurep 'denote)))

(defun dg--extract-denote-id (filename)
  "Extract denote ID from FILENAME if present.
Returns the ID string or nil."
  (let ((name (file-name-nondirectory filename)))
    (when (string-match "^\\([0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]\\)" name)
      (match-string 1 name))))

(defun dg--get-id-at-point ()
  "Get discourse graph node ID at point.
Checks org ID property first, then looks for file-level identifiers.
Returns nil if in context buffer or before first heading."
  ;; Don't return ID if we're in the context buffer
  (when (not (string= (buffer-name) dg--context-buffer-name))
    (cond
     ;; Before any heading - return nil for heading-level nodes
     ((and (derived-mode-p 'org-mode)
           (org-before-first-heading-p))
      ;; Only check file-level identifiers
      (or
       (save-excursion
         (goto-char (point-min))
         (when (re-search-forward "^#\\+identifier:[ \t]*\\(.+\\)$" nil t)
           (string-trim (match-string 1))))
       (when (buffer-file-name)
         (dg--extract-denote-id (buffer-file-name)))))
     ;; Under a heading - get heading ID
     ((derived-mode-p 'org-mode)
      (save-excursion
        (org-back-to-heading t)
        (org-entry-get nil "ID")))
     ;; Non-org buffer with possible denote ID
     (t
      (when (buffer-file-name)
        (dg--extract-denote-id (buffer-file-name)))))))

(defun dg--create-denote-node (type title)
  "Create a new denote file for a discourse graph node.
TYPE is the node type symbol, TITLE is the node title string."
  (when (dg--denote-available-p)
    (let* ((keywords (if dg-denote-keywords-as-type
                         (list (symbol-name type))
                       nil))
           (denote-directory (car dg-directories)))
      (denote title keywords 'org)
      ;; Add DG_TYPE to front matter
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward "^#\\+identifier:" nil t)
          (forward-line 1)
          (insert (format "#+dg_type: %s\n" type)))))))

;;; ============================================================
;;; File Collection and Scanning
;;; ============================================================

(defun dg--collect-files ()
  "Collect all org files from configured directories."
  (let ((files '()))
    (dolist (dir dg-directories)
      (when (file-directory-p dir)
        (setq files
              (append files
                      (if dg-recursive
                          (directory-files-recursively dir "\\.org$")
                        (directory-files dir t "\\.org$"))))))
    (seq-uniq files)))

(defun dg--parse-relations-at-point ()
  "Parse all DG relation properties at current heading.
Returns list of (REL-TYPE . TARGET . NOTE) where NOTE may be nil."
  (let ((relations '()))
    (dolist (rel-type dg-relation-types)
      (let* ((rel-name (symbol-name (car rel-type)))
             (prop (concat "DG_" (upcase rel-name)))
             (note-prop (concat "DG_" (upcase rel-name) "_NOTE"))
             (value (org-entry-get nil prop))
             (note (org-entry-get nil note-prop)))
        (when value
          ;; Support multiple targets separated by space or comma
          (dolist (target (split-string value "[ \t,]+" t))
            ;; Note applies to all targets of this relation type
            (push (list (car rel-type) target note) relations)))))
    relations))

(defun dg--get-node-type-at-point ()
  "Get DG_TYPE at point, checking both property and front matter."
  (or (org-entry-get nil "DG_TYPE")
      ;; Check org-mode keywords for denote compatibility
      (save-excursion
        (goto-char (point-min))
        (when (re-search-forward "^#\\+dg_type:[ \t]*\\(.+\\)" nil t)
          (string-trim (match-string 1))))))

(defun dg--scan-file (file)
  "Scan FILE for discourse graph nodes.
Returns (NODES . RELATIONS) where each is a list."
  (let ((nodes '())
        (relations '())
        (file-mtime (float-time (file-attribute-modification-time
                                 (file-attributes file))))
        (existing-buffer (get-file-buffer file)))
    (condition-case err
        (let ((buf (or existing-buffer
                       (let ((inhibit-message t)
                             (message-log-max nil))
                         (find-file-noselect file t)))))
          (with-current-buffer buf
            (save-excursion
              (save-restriction
                (widen)
                ;; Check for file-level node (denote style)
                (let* ((denote-id (dg--extract-denote-id file))
                       (file-type (progn
                                    (goto-char (point-min))
                                    (when (re-search-forward "^#\\+dg_type:[ \t]*\\(.+\\)" nil t)
                                      (string-trim (match-string 1)))))
                       (file-title (progn
                                     (goto-char (point-min))
                                     (when (re-search-forward "^#\\+title:[ \t]*\\(.+\\)" nil t)
                                       (string-trim (match-string 1))))))
                  (when (and denote-id file-type file-title)
                    (push (list :id denote-id
                                :type file-type
                                :title file-title
                                :file file
                                :pos 1
                                :outline-path ""
                                :is-file-node t
                                :mtime file-mtime)
                          nodes)
                    ;; Parse file-level relations from keywords
                    (goto-char (point-min))
                    (while (re-search-forward "^#\\+dg_\\([a-z_-]+\\):[ \t]*\\(.+\\)" nil t)
                      (let ((rel-name (match-string 1))
                            (targets (match-string 2)))
                        (unless (string= rel-name "type")
                          (dolist (target (split-string targets "[ \t,]+" t))
                            (push (list :source denote-id
                                        :target target
                                        :type (intern (replace-regexp-in-string "_" "-" rel-name)))
                                  relations)))))))
                ;; Scan headings
                (goto-char (point-min))
                (while (re-search-forward "^\\*+ " nil t)
                  (condition-case nil
                      (save-excursion
                        (beginning-of-line)
                        (let ((id (org-entry-get nil "ID"))
                              (type (org-entry-get nil "DG_TYPE")))
                          (when (and id type)
                            (push (list :id id
                                        :type type
                                        :title (org-get-heading t t t t)
                                        :file file
                                        :pos (point)
                                        :outline-path (ignore-errors
                                                        (string-join (org-get-outline-path t) "/"))
                                        :is-file-node nil
                                        :mtime file-mtime)
                                  nodes)
                            (dolist (rel (dg--parse-relations-at-point))
                              (push (list :source id
                                          :target (nth 1 rel)
                                          :type (nth 0 rel)
                                          :note (nth 2 rel))
                                    relations)))))
                    (error nil))))))
          ;; Kill buffer if we opened it
          (unless existing-buffer
            (kill-buffer buf)))
      (error
       (message "DG: Error scanning %s: %s" file (error-message-string err))))
    (cons nodes relations)))

;;; ============================================================
;;; Database Operations
;;; ============================================================

(defun dg--save-node (node)
  "Save NODE to database."
  (sqlite-execute
   (dg--db)
   "INSERT OR REPLACE INTO nodes
    (id, type, title, file, pos, outline_path, is_file_node, mtime)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
   (list (plist-get node :id)
         (plist-get node :type)
         (plist-get node :title)
         (plist-get node :file)
         (plist-get node :pos)
         (plist-get node :outline-path)
         (if (plist-get node :is-file-node) 1 0)
         (plist-get node :mtime))))

(defun dg--save-relation (rel)
  "Save REL to database, including optional context note."
  (sqlite-execute
   (dg--db)
   "INSERT OR REPLACE INTO relations (source_id, target_id, rel_type, context_note)
    VALUES (?, ?, ?, ?)"
   (list (plist-get rel :source)
         (plist-get rel :target)
         (symbol-name (plist-get rel :type))
         (plist-get rel :note))))

(defun dg--delete-file-data (file)
  "Delete all nodes and relations from FILE."
  (sqlite-execute
   (dg--db)
   "DELETE FROM relations WHERE source_id IN
    (SELECT id FROM nodes WHERE file = ?)"
   (list file))
  (sqlite-execute
   (dg--db)
   "DELETE FROM nodes WHERE file = ?"
   (list file)))

;;; ============================================================
;;; Cache Management
;;; ============================================================

(defun dg-rebuild-cache ()
  "Completely rebuild the database from all configured directories."
  (interactive)
  (let ((inhibit-message t)
        (message-log-max nil))
    (sqlite-execute (dg--db) "DELETE FROM relations")
    (sqlite-execute (dg--db) "DELETE FROM nodes"))
  (let ((files (dg--collect-files))
        (node-count 0)
        (rel-count 0)
        (file-count 0)
        (total-files 0))
    (setq total-files (length files))
    (message "Discourse Graph: scanning %d files..." total-files)
    (dolist (file files)
      (cl-incf file-count)
      ;; Show progress every 10 files
      (when (= 0 (mod file-count 10))
        (message "Discourse Graph: scanning... %d/%d" file-count total-files))
      (let* ((inhibit-message t)
             (message-log-max nil)
             (result (dg--scan-file file))
             (nodes (car result))
             (relations (cdr result)))
        (dolist (node nodes)
          (dg--save-node node)
          (cl-incf node-count))
        (dolist (rel relations)
          (dg--save-relation rel)
          (cl-incf rel-count))))
    (message "Discourse Graph: indexed %d nodes, %d relations from %d files"
             node-count rel-count total-files)))

(defun dg-update-file (&optional file)
  "Incrementally update index for FILE (defaults to current buffer)."
  (interactive)
  (let ((file (or file (buffer-file-name))))
    (when (and file
               (file-exists-p file)
               (string-suffix-p ".org" file))
      (condition-case err
          (let ((inhibit-message t)
                (message-log-max nil))
            (dg--delete-file-data file)
            (let* ((result (dg--scan-file file))
                   (nodes (car result))
                   (relations (cdr result)))
              (dolist (node nodes)
                (dg--save-node node))
              (dolist (rel relations)
                (dg--save-relation rel))
              ;; Only show message if called interactively
              (when (called-interactively-p 'any)
                (let ((inhibit-message nil))
                  (message "Discourse Graph: updated %d nodes from %s"
                           (length nodes) (file-name-nondirectory file))))))
        (error
         (message "DG: Error updating %s: %s" file (error-message-string err)))))))

;;; ============================================================
;;; Query API
;;; ============================================================

(defun dg--row-to-plist (row)
  "Convert database ROW to property list.
Type is kept as string for consistency with database."
  (when row
    (list :id (nth 0 row)
          :type (nth 1 row)  ;; Keep as string
          :title (nth 2 row)
          :file (nth 3 row)
          :pos (nth 4 row)
          :outline-path (nth 5 row))))

(defun dg-get (id)
  "Get node by ID."
  (dg--row-to-plist
   (car (sqlite-select
         (dg--db)
         "SELECT id, type, title, file, pos, outline_path
          FROM nodes WHERE id = ?"
         (list id)))))

(defun dg-find-by-type (type)
  "Find all nodes of TYPE."
  (mapcar #'dg--row-to-plist
          (sqlite-select
           (dg--db)
           "SELECT id, type, title, file, pos, outline_path
            FROM nodes WHERE type = ? ORDER BY title"
           (list (if (symbolp type) (symbol-name type) type)))))

(defun dg-find-by-title (pattern)
  "Find nodes with titles matching PATTERN."
  (mapcar #'dg--row-to-plist
          (sqlite-select
           (dg--db)
           "SELECT id, type, title, file, pos, outline_path
            FROM nodes WHERE title LIKE ? ORDER BY title"
           (list (concat "%" pattern "%")))))

(defun dg-find-outgoing (id &optional rel-type)
  "Find nodes that ID points to, optionally filtered by REL-TYPE."
  (let ((sql (if rel-type
                 "SELECT n.id, n.type, n.title, n.file, n.pos, n.outline_path
                  FROM nodes n
                  JOIN relations r ON n.id = r.target_id
                  WHERE r.source_id = ? AND r.rel_type = ?"
               "SELECT n.id, n.type, n.title, n.file, n.pos, n.outline_path
                FROM nodes n
                JOIN relations r ON n.id = r.target_id
                WHERE r.source_id = ?"))
        (params (if rel-type
                    (list id (symbol-name rel-type))
                  (list id))))
    (mapcar #'dg--row-to-plist
            (sqlite-select (dg--db) sql params))))

(defun dg-find-incoming (id &optional rel-type)
  "Find nodes that point to ID, optionally filtered by REL-TYPE."
  (let ((sql (if rel-type
                 "SELECT n.id, n.type, n.title, n.file, n.pos, n.outline_path
                  FROM nodes n
                  JOIN relations r ON n.id = r.source_id
                  WHERE r.target_id = ? AND r.rel_type = ?"
               "SELECT n.id, n.type, n.title, n.file, n.pos, n.outline_path
                FROM nodes n
                JOIN relations r ON n.id = r.source_id
                WHERE r.target_id = ?"))
        (params (if rel-type
                    (list id (symbol-name rel-type))
                  (list id))))
    (mapcar #'dg--row-to-plist
            (sqlite-select (dg--db) sql params))))

(defun dg-get-relations (id)
  "Get all relations for node ID.
Returns plist with :outgoing and :incoming lists.
Each relation is (direction rel_type node_id title type context_note)."
  (let ((outgoing (sqlite-select
                   (dg--db)
                   "SELECT 'out', rel_type, target_id, n.title, n.type, r.context_note
                    FROM relations r
                    LEFT JOIN nodes n ON r.target_id = n.id
                    WHERE r.source_id = ?"
                   (list id)))
        (incoming (sqlite-select
                   (dg--db)
                   "SELECT 'in', rel_type, source_id, n.title, n.type, r.context_note
                    FROM relations r
                    LEFT JOIN nodes n ON r.source_id = n.id
                    WHERE r.target_id = ?"
                   (list id))))
    (list :outgoing outgoing :incoming incoming)))

(defun dg-all-nodes ()
  "Get all nodes."
  (mapcar #'dg--row-to-plist
          (sqlite-select
           (dg--db)
           "SELECT id, type, title, file, pos, outline_path
            FROM nodes ORDER BY type, title")))

;;; ============================================================
;;; Convenience Query Functions
;;; ============================================================

(defun dg-find-answers (question-id)
  "Find claims that answer QUESTION-ID."
  (dg-find-incoming question-id 'answers))

(defun dg-find-supporting-evidence (claim-id)
  "Find evidence that supports CLAIM-ID."
  (dg-find-incoming claim-id 'supports))

(defun dg-find-opposing-evidence (claim-id)
  "Find evidence that opposes CLAIM-ID."
  (dg-find-incoming claim-id 'opposes))

;;; ============================================================
;;; Helper Functions
;;; ============================================================

(defun dg--node-type-short (node)
  "Get short type indicator for NODE (plist or id string).
Returns \"?\" if type not found."
  (let* ((node-plist (if (stringp node) (dg-get node) node))
         (type-str (and node-plist (plist-get node-plist :type)))
         (type-sym (and type-str (intern type-str)))
         (type-info (and type-sym (alist-get type-sym dg-node-types))))
    (or (plist-get type-info :short) "?")))

(defun dg--node-type-color (node)
  "Get color for NODE (plist or id string).
Returns \"gray\" if not found."
  (let* ((node-plist (if (stringp node) (dg-get node) node))
         (type-str (and node-plist (plist-get node-plist :type)))
         (type-sym (and type-str (intern type-str)))
         (type-info (and type-sym (alist-get type-sym dg-node-types))))
    (or (plist-get type-info :color) "gray")))

(defun dg--format-node-choice (node)
  "Format NODE for completing-read display."
  (format "[%s] %s" (dg--node-type-short node) (plist-get node :title)))

;;; ============================================================
;;; Discourse Attributes (Customizable Formula System)
;;; ============================================================

;; This system allows custom attribute formulas using a DSL.
;;
;; Formula syntax:
;;   {count:RELATION:TYPE}     - Count relations
;;   {sum:RELATION:TYPE:ATTR}  - Sum attribute values from related nodes
;;   {avg:RELATION:TYPE:ATTR}  - Average attribute values
;;
;; Relation names:
;;   Outgoing: supports, opposes, informs, answers
;;   Incoming: Supported By, Opposed By, Informed By, Answered By

(defcustom dg-discourse-attributes
  '((claim
     . ((evidence-score
         . "{count:Supported By:evidence} - {count:Opposed By:evidence}")
        (robustness
         . "{count:Supported By:evidence} + {count:Supported By:claim}*0.5 - {count:Opposed By:evidence} - {count:Opposed By:claim}*0.5")
        (total-support
         . "{count:Supported By:evidence} + {count:Supported By:claim}")
        (overlay . evidence-score)))
    (question
     . ((answer-count
         . "{count:Answered By:claim}")
        (informed-count
         . "{count:Informed By:evidence} + {count:Informed By:source}")
        (overlay . answer-count)))
    (evidence
     . ((source-count
         . "{count:informs:source}")
        (supports-count
         . "{count:supports:claim}")
        (overlay . nil)))
    (source
     . ((usage-count
         . "{count:Informed By:evidence}")
        (overlay . usage-count))))
  "Discourse attributes configuration for each node type.

Each node type maps to an alist of (ATTR-NAME . FORMULA) pairs.
The special key `overlay' specifies which attribute to show in the
heading overlay (nil for none).

Formula syntax:
  {count:RELATION:TYPE}     - Count incoming/outgoing relations
  {sum:RELATION:TYPE:ATTR}  - Sum attribute from related nodes
  {avg:RELATION:TYPE:ATTR}  - Average attribute from related nodes

Relation names:
  Outgoing: supports, opposes, informs, answers
  Incoming: Supported By, Opposed By, Informed By, Answered By

Math operations: + - * / and parentheses are supported."
  :type '(alist :key-type symbol
                :value-type (alist :key-type symbol
                                   :value-type string))
  :group 'discourse-graph)

(defcustom dg-overlay-format-function #'dg-default-overlay-format
  "Function to format overlay string from attributes.
Called with (attributes node-type) and should return a string or nil."
  :type 'function
  :group 'discourse-graph)
(defconst dg--relation-map
  '(;; Incoming relations (from target's perspective)
    ("Supported By" . (:rel "supports" :dir incoming))
    ("Opposed By"   . (:rel "opposes"  :dir incoming))
    ("Informed By"  . (:rel "informs"  :dir incoming))
    ("Answered By"  . (:rel "answers"  :dir incoming))
    ;; Outgoing relations
    ("supports"     . (:rel "supports" :dir outgoing))
    ("opposes"      . (:rel "opposes"  :dir outgoing))
    ("informs"      . (:rel "informs"  :dir outgoing))
    ("answers"      . (:rel "answers"  :dir outgoing)))
  "Map relation names to internal representation.")

(defvar dg--parser-tokens nil "Current token list during parsing.")

(defun dg--parse-formula (formula)
  "Parse FORMULA string into an S-expression for evaluation.
Returns a form that can be evaluated with `dg--eval-formula'."
  (setq dg--parser-tokens (dg--tokenize-formula formula))
  (let ((result (dg--parse-expr)))
    (when dg--parser-tokens
      (error "Unexpected tokens at end: %S" dg--parser-tokens))
    result))

(defun dg--tokenize-formula (formula)
  "Tokenize FORMULA into a list of tokens."
  (let ((pos 0)
        (len (length formula))
        (tokens '()))
    (while (< pos len)
      (let ((char (aref formula pos)))
        (cond
         ;; Skip whitespace
         ((memq char '(?\s ?\t ?\n))
          (setq pos (1+ pos)))
         ;; Function call {op:rel:type} or {op:rel:type:attr}
         ((= char ?{)
          (let ((end (string-match "}" formula pos)))
            (unless end
              (error "Unclosed { in formula at position %d" pos))
            (let* ((content (substring formula (1+ pos) end))
                   (parts (split-string content ":")))
              (push (dg--parse-function parts) tokens)
              (setq pos (1+ end)))))
         ;; Operators
         ((= char ?+) (push '+ tokens) (setq pos (1+ pos)))
         ((= char ?-) (push '- tokens) (setq pos (1+ pos)))
         ((= char ?*) (push '* tokens) (setq pos (1+ pos)))
         ((= char ?/) (push '/ tokens) (setq pos (1+ pos)))
         ;; Parentheses
         ((= char ?\() (push 'lparen tokens) (setq pos (1+ pos)))
         ((= char ?\)) (push 'rparen tokens) (setq pos (1+ pos)))
         ;; Number
         ((or (and (>= char ?0) (<= char ?9))
              (and (= char ?.) (< (1+ pos) len)
                   (let ((next (aref formula (1+ pos))))
                     (and (>= next ?0) (<= next ?9)))))
          (let ((start pos))
            (while (and (< pos len)
                        (let ((c (aref formula pos)))
                          (or (and (>= c ?0) (<= c ?9))
                              (= c ?.))))
              (setq pos (1+ pos)))
            (push (string-to-number (substring formula start pos)) tokens)))
         (t
          (error "Unexpected character '%c' at position %d" char pos)))))
    (nreverse tokens)))

(defun dg--parse-function (parts)
  "Parse function PARTS into a function spec."
  (let ((op (intern (downcase (nth 0 parts))))
        (rel (nth 1 parts))
        (type (and (nth 2 parts) (downcase (nth 2 parts))))
        (attr (and (nth 3 parts) (intern (nth 3 parts)))))
    (unless (memq op '(count sum avg average))
      (error "Unknown operation: %s (expected count, sum, avg)" op))
    (when (eq op 'average) (setq op 'avg))
    (list 'func op rel type attr)))

(defun dg--parser-peek ()
  "Peek at the next token without consuming it."
  (car dg--parser-tokens))

(defun dg--parser-consume ()
  "Consume and return the next token."
  (pop dg--parser-tokens))

(defun dg--parse-expr ()
  "Parse expression (handles + and -)."
  (let ((left (dg--parse-term)))
    (while (memq (dg--parser-peek) '(+ -))
      (let ((op (dg--parser-consume)))
        (setq left (list op left (dg--parse-term)))))
    left))

(defun dg--parse-term ()
  "Parse term (handles * and /)."
  (let ((left (dg--parse-factor)))
    (while (memq (dg--parser-peek) '(* /))
      (let ((op (dg--parser-consume)))
        (setq left (list op left (dg--parse-factor)))))
    left))

(defun dg--parse-factor ()
  "Parse factor (handles parentheses and atoms)."
  (let ((tok (dg--parser-peek)))
    (cond
     ((null tok)
      (error "Unexpected end of formula"))
     ((numberp tok)
      (dg--parser-consume))
     ((eq tok 'lparen)
      (dg--parser-consume)  ; consume '('
      (let ((expr (dg--parse-expr)))
        (unless (eq (dg--parser-consume) 'rparen)
          (error "Missing closing parenthesis"))
        expr))
     ((and (listp tok) (eq (car tok) 'func))
      (dg--parser-consume))
     ((eq tok '-)
      ;; Unary minus
      (dg--parser-consume)
      (list '- 0 (dg--parse-factor)))
     (t
      (error "Unexpected token: %S" tok)))))

(defun dg--eval-formula (expr id &optional attr-cache)
  "Evaluate formula EXPR for node ID.
ATTR-CACHE is an optional hash table for memoizing attribute lookups."
  (cond
   ((numberp expr) expr)
   ((and (listp expr) (eq (car expr) 'func))
    (dg--eval-function (cdr expr) id attr-cache))
   ((and (listp expr) (memq (car expr) '(+ - * /)))
    (let ((op (car expr))
          (left (dg--eval-formula (nth 1 expr) id attr-cache))
          (right (dg--eval-formula (nth 2 expr) id attr-cache)))
      (pcase op
        ('+ (+ left right))
        ('- (- left right))
        ('* (* left right))
        ('/ (if (zerop right) 0 (/ left right))))))
   (t (error "Invalid expression: %S" expr))))

(defun dg--eval-function (spec id &optional attr-cache)
  "Evaluate function SPEC for node ID."
  (let* ((op (nth 0 spec))
         (rel-name (nth 1 spec))
         (node-type (nth 2 spec))
         (attr-name (nth 3 spec))
         (rel-info (cdr (assoc rel-name dg--relation-map)))
         (rel-type (plist-get rel-info :rel))
         (direction (plist-get rel-info :dir)))
    (unless rel-info
      (error "Unknown relation: %s" rel-name))
    (pcase op
      ('count
       (dg--count-relations id rel-type direction node-type))
      ((or 'sum 'avg)
       (dg--aggregate-attribute id rel-type direction node-type attr-name op attr-cache))
      (_ (error "Unknown operation: %s" op)))))

(defun dg--count-relations (id rel-type direction &optional node-type)
  "Count relations for ID of REL-TYPE in DIRECTION, optionally filtered by NODE-TYPE."
  (let ((sql (if (eq direction 'incoming)
                 (if node-type
                     "SELECT COUNT(*) FROM relations r
                      JOIN nodes n ON r.source_id = n.id
                      WHERE r.target_id = ? AND r.rel_type = ? AND n.type = ?"
                   "SELECT COUNT(*) FROM relations
                    WHERE target_id = ? AND rel_type = ?")
               (if node-type
                   "SELECT COUNT(*) FROM relations r
                    JOIN nodes n ON r.target_id = n.id
                    WHERE r.source_id = ? AND r.rel_type = ? AND n.type = ?"
                 "SELECT COUNT(*) FROM relations
                  WHERE source_id = ? AND rel_type = ?")))
        (params (if node-type
                    (list id rel-type node-type)
                  (list id rel-type))))
    (or (caar (sqlite-select (dg--db) sql params)) 0)))

(defun dg--aggregate-attribute (id rel-type direction node-type attr-name op &optional attr-cache)
  "Aggregate ATTR-NAME from related nodes using OP (sum or avg).
Related nodes are found via REL-TYPE in DIRECTION, filtered by NODE-TYPE."
  (let* ((sql (if (eq direction 'incoming)
                  (if node-type
                      "SELECT r.source_id FROM relations r
                       JOIN nodes n ON r.source_id = n.id
                       WHERE r.target_id = ? AND r.rel_type = ? AND n.type = ?"
                    "SELECT source_id FROM relations
                     WHERE target_id = ? AND rel_type = ?")
                (if node-type
                    "SELECT r.target_id FROM relations r
                     JOIN nodes n ON r.target_id = n.id
                     WHERE r.source_id = ? AND r.rel_type = ? AND n.type = ?"
                  "SELECT target_id FROM relations
                   WHERE source_id = ? AND rel_type = ?")))
         (params (if node-type (list id rel-type node-type) (list id rel-type)))
         (related-ids (mapcar #'car (sqlite-select (dg--db) sql params)))
         (values (mapcar (lambda (rid)
                           (dg-compute-attribute rid attr-name attr-cache))
                         related-ids)))
    (if (null values)
        0
      (pcase op
        ('sum (apply #'+ values))
        ('avg (/ (apply #'+ values) (float (length values))))))))

(defun dg-compute-attribute (id attr-name &optional attr-cache)
  "Compute attribute ATTR-NAME for node ID.
Uses ATTR-CACHE if provided to avoid recomputation."
  (let ((cache-key (cons id attr-name)))
    (if (and attr-cache (gethash cache-key attr-cache))
        (gethash cache-key attr-cache)
      (let* ((node (dg-get id))
             (node-type (and node (intern (plist-get node :type))))
             (type-attrs (cdr (assq node-type dg-discourse-attributes)))
             (formula-str (cdr (assq attr-name type-attrs)))
             (result (if formula-str
                         (let ((parsed (dg--parse-formula formula-str)))
                           (dg--eval-formula parsed id attr-cache))
                       0)))
        (when attr-cache
          (puthash cache-key result attr-cache))
        result))))

(defun dg-compute-all-attributes (id)
  "Compute all defined attributes for node ID.
Returns a plist of (:ATTR-NAME . VALUE) pairs using keywords."
  (let* ((node (dg-get id))
         (node-type (and node (intern (plist-get node :type))))
         (type-attrs (cdr (assq node-type dg-discourse-attributes)))
         (attr-cache (make-hash-table :test 'equal))
         (results '()))
    (dolist (attr-def type-attrs)
      (let ((attr-name (car attr-def)))
        (unless (eq attr-name 'overlay)
          (let* ((value (dg-compute-attribute id attr-name attr-cache))
                 ;; Convert symbol to keyword for plist compatibility
                 (key (intern (concat ":" (symbol-name attr-name)))))
            (setq results (plist-put results key value))))))
    results))

(defun dg-default-overlay-format (attrs node-type)
  "Default overlay format function.
ATTRS is a plist of computed attributes, NODE-TYPE is the node type symbol."
  (let* ((type-config (cdr (assq node-type dg-discourse-attributes)))
         (overlay-attr (cdr (assq 'overlay type-config))))
    (when overlay-attr
      ;; Convert symbol to keyword for plist lookup
      (let* ((overlay-key (intern (concat ":" (symbol-name overlay-attr))))
             (value (plist-get attrs overlay-key)))
        (when (and value (not (zerop value)))
          (cond
           ;; For evidence-score style: show +N or -N or +N/-M
           ((memq overlay-attr '(evidence-score robustness))
            (let ((supp (or (plist-get attrs :total-support)
                            (plist-get attrs :support-count)
                            0))
                  (opp (or (plist-get attrs :oppose-count) 0)))
              (cond
               ((and (> supp 0) (> opp 0))
                (format "[+%d/-%d]" supp opp))
               ((> supp 0)
                (format "[+%d]" supp))
               ((> opp 0)
                (format "[-%d]" opp))
               ((not (zerop value))
                (format "[%+d]" (round value))))))
           ;; For counts: show the count
           ((string-match-p "-count$" (symbol-name overlay-attr))
            (format "[%d]" (round value)))
           ;; Generic: show signed value
           (t
            (if (>= value 0)
                (format "[+%.0f]" value)
              (format "[%.0f]" value)))))))))

(defun dg-detailed-overlay-format (attrs node-type)
  "Detailed overlay format showing multiple attributes.
Shows [+S/-O ?A ~I] format."
  (let* ((supp (or (plist-get attrs :total-support)
                   (plist-get attrs :support-count)
                   (plist-get attrs :evidence-score)
                   0))
         (opp (or (plist-get attrs :oppose-count) 0))
         (ans (or (plist-get attrs :answer-count) 0))
         (inf (or (plist-get attrs :informed-count)
                  (plist-get attrs :source-count)
                  0))
         (parts '()))
    (when (> inf 0) (push (format "~%d" (round inf)) parts))
    (when (> ans 0) (push (format "?%d" (round ans)) parts))
    (when (> opp 0) (push (format "-%d" (round opp)) parts))
    (when (> supp 0) (push (format "+%d" (round supp)) parts))
    (when parts
      (format "[%s]" (string-join parts " ")))))

(defun dg-get-all-attributes (id)
  "Get all computed attributes for ID.
This overrides the original function to use customizable formulas."
  (let ((attrs (dg-compute-all-attributes id)))
    ;; Also include legacy attributes for backward compatibility
    (unless (plist-get attrs :support-count)
      (setq attrs (plist-put attrs :support-count
                             (dg--count-relations id "supports" 'incoming nil))))
    (unless (plist-get attrs :oppose-count)
      (setq attrs (plist-put attrs :oppose-count
                             (dg--count-relations id "opposes" 'incoming nil))))
    attrs))


(defun dg-get-summary (id)
  "Get summary for node ID.
Returns DG_SUMMARY property if exists, otherwise first paragraph."
  (let ((node (dg-get id)))
    (when node
      (let ((file (plist-get node :file))
            (pos (plist-get node :pos))
            (is-file-node (plist-get node :is-file-node)))
        (condition-case nil
            (let ((existing-buffer (get-file-buffer file)))
              (with-current-buffer (or existing-buffer
                                       (let ((inhibit-message t))
                                         (find-file-noselect file t)))
                (save-excursion
                  (save-restriction
                    (widen)
                    (goto-char (or pos (point-min)))
                    (let ((summary (org-entry-get nil "DG_SUMMARY")))
                      (if summary
                          (string-trim summary)
                        ;; Get first paragraph
                        (dg--extract-first-paragraph)))))))
          (error nil))))))

(defcustom dg-context-max-lines 30
  "Maximum number of lines to display for node content in context panel.
Set to nil for unlimited."
  :type '(choice integer (const nil))
  :group 'discourse-graph)

(defun dg--fetch-node-content (id)
  "Fetch complete content for node ID from source file.
Returns the body content (excluding properties drawer and planning lines).
Content is truncated according to `dg-context-max-lines'."
  (let ((node (dg-get id)))
    (when node
      (let ((file (plist-get node :file))
            (pos (plist-get node :pos)))
        (when (and file (file-readable-p file))
          (condition-case nil
              (let ((existing-buffer (get-file-buffer file)))
                (with-current-buffer (or existing-buffer
                                         (let ((inhibit-message t))
                                           (find-file-noselect file t)))
                  (save-excursion
                    (save-restriction
                      (widen)
                      (goto-char (or pos (point-min)))
                      (let* ((element (org-element-at-point))
                             (content-begin (org-element-property :contents-begin element))
                             (content-end (org-element-property :contents-end element)))
                        (when (and content-begin content-end)
                          (let ((raw-content (buffer-substring-no-properties
                                              content-begin content-end)))
                            ;; Clean up: remove properties drawer
                            (with-temp-buffer
                              (insert raw-content)
                              (goto-char (point-min))
                              ;; Remove :PROPERTIES: ... :END:
                              (when (re-search-forward "^[ \t]*:PROPERTIES:[ \t]*$" nil t)
                                (let ((prop-start (match-beginning 0)))
                                  (when (re-search-forward "^[ \t]*:END:[ \t]*$" nil t)
                                    (delete-region prop-start (1+ (point))))))
                              ;; Remove planning lines
                              (goto-char (point-min))
                              (while (looking-at-p "^[ \t]*\\(DEADLINE:\\|SCHEDULED:\\|CLOSED:\\)")
                                (delete-region (point) (progn (forward-line 1) (point))))
                              ;; Trim and truncate
                              (let ((content (string-trim (buffer-string))))
                                (when (and dg-context-max-lines
                                           (not (string-empty-p content)))
                                  (let* ((lines (split-string content "\n"))
                                         (total (length lines)))
                                    (when (> total dg-context-max-lines)
                                      (setq content
                                            (concat
                                             (string-join (seq-take lines dg-context-max-lines) "\n")
                                             (format "\n... (%d more lines)" (- total dg-context-max-lines)))))))
                                content)))))))))
            (error nil)))))))

(defun dg--extract-first-paragraph ()
  "Extract first non-empty paragraph after current heading or file start."
  (save-excursion
    (let ((bound (save-excursion
                   (or (outline-next-heading) (point-max))))
          (start nil)
          (result nil))
      ;; Skip properties drawer and blank lines
      (when (re-search-forward ":END:" bound t)
        (forward-line 1))
      ;; Find first non-empty line
      (while (and (< (point) bound)
                  (looking-at-p "^[ \t]*$"))
        (forward-line 1))
      (setq start (point))
      ;; Collect until blank line or heading or end
      (while (and (< (point) bound)
                  (not (looking-at-p "^[ \t]*$"))
                  (not (looking-at-p "^\\*")))
        (forward-line 1))
      (when (> (point) start)
        (setq result (string-trim
                      (buffer-substring-no-properties start (point)))))
      ;; Truncate if too long
      (when (and result (> (length result) 200))
        (setq result (concat (substring result 0 197) "...")))
      result)))


;;; ============================================================
;;; Discourse Context Panel
;;; ============================================================

(defun dg-context-refresh ()
  "Refresh discourse context for node at point."
  (interactive)
  (setq dg--current-node-id nil)  ;; Force refresh
  (let ((id (dg--get-id-at-point)))
    (if id
        (let ((node (dg-get id)))
          (if node
              (dg--display-context id)
            (message "Node ID '%s' not in database. Run dg-rebuild-cache?" id)))
      (message "No discourse graph node at point"))))

(defun dg--display-context (id)
  "Display discourse context for node ID in side window as org buffer."
  (setq dg--current-node-id id)
  (let* ((node (dg-get id))
         (rels (dg-get-relations id))
         (attrs (dg-get-all-attributes id))
         (outgoing (plist-get rels :outgoing))
         (incoming (plist-get rels :incoming))
         (node-type-str (plist-get node :type))
         (node-type (and node-type-str (intern node-type-str)))
         (type-info (alist-get node-type dg-node-types))
         (short (or (plist-get type-info :short) "?"))
         (stats-str (funcall dg-overlay-format-function attrs node-type)))
    (with-current-buffer (get-buffer-create dg--context-buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)

        ;; Back link if history exists
        (when dg--nav-history
          (let* ((prev-id (car dg--nav-history))
                 (prev-node (dg-get prev-id))
                 (prev-title (or (plist-get prev-node :title) prev-id)))
            (insert (format "[[dg:%s][ Back: %s]]\n\n"
                            prev-id
                            (truncate-string-to-width prev-title 28 nil nil "…")))))

        ;; Header with stats inline (consistent with overlay)
        (insert (format "#+title: [%s] %s"
                        short
                        (or (plist-get node :title) "Unknown")))
        (when stats-str
          (insert " " stats-str))
        (insert "\n")
        (insert (format "#+property: id %s\n" id))


        ;; Outgoing relations
        (when outgoing
          (let ((grouped (seq-group-by (lambda (r) (nth 1 r)) outgoing)))
            (dolist (group grouped)
              (let* ((rel-type (intern (car group)))
                     (display-name (capitalize (symbol-name rel-type))))
                (insert (format "\n*  %s\n" display-name))
                (dolist (r (cdr group))
                  (dg--insert-context-node r 'outgoing))))))

        ;; Incoming relations
        (when incoming
          (let ((grouped (seq-group-by (lambda (r) (nth 1 r)) incoming)))
            (dolist (group grouped)
              (let* ((rel-type (intern (car group)))
                     (rel-info (alist-get rel-type dg-relation-types))
                     (inverse-name (or (plist-get rel-info :inverse)
                                       (format "%s (inverse)" (car group)))))
                (insert (format "\n*  %s\n" inverse-name))
                (dolist (r (cdr group))
                  (dg--insert-context-node r 'incoming))))))

        ;; Setup mode and folding AFTER content is inserted
        (goto-char (point-min))
        ;; Apply dg-context-mode (inherits org-mode)
        (dg-context-mode)
        ;; Fold all level-2 headings (individual nodes), keep level-1 visible
        (save-excursion
          (goto-char (point-min))
          (while (re-search-forward "^\\*\\* " nil t)
            (org-cycle)))

        (display-buffer (current-buffer)
                        `(display-buffer-in-side-window
                          (side . right)
                          (window-width . ,dg-context-window-width)))))))

(defun dg--insert-context-node (rel direction)
  "Insert a node entry for REL in DIRECTION (outgoing or incoming).
REL is (direction rel_type node_id title type context_note)."
  (let* ((rel-type (nth 1 rel))
         (target-id (nth 2 rel))
         (target-title (or (nth 3 rel) "?"))
         (target-type (nth 4 rel))
         (context-note (nth 5 rel))
         (type-sym (and target-type (intern target-type)))
         (type-info (and type-sym (alist-get type-sym dg-node-types)))
         (type-short (or (plist-get type-info :short) "?")))
    ;; Level 2 heading: title + type tag (no link in heading)
    (insert (format "** %s :%s:\n" target-title type-short))
    ;; Link on separate line (hidden when folded)
    (insert (format "[[dg:%s]]\n" target-id))
    ;; Context note with relation type label
    (when (and context-note (not (string-empty-p context-note)))
      (let ((label (format "[%s_NOTE] " (upcase rel-type))))
        (insert (concat
                 (propertize label 'face 'dg-context-note-label 'font-lock-face 'dg-context-note-label)
                 (format "%s\n" context-note)))))
    ;; Node content (transclusion style)
    (let ((content (dg--fetch-node-content target-id)))
      (when (and content (not (string-empty-p content)))
        (insert "#+begin_quote\n")
        (insert content)
        (unless (string-suffix-p "\n" content)
          (insert "\n"))
        (insert "#+end_quote\n")))))

(defun dg-context-toggle ()
  "Toggle discourse context side window."
  (interactive)
  (unless discourse-graph-mode
    (user-error "Discourse Graph mode is not enabled. Run M-x discourse-graph-mode first"))
  (let ((win (get-buffer-window dg--context-buffer-name)))
    (if win
        (delete-window win)
      (dg-context-refresh))))

;; Custom link type for discourse graph
(org-link-set-parameters
 "dg"
 :follow #'dg--link-follow
 :face 'org-link)

(defun dg--link-follow (id _)
  "Follow a dg: link to node ID."
  ;; Push current to history before jumping
  (when dg--current-node-id
    (push dg--current-node-id dg--nav-history)
    (when (> (length dg--nav-history) dg--nav-history-max)
      (setq dg--nav-history (butlast dg--nav-history))))
  (dg-goto-node-by-id id))

(defun dg-context-go-back ()
  "Go back to previous node in navigation history."
  (interactive)
  (if dg--nav-history
      (let ((prev-id (pop dg--nav-history)))
        (setq dg--current-node-id nil) ; Force refresh
        (dg-goto-node-by-id prev-id))
    (message "No previous node in history")))

(defvar dg-context-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "g") #'dg-context-refresh)
    (define-key map (kbd "l") #'dg-context-go-back)  ; back like eww
    (define-key map (kbd "n") #'org-next-visible-heading)
    (define-key map (kbd "p") #'org-previous-visible-heading)
    (define-key map (kbd "TAB") #'org-cycle)
    (define-key map (kbd "<backtab>") #'org-global-cycle)
    (define-key map (kbd "RET") #'org-open-at-point)
    map)
  "Keymap for `dg-context-mode'.")

(define-derived-mode dg-context-mode org-mode "DG-Context"
  "Major mode for discourse graph context display.
Inherits from `org-mode' for folding and navigation.

Key bindings:
\\{dg-context-mode-map}"
  (setq-local buffer-read-only t)
  (setq-local org-startup-folded 'content)
  (setq-local cursor-type 'box))

;;; ============================================================
;;; Query Relations
;;; ============================================================

(defun dg-query-relations ()
  "Query relations of current node or selected node.
More intuitive: select a node, pick relation type, see results."
  (interactive)
  (let* ((current-id (dg--get-id-at-point))
         (use-current (and current-id
                           (y-or-n-p "Query from current node? ")))
         (node-id (if use-current
                      current-id
                    (let* ((all-nodes (dg-all-nodes))
                           (candidates (mapcar (lambda (n)
                                                 (cons (dg--format-node-choice n)
                                                       (plist-get n :id)))
                                               all-nodes))
                           (choice (completing-read "Select node: " candidates nil t)))
                      (alist-get choice candidates nil nil #'equal))))
         (direction (intern (completing-read
                             "Direction: "
                             '("both" "outgoing" "incoming"))))
         (rel-type (let ((choice (completing-read
                                  "Relation type: "
                                  (cons "all" (mapcar (lambda (x) (symbol-name (car x)))
                                                      dg-relation-types)))))
                     (if (string= choice "all") 'all (intern choice))))
         (results (dg--query-node-relations node-id direction rel-type)))
    (dg--display-relation-results node-id direction rel-type results)))

(defun dg--query-node-relations (id direction rel-type)
  "Query relations for node ID in DIRECTION with REL-TYPE."
  (let ((outgoing nil)
        (incoming nil))
    (when (memq direction '(outgoing both))
      (setq outgoing
            (if (eq rel-type 'all)
                (dg-find-outgoing id)
              (dg-find-outgoing id rel-type))))
    (when (memq direction '(incoming both))
      (setq incoming
            (if (eq rel-type 'all)
                (dg-find-incoming id)
              (dg-find-incoming id rel-type))))
    (list :outgoing outgoing :incoming incoming)))

(defun dg--display-relation-results (node-id direction rel-type results)
  "Display relation query RESULTS for NODE-ID."
  (let ((node (dg-get node-id))
        (outgoing (plist-get results :outgoing))
        (incoming (plist-get results :incoming))
        (buf (get-buffer-create "*DG Query Results*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)
        (insert (format "#+title: Relations of: %s\n\n" (plist-get node :title)))

        (when outgoing
          (insert (format "*  Outgoing (%d)\n" (length outgoing)))
          (dolist (n outgoing)
            (insert (format "** %s :%s:\n[[dg:%s]]\n"
                            (plist-get n :title)
                            (dg--node-type-short n)
                            (plist-get n :id)))))

        (when incoming
          (insert (format "*  Incoming (%d)\n" (length incoming)))
          (dolist (n incoming)
            (insert (format "** %s :%s:\n[[dg:%s]]\n"
                            (plist-get n :title)
                            (dg--node-type-short n)
                            (plist-get n :id)))))

        (when (and (null outgoing) (null incoming))
          (insert "No relations found.\n"))

        (goto-char (point-min))
        (org-content 1)
        (read-only-mode 1)))
    (pop-to-buffer buf)))

;;; ============================================================
;;; Node Navigation
;;; ============================================================

(defun dg--completing-read-node (prompt &optional type)
  "Interactively select a node with PROMPT, optionally filtered by TYPE."
  (let* ((sql (if type
                  "SELECT id, type, title FROM nodes WHERE type = ? ORDER BY title"
                "SELECT id, type, title FROM nodes ORDER BY type, title"))
         (params (when type (list (symbol-name type))))
         (rows (sqlite-select (dg--db) sql params))
         (candidates (mapcar (lambda (row)
                               (let* ((type-str (nth 1 row))
                                      (ntype (intern type-str))
                                      (type-info (alist-get ntype dg-node-types))
                                      (short (or (plist-get type-info :short) "?")))
                                 (cons (format "[%s] %s" short (nth 2 row))
                                       (nth 0 row))))
                             rows)))
    (when candidates
      (alist-get (completing-read prompt candidates) candidates nil nil #'equal))))

(defun dg-goto-node ()
  "Jump to a discourse graph node."
  (interactive)
  (let ((id (dg--completing-read-node "Go to node: ")))
    (when id
      (dg-goto-node-by-id id))))

(defun dg-goto-node-by-id (id)
  "Jump to node with ID."
  (let ((node (dg-get id)))
    (when node
      (find-file (plist-get node :file))
      (goto-char (plist-get node :pos))
      (org-reveal)
      (org-show-entry)
      (when dg-context-auto-update
        (run-with-idle-timer 0.1 nil #'dg-context-refresh)))))

;;; ============================================================
;;; Node Creation
;;; ============================================================

(defun dg--format-title (type title)
  "Format TITLE according to TYPE template if enabled."
  (if (and dg-auto-format-title dg-title-templates)
      (let ((template (alist-get type dg-title-templates)))
        (if template
            (format template title)
          title))
    title))

(defun dg-create-node (type title)
  "Create a new discourse graph node of TYPE with TITLE."
  (interactive
   (list (intern (completing-read "Type: " (mapcar #'car dg-node-types)))
         (read-string "Title: ")))
  (unless (derived-mode-p 'org-mode)
    (user-error "Must be in org-mode buffer to create node"))
  (if (dg--denote-available-p)
      ;; Use denote to create file-level node
      (dg--create-denote-node type title)
    ;; Create heading-level node
    (let ((id (dg-generate-id (format "%s-%s-%s" type title (float-time))))
          (formatted-title (dg--format-title type title)))
      (org-insert-heading-respect-content)
      (insert formatted-title)
      (org-set-property "ID" id)
      (org-set-property "DG_TYPE" (symbol-name type))
      (when (buffer-file-name)
        (save-buffer)
        (dg-update-file))
      (message "Created [%s] node: %s" type id)
      id)))

(defun dg-create-question (title)
  "Create a question node with TITLE."
  (interactive "sQuestion: ")
  (dg-create-node 'question title))

(defun dg-create-claim (title)
  "Create a claim node with TITLE."
  (interactive "sClaim: ")
  (dg-create-node 'claim title))

(defun dg-create-evidence (title)
  "Create an evidence node with TITLE."
  (interactive "sEvidence: ")
  (dg-create-node 'evidence title))

(defun dg-create-source (title)
  "Create a source node with TITLE."
  (interactive "sSource: ")
  (dg-create-node 'source title))

(defun dg-convert-to-node (type)
  "Convert current heading to a discourse graph node of TYPE."
  (interactive
   (list (intern (completing-read "Type: " (mapcar #'car dg-node-types)))))
  (unless (org-at-heading-p)
    (user-error "Not at a heading"))
  ;; Ensure ID exists
  (unless (org-entry-get nil "ID")
    (org-id-get-create))
  ;; Set DG_TYPE
  (org-set-property "DG_TYPE" (symbol-name type))
  (when (buffer-file-name)
    (save-buffer)
    (dg-update-file))
  (message "Converted to [%s] node" type))


;;; ============================================================
;;; Relation Management
;;; ============================================================

(defun dg-link (rel-type &optional with-note)
  "Add relation from current node.
If cursor is on a link, use that as target; otherwise prompt.
REL-TYPE is the relation type symbol.
With prefix argument (WITH-NOTE), also prompt for context note."
  (interactive
   (list (intern (completing-read
                  "Relation: "
                  (mapcar #'car dg-relation-types)
                  nil t))
         current-prefix-arg))
  (let ((source-id (dg--get-id-at-point)))
    (unless source-id
      (user-error "Not on a discourse node"))
    (let* ((link-target (dg--link-id-at-point))
           (target-id (or link-target
                          (dg--completing-read-node "Target: "))))
      (when target-id
        (let* ((prop (concat "DG_" (upcase (symbol-name rel-type))))
               (note-prop (concat prop "_NOTE"))
               (existing (org-entry-get nil prop))
               (note (when with-note
                       (read-string "Context note (why this relation?): "))))
          (org-set-property prop
                            (if existing
                                (concat existing " " target-id)
                              target-id))
          (when (and note (not (string-empty-p note)))
            (org-set-property note-prop note))
          (let ((target-node (dg-get target-id)))
            (message "%s -> %s%s (save to update)"
                     rel-type
                     (or (plist-get target-node :title) target-id)
                     (if note " [with note]" ""))))))))

(defun dg-remove-relation ()
  "Remove a relation from current node.
Shows all relations and lets user select which to remove."
  (interactive)
  (let* ((id (dg--get-id-at-point)))
    (unless id
      (user-error "No discourse graph node at point"))
    (let* ((rels (dg-get-relations id))
           (outgoing (plist-get rels :outgoing))
           (candidates
            (mapcar (lambda (r)
                      (let* ((rel-type (nth 1 r))
                             (target-id (nth 2 r))
                             (target-title (nth 3 r)))
                        (cons (format "%s  %s (%s)"
                                      rel-type
                                      (or target-title target-id)
                                      target-id)
                              (list rel-type target-id))))
                    outgoing)))
      (if (null candidates)
          (message "No outgoing relations to remove")
        (let* ((choice (completing-read "Remove relation: " candidates nil t))
               (rel-info (cdr (assoc choice candidates)))
               (rel-type (car rel-info))
               (target-id (cadr rel-info))
               (prop (concat "DG_" (upcase rel-type)))
               (current (org-entry-get nil prop)))
          (when current
            (let* ((ids (split-string current "[ \t,]+" t))
                   (new-ids (delete target-id ids)))
              (if new-ids
                  (org-set-property prop (string-join new-ids " "))
                (org-delete-property prop))))
          ;; Also remove from database immediately
          (sqlite-execute
           (dg--db)
           "DELETE FROM relations WHERE source_id = ? AND target_id = ? AND rel_type = ?"
           (list id target-id rel-type))
          (message "Removed: %s  %s (save to update context)" rel-type target-id))))))


(defun dg-unmark-node ()
  "Remove DG_TYPE from current heading, converting it back to regular heading.
Also removes from database. Relations and other DG properties are preserved
but will be ignored until DG_TYPE is set again."
  (interactive)
  (let ((id (dg--get-id-at-point)))
    (unless id
      (user-error "No discourse graph node at point"))
    (when (yes-or-no-p "Remove this heading from discourse graph? ")
      ;; Remove from database
      (sqlite-execute (dg--db) "DELETE FROM nodes WHERE id = ?" (list id))
      (sqlite-execute (dg--db) "DELETE FROM relations WHERE source_id = ? OR target_id = ?"
                      (list id id))
      ;; Remove DG_TYPE property
      (org-delete-property "DG_TYPE")
      (message "Node removed from discourse graph"))))

;;; ============================================================
;;; Export: Graphviz SVG
;;; ============================================================

(defcustom dg-graphviz-command "dot"
  "Graphviz command for rendering graphs."
  :type 'string
  :group 'discourse-graph)

(defun dg--dot-escape (str)
  "Escape STR for use in DOT labels."
  (when str
    (replace-regexp-in-string
     "\""
     "\\\\\""
     (replace-regexp-in-string
      "\n"
      "\\\\n"
      str))))

(defun dg--generate-dot (nodes-hash edges &optional center-id)
  "Generate DOT content string for NODES-HASH and EDGES.
NODES-HASH is a hash table of node IDs.
EDGES is a list of (source-id rel-type target-id).
If CENTER-ID provided, highlight that node."
  (with-temp-buffer
    (insert "digraph DiscourseGraph {\n")
    (insert "  rankdir=LR;\n")
    (insert "  bgcolor=transparent;\n")
    (insert "  node [shape=box, style=rounded, color=\"black\", fontcolor=\"black\"];\n")
    (insert "  edge [color=\"black\", fontcolor=\"black\"];\n\n")
    ;; Nodes
    (maphash
     (lambda (id _)
       (let* ((node (dg-get id))
              (title (or (plist-get node :title) id))
              (color (dg--node-type-color node))
              (is-center (and center-id (string= id center-id))))
         (insert (format "  \"%s\" [label=\"%s\", fillcolor=\"%s\", style=\"%s\"];\n"
                         id
                         (dg--dot-escape (truncate-string-to-width title 30 nil nil "…"))
                         color
                         (if is-center "filled,bold,rounded" "filled,rounded")))))
     nodes-hash)
    ;; Edges
    (dolist (edge edges)
      (let* ((from (nth 0 edge))
             (rel-type-str (nth 1 edge))
             (to (nth 2 edge))
             (rel-sym (and rel-type-str (intern rel-type-str)))
             (rel-info (and rel-sym (alist-get rel-sym dg-relation-types)))
             (style (or (and rel-info (plist-get rel-info :style)) "solid")))
        (insert (format "  \"%s\" -> \"%s\" [label=\"%s\", style=\"%s\"];\n"
                        from to rel-type-str style))))
    (insert "}\n")
    (buffer-string)))

(defun dg--dot-to-svg (dot-content file &optional for-web)
  "Convert DOT-CONTENT to SVG and save to FILE.
If FOR-WEB is non-nil, use CSS variables for theming.
Otherwise use current Emacs theme colors.
Returns t on success, nil on failure."
  (let ((dot-file (make-temp-file "dg-export" nil ".dot"))
        (fg-color (if for-web
                      "var(--fg, #333)"
                    (face-foreground 'default nil 'default)))
        (bg-color (if for-web
                      "var(--bg, #fff)"
                    (face-background 'default nil 'default))))
    (unwind-protect
        (progn
          (with-temp-file dot-file
            (insert dot-content))
          (when (executable-find dg-graphviz-command)
            (let ((raw-svg (make-temp-file "dg-export" nil ".svg")))
              (unwind-protect
                  (progn
                    (call-process dg-graphviz-command nil nil nil
                                  "-Tsvg" dot-file "-o" raw-svg)
                    (with-temp-file file
                      (insert-file-contents raw-svg)
                      ;; Insert CSS style block after <svg> tag
                      (goto-char (point-min))
                      (when (re-search-forward "<svg[^>]*>" nil t)
                        (insert (format "\n<style>
  .node text { fill: #333; }
  .edge text { fill: %s; }
  .edge path, .edge polygon { stroke: %s; }
</style>\n" fg-color fg-color)))
                      ;; Replace explicit black/white values
                      (dolist (black '("=\"black\"" "=\"#000000\"" "=\"#000\""))
                        (goto-char (point-min))
                        (while (search-forward black nil t)
                          (replace-match (format "=\"%s\"" fg-color))))
                      (dolist (white '("=\"white\"" "=\"#ffffff\"" "=\"#fff\""))
                        (goto-char (point-min))
                        (while (search-forward white nil t)
                          (replace-match (format "=\"%s\"" bg-color)))))
                    t)
                (delete-file raw-svg)))))
      (delete-file dot-file))))

(defun dg-export-svg (&optional file)
  "Export entire discourse graph to SVG.
The SVG uses CSS variables for colors, suitable for light/dark mode."
  (interactive "FExport to SVG file: ")
  (let* ((nodes (sqlite-select (dg--db) "SELECT id FROM nodes"))
         (relations (sqlite-select (dg--db) "SELECT source_id, rel_type, target_id FROM relations"))
         (nodes-hash (make-hash-table :test 'equal)))
    ;; Build nodes hash
    (dolist (node nodes)
      (puthash (nth 0 node) t nodes-hash))
    ;; Generate and convert
    (let ((dot-content (dg--generate-dot nodes-hash relations)))
      (if (dg--dot-to-svg dot-content file t)
          (message "Exported %d nodes, %d relations to %s"
                   (length nodes) (length relations) file)
        (user-error "Failed to generate SVG. Is Graphviz installed?")))))

;;; ============================================================
;;; Export: Markdown
;;; ============================================================

(defun dg--sanitize-filename (title)
  "Sanitize TITLE for use as filename."
  (let ((clean (replace-regexp-in-string "[\\/:*?\"<>|]" "_" title)))
    (truncate-string-to-width clean 60 nil nil)))

(defun dg--format-md-link (title)
  "Format markdown link to TITLE."
  (pcase dg-export-link-style
    ('wikilink (format "[[%s]]" title))
    ('markdown (format "[%s](%s.md)" title (dg--sanitize-filename title)))))

(defun dg-export-markdown (&optional directory)
  "Export entire discourse graph to markdown files in DIRECTORY."
  (interactive "DExport to directory: ")
  (let ((nodes (sqlite-select (dg--db)
                              "SELECT id, type, title, outline_path FROM nodes"))
        (exported 0))
    (dolist (row nodes)
      (let* ((id (nth 0 row))
             (ntype (nth 1 row))
             (title (nth 2 row))
             (filename (dg--sanitize-filename title))
             (filepath (expand-file-name (concat filename ".md") directory))
             (rels (dg-get-relations id))
             (attrs (dg-get-all-attributes id)))
        (with-temp-file filepath
          ;; YAML front matter
          (insert "---\n")
          (insert (format "title: \"%s\"\n" (replace-regexp-in-string "\"" "\\\\\"" title)))
          (insert (format "type: %s\n" ntype))
          (insert (format "id: %s\n" id))
          (insert "---\n\n")
          ;; Title
          (insert (format "# %s\n\n" title))
          ;; Attributes
          (insert "## Attributes\n\n")
          (insert (format "- **Type**: %s\n" ntype))
          (let ((supp (plist-get attrs :support-count))
                (opp (plist-get attrs :oppose-count))
                (score (plist-get attrs :evidence-score)))
            (cond
             ((and (> supp 0) (> opp 0))
              (insert (format "- **Support Score**: %+d (↑%d ↓%d)\n" score supp opp)))
             ((> supp 0)
              (insert (format "- **Support Score**: %+d (↑%d)\n" score supp)))
             ((> opp 0)
              (insert (format "- **Support Score**: %+d (↓%d)\n" score opp)))))
          ;; Relations
          (when (plist-get rels :outgoing)
            (insert "\n## Outgoing Relations\n\n")
            (let ((grouped (seq-group-by (lambda (r) (nth 1 r))
                                         (plist-get rels :outgoing))))
              (dolist (group grouped)
                (insert (format "### %s\n\n" (car group)))
                (dolist (r (cdr group))
                  (let ((target-title (or (nth 3 r) (nth 2 r))))
                    (insert (format "- %s\n" (dg--format-md-link target-title))))))))
          (when (plist-get rels :incoming)
            (insert "\n## Incoming Relations\n\n")
            (let ((grouped (seq-group-by (lambda (r) (nth 1 r))
                                         (plist-get rels :incoming))))
              (dolist (group grouped)
                (insert (format "### %s\n\n" (car group)))
                (dolist (r (cdr group))
                  (let ((source-title (or (nth 3 r) (nth 2 r))))
                    (insert (format "- %s\n" (dg--format-md-link source-title)))))))))
        (cl-incf exported)))
    (message "Exported %d nodes to %s" exported directory)))

;;; ============================================================
;;; Overlay System (Relation Count Indicators)
;;; ============================================================

(defvar-local dg--overlays nil
  "List of discourse graph overlays in current buffer.")

(defface dg-overlay-face
  '((t :foreground "gray60"))
  "Face for discourse graph overlay indicators."
  :group 'discourse-graph)

(defface dg-context-note-label
  '((t :inherit font-lock-keyword-face))
  "Face for relation type label in context notes."
  :group 'discourse-graph)

(defun dg--make-overlay-string (id)
  "Create overlay string for node ID using customizable attributes."
  (let* ((node (dg-get id))
         (node-type (and node (intern (plist-get node :type))))
         (attrs (dg-get-all-attributes id))
         (overlay-str (funcall dg-overlay-format-function attrs node-type)))
    (when overlay-str
      (concat " " (propertize overlay-str 'face 'dg-overlay-face)))))

(defun dg-overlay-update ()
  "Update overlays for all discourse nodes in current buffer."
  (interactive)
  (when (and discourse-graph-mode
             dg-overlay-enable
             (derived-mode-p 'org-mode))
    (dg-overlay-clear)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^\\*+ " nil t)
        (let ((id (org-entry-get nil "ID")))
          (when (and id (org-entry-get nil "DG_TYPE"))
            (let* ((overlay-str (dg--make-overlay-string id))
                   (eol (line-end-position)))
              (when overlay-str
                (let ((ov (make-overlay eol eol)))
                  (overlay-put ov 'after-string overlay-str)
                  (overlay-put ov 'dg-overlay t)
                  (push ov dg--overlays))))))))))

(defun dg-overlay-clear ()
  "Clear all discourse graph overlays in current buffer."
  (interactive)
  (dolist (ov dg--overlays)
    (delete-overlay ov))
  (setq dg--overlays nil))

(defun dg-overlay-toggle ()
  "Toggle overlay display."
  (interactive)
  (setq dg-overlay-enable (not dg-overlay-enable))
  (if dg-overlay-enable
      (progn
        (dg-overlay-update)
        (message "Discourse Graph overlays enabled"))
    (dg-overlay-clear)
    (message "Discourse Graph overlays disabled")))

;;; ============================================================
;;; Smart Relation Commands

;;; ============================================================
;;; Graph Preview
;;; ============================================================

(defun dg-graph-preview (&optional depth)
  "Preview graph neighborhood around current node as SVG.
DEPTH controls how many levels of relations to include (default 2)."
  (interactive "P")
  (let* ((center-id (dg--get-id-at-point))
         (depth (or depth 2))
         (nodes-seen (make-hash-table :test 'equal))
         (edges '())
         (svg-file (make-temp-file "dg-preview" nil ".svg")))
    (unless center-id
      (user-error "Not on a discourse node"))
    ;; Collect nodes using BFS
    (dg--collect-neighborhood center-id depth nodes-seen)
    ;; Collect edges between seen nodes
    (maphash (lambda (id _)
               (let ((rels (sqlite-select
                            (dg--db)
                            "SELECT source_id, rel_type, target_id FROM relations WHERE source_id = ?"
                            (list id))))
                 (dolist (rel rels)
                   (when (gethash (nth 2 rel) nodes-seen)
                     (push rel edges)))))
             nodes-seen)
    ;; Generate and display
    (let ((dot-content (dg--generate-dot nodes-seen edges center-id)))
      (if (dg--dot-to-svg dot-content svg-file nil)
          (progn
            (find-file svg-file)
            (message "Graph preview: %d nodes, %d edges"
                     (hash-table-count nodes-seen) (length edges)))
        ;; Fallback: show DOT
        (let ((dot-file (make-temp-file "dg-preview" nil ".dot")))
          (with-temp-file dot-file
            (insert dot-content))
          (find-file dot-file)
          (message "Graphviz not found, showing DOT file"))))))

(defun dg--collect-neighborhood (id depth seen)
  "Collect nodes in neighborhood of ID up to DEPTH into SEEN hash."
  (when (and (> depth 0) (not (gethash id seen)))
    (puthash id t seen)
    ;; Get relations directly from database
    (let ((rels (sqlite-select
                 (dg--db)
                 "SELECT source_id, target_id FROM relations
                  WHERE source_id = ? OR target_id = ?"
                 (list id id))))
      (dolist (rel rels)
        (let ((source (nth 0 rel))
              (target (nth 1 rel)))
          ;; Recurse on the other end of the relation
          (when (string= source id)
            (dg--collect-neighborhood target (1- depth) seen))
          (when (string= target id)
            (dg--collect-neighborhood source (1- depth) seen)))))))

;;; ============================================================
;;; Validation and Consistency Checks
;;; ============================================================

(defun dg-validate ()
  "Validate discourse graph for consistency issues."
  (interactive)
  (let ((issues nil)
        (nodes (dg-all-nodes))
        (node-ids (make-hash-table :test 'equal)))
    ;; Build ID set
    (dolist (node nodes)
      (puthash (plist-get node :id) t node-ids))
    ;; Check relations
    (let ((rows (sqlite-select (dg--db)
                               "SELECT source_id, target_id, rel_type FROM relations")))
      (dolist (row rows)
        (let ((source (nth 0 row))
              (target (nth 1 row))
              (rel-type (nth 2 row)))
          ;; Check for dangling references
          (unless (gethash source node-ids)
            (push (format "Dangling source: %s in relation %s%s" source rel-type target) issues))
          (unless (gethash target node-ids)
            (push (format "Dangling target: %s in relation %s%s" target rel-type source) issues)))))
    ;; Check for orphan nodes
    (dolist (node nodes)
      (let* ((id (plist-get node :id))
             (outgoing (dg-find-outgoing id))
             (incoming (dg-find-incoming id)))
        (when (and (null outgoing) (null incoming))
          (push (format "Orphan node: %s (%s)" (plist-get node :title) id) issues))))
    ;; Check for missing files
    (dolist (node nodes)
      (let ((file (plist-get node :file)))
        (unless (file-exists-p file)
          (push (format "Missing file: %s for node %s" file (plist-get node :id)) issues))))
    ;; Display results
    (if issues
        (let ((buf (get-buffer-create "*DG Validation*")))
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert (format "Discourse Graph Validation: %d issues found\n\n" (length issues)))
              (dolist (issue (nreverse issues))
                (insert (format "• %s\n" issue)))
              (goto-char (point-min))
              (special-mode)))
          (pop-to-buffer buf))
      (message "Discourse Graph validation passed: no issues found"))))

;;; ============================================================
;;; Attribute Commands
;;; ============================================================

(defun dg-use-detailed-overlay ()
  "Switch to detailed overlay format."
  (interactive)
  (setq dg-overlay-format-function #'dg-detailed-overlay-format)
  (when dg-overlay-enable (dg-overlay-update))
  (message "Using detailed overlay format"))

(defun dg-use-simple-overlay ()
  "Switch to simple overlay format."
  (interactive)
  (setq dg-overlay-format-function #'dg-default-overlay-format)
  (when dg-overlay-enable (dg-overlay-update))
  (message "Using simple overlay format"))

;;; ============================================================
;;; Transient Menus
;;; ============================================================

(transient-define-prefix dg-menu ()
  "Discourse Graph main menu."
  ["Discourse Graph"
   ["Create"
    ("c" "Create node..." dg-create-node)
    ("C" "Convert heading" dg-convert-to-node)
    ("q" "Question" dg-create-question)
    ("l" "Claim" dg-create-claim)
    ("e" "Evidence" dg-create-evidence)
    ("s" "Source" dg-create-source)]
   ["Relations"
    ("r" "Add relation" dg-link)
    ("D" "Remove relation" dg-remove-relation)]
   ["Navigate"
    ("g" "Go to node" dg-goto-node)
    ("x" "Toggle context" dg-context-toggle)
    ("b" "Go back" dg-context-go-back)
    ("p" "Graph preview" dg-graph-preview)]]
  [["Analysis"
    ("S" "Synthesis" dg-synthesis-open)
    ("A" "Analyze question" dg-analyze-question)
    ("?" "Query this node" dg-query-relations)]
   ["Export"
    ("E s" "SVG" dg-export-svg)
    ("E m" "Markdown" dg-export-markdown)]]
  [["Maintain"
    ("!" "Rebuild cache" dg-rebuild-cache)
    ("v" "Validate" dg-validate)]
   ["Display"
    ("o" "Toggle overlays" dg-overlay-toggle)
    ("d" "Detailed overlay" dg-use-detailed-overlay)
    ("D" "Simple overlay" dg-use-simple-overlay)
    ("W" "Configure..." dg-configure)]])

(transient-define-prefix dg-configure ()
  "Discourse Graph configuration."
  ["Configuration"
   ["Directories"
    ("d" "Directories" dg--set-directories)
    ("r" "Recursive scan" dg--toggle-recursive)]
   ["Display"
    ("o" "Overlay enable" dg--toggle-overlay)
    ("a" "Auto-update context" dg--toggle-auto-update)
    ("w" "Context width" dg--set-context-width)]
   ["Denote"
    ("D" "Use denote" dg--toggle-denote)
    ("K" "Keywords as type" dg--toggle-keywords-type)]
   ["Export"
    ("l" "Link style" dg--cycle-link-style)]])

(defun dg--set-directories ()
  "Set discourse graph directories."
  (interactive)
  (let ((dir (read-directory-name "Add directory: ")))
    (add-to-list 'dg-directories dir)
    (message "Directories: %s" dg-directories)))

(defun dg--toggle-recursive ()
  "Toggle recursive directory scan."
  (interactive)
  (setq dg-recursive (not dg-recursive))
  (message "Recursive scan: %s" (if dg-recursive "ON" "OFF")))

(defun dg--toggle-overlay ()
  "Toggle overlay display."
  (interactive)
  (dg-overlay-toggle))

(defun dg--toggle-auto-update ()
  "Toggle auto-update context."
  (interactive)
  (setq dg-context-auto-update (not dg-context-auto-update))
  (message "Auto-update context: %s" (if dg-context-auto-update "ON" "OFF")))

(defun dg--set-context-width ()
  "Set context window width."
  (interactive)
  (setq dg-context-window-width
        (read-number "Context width: " dg-context-window-width))
  (message "Context width: %d" dg-context-window-width))

(defun dg--toggle-denote ()
  "Toggle denote compatibility."
  (interactive)
  (setq dg-use-denote (not dg-use-denote))
  (message "Denote compatibility: %s" (if dg-use-denote "ON" "OFF")))

(defun dg--toggle-keywords-type ()
  "Toggle denote keywords as type."
  (interactive)
  (setq dg-denote-keywords-as-type (not dg-denote-keywords-as-type))
  (message "Denote keywords as type: %s" (if dg-denote-keywords-as-type "ON" "OFF")))

(defun dg--cycle-link-style ()
  "Cycle export link style."
  (interactive)
  (setq dg-export-link-style
        (pcase dg-export-link-style
          ('wikilink 'markdown)
          ('markdown 'wikilink)))
  (message "Link style: %s" dg-export-link-style))

;;; ============================================================
;;; Hooks and Auto-update
;;; ============================================================

(defun dg--after-save-hook ()
  "Hook to update index after saving org file."
  (when (and discourse-graph-mode
             (derived-mode-p 'org-mode)
             (buffer-file-name))
    (dg-update-file)
    ;; Update overlays after save
    (when dg-overlay-enable
      (run-with-idle-timer 0.5 nil #'dg-overlay-update))
    ;; Refresh context panel if visible
    (when (get-buffer-window dg--context-buffer-name)
      (let ((id (dg--get-id-at-point)))
        (when id
          (setq dg--current-node-id nil)
          (run-with-idle-timer 0.3 nil
                               (lambda () (dg--display-context id))))))))

(defun dg--post-command-hook ()
  "Hook to auto-update context when moving to different node."
  (when (and discourse-graph-mode
             dg-context-auto-update
             (derived-mode-p 'org-mode)
             ;; Don't trigger in context buffer itself
             (not (string= (buffer-name) dg--context-buffer-name))
             (get-buffer-window dg--context-buffer-name))
    ;; Always cancel previous timer first
    (when dg--context-timer
      (cancel-timer dg--context-timer)
      (setq dg--context-timer nil))
    ;; Capture current buffer and window
    (let ((buf (current-buffer))
          (win (selected-window)))
      (setq dg--context-timer
            (run-with-idle-timer
             0.3 nil
             (lambda ()
               (setq dg--context-timer nil)
               ;; Check ID at current cursor position in window
               (when (and (window-live-p win)
                          (buffer-live-p buf)
                          (eq (window-buffer win) buf))
                 (with-current-buffer buf
                   (save-excursion
                     (goto-char (window-point win))
                     (let ((id (dg--get-id-at-point)))
                       (when (and id (not (equal id dg--current-node-id)))
                         (dg--display-context id))))))))))))

;;; ============================================================
;;; Keybindings
;;; ============================================================

(defvar dg-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Core commands only - use C-c d d for full menu
    (define-key map (kbd "C-c d d") #'dg-menu)       ; Main menu
    (define-key map (kbd "C-c d c") #'dg-create-node) ; Create
    (define-key map (kbd "C-c d r") #'dg-link)        ; Relation
    (define-key map (kbd "C-c d x") #'dg-context-toggle) ; Context
    (define-key map (kbd "C-c d g") #'dg-goto-node)   ; Go to
    (define-key map (kbd "C-c d !") #'dg-rebuild-cache) ; Rebuild
    map)
  "Keymap for `discourse-graph-mode'.
Only essential commands are bound. Use \\[dg-menu] for full menu.")

;;; ============================================================
;;; Minor Mode Definition
;;; ============================================================

;;;###autoload
(define-minor-mode discourse-graph-mode
  "Minor mode for discourse graph knowledge synthesis.

Key bindings:
  \\[dg-menu]           Open main menu (discover all commands)
  \\[dg-create-node]    Create a new node
  \\[dg-link]           Add relation (smart: uses link at point or prompts)
  \\[dg-context-toggle] Toggle context panel
  \\[dg-goto-node]      Jump to a node
  \\[dg-rebuild-cache]  Rebuild database cache

All other commands available via \\[dg-menu]."
  :global t
  :lighter " DG"
  :keymap dg-mode-map
  (if discourse-graph-mode
      (progn
        (add-hook 'after-save-hook #'dg--after-save-hook)
        (add-hook 'post-command-hook #'dg--post-command-hook)
        (add-hook 'org-mode-hook #'dg--org-mode-setup)
        ;; Initialize database
        (dg--db)
        ;; Update overlays in all existing org buffers
        (when dg-overlay-enable
          (dolist (buf (buffer-list))
            (with-current-buffer buf
              (when (derived-mode-p 'org-mode)
                (dg-overlay-update)))))
        (message "Discourse Graph mode enabled. Press C-c d d for menu."))
    (remove-hook 'after-save-hook #'dg--after-save-hook)
    (remove-hook 'post-command-hook #'dg--post-command-hook)
    (remove-hook 'org-mode-hook #'dg--org-mode-setup)
    ;; Clear overlays in all org buffers
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (derived-mode-p 'org-mode)
          (dg-overlay-clear))))
    ;; Close context buffer
    (when-let* ((ctx-buf (get-buffer dg--context-buffer-name)))
      (when-let* ((win (get-buffer-window ctx-buf)))
        (delete-window win))
      (kill-buffer ctx-buf))
    (setq dg--current-node-id nil)
    (setq dg--nav-history nil)
    (message "Discourse Graph mode disabled")))

(defun dg--org-mode-setup ()
  "Setup for org-mode buffers when discourse-graph-mode is active."
  (when discourse-graph-mode
    ;; Update overlays after a short delay
    (run-with-idle-timer 1 nil #'dg-overlay-update)))


;;; ============================================================
;;; Configuration
;;; ============================================================

(defcustom dg-synthesis-file nil
  "Path to the synthesis file. If nil, uses dg-directories."
  :type '(choice (const nil) file)
  :group 'discourse-graph)

;;; ============================================================
;;; Core Analysis Functions
;;; ============================================================

(defun dg--get-argument-gaps (claim-id)
  "Check structural completeness of argument for CLAIM-ID.
Returns list of gap types."
  (let ((gaps nil)
        (supporting (dg-find-supporting-evidence claim-id))
        (opposing (dg-find-opposing-evidence claim-id)))
    ;; Gap 1: No supporting evidence at all
    (when (= (length supporting) 0)
      (push 'no-support gaps))
    ;; Gap 2: Supporting evidence lacks sources
    (when (and (> (length supporting) 0)
               (seq-every-p (lambda (ev)
                              (= (length (dg-find-outgoing (plist-get ev :id) 'informs)) 0))
                            supporting))
      (push 'no-source gaps))
    ;; Gap 3: Has opposition but no/insufficient response
    (when (and (> (length opposing) 0)
               (<= (length supporting) (length opposing)))
      (push 'unanswered-opposition gaps))
    gaps))

(defun dg--analyze-question-answers (question-id)
  "Analyze all answers to QUESTION-ID with structural assessment."
  (let ((answers (dg-find-answers question-id)))
    (mapcar
     (lambda (answer)
       (let* ((id (plist-get answer :id))
              (title (plist-get answer :title))
              (supporting (dg-find-supporting-evidence id))
              (opposing (dg-find-opposing-evidence id))
              (gaps (dg--get-argument-gaps id))
              ;; Structural strength assessment
              (strength (cond
                         ((member 'no-support gaps) 'unsupported)
                         ((member 'unanswered-opposition gaps) 'challenged)
                         ((> (length opposing) 0) 'contested)
                         ((> (length supporting) 0) 'supported)
                         (t 'unknown))))
         (list :id id
               :title title
               :support-count (length supporting)
               :oppose-count (length opposing)
               :gaps gaps
               :strength strength
               :supporting supporting
               :opposing opposing)))
     answers)))

;;; ============================================================
;;; dg-synthesis: Question Analysis Block
;;; ============================================================

(defun org-dblock-write:dg-synthesis (params)
  "Analyze a question: compare answers by argument structure."
  (let* ((q-ref (or (plist-get params :id) (plist-get params :question)))
         (question-id (dg--resolve-node-ref q-ref))
         (question (and question-id (dg-get question-id))))
    (if (not question)
        (insert (format "/Question not found: %s/\n" q-ref))
      (let* ((analyses (dg--analyze-question-answers question-id))
             ;; Sort by structural strength
             (sorted (seq-sort-by
                      (lambda (a)
                        (pcase (plist-get a :strength)
                          ('supported 0)
                          ('contested 1)
                          ('challenged 2)
                          ('unsupported 3)
                          (_ 4)))
                      #'< analyses)))
        (insert (format "/Updated: %s/\n\n" (format-time-string "%Y-%m-%d %H:%M")))
        (if (null sorted)
            (insert "/No answers to this question yet./\n")
          ;; Answer ranking table
          (insert "** Answer Structure\n\n")
          (insert "| Answer | Status | +Ev | -Ev | Gaps |\n")
          (insert "|---+---+---+---+---|\n")
          (dolist (a sorted)
            (let* ((id (plist-get a :id))
                   (title (plist-get a :title))
                   (strength (plist-get a :strength))
                   (status (pcase strength
                             ('supported "✓ Supported")
                             ('contested "⚡ Contested")
                             ('challenged "⚠ Challenged")
                             ('unsupported "✗ Unsupported")
                             (_ "?")))
                   (gaps (plist-get a :gaps))
                   (gap-str (if gaps
                                (mapconcat #'symbol-name gaps ", ")
                              "—")))
              (insert (format "| [[dg:%s][%s]] | %s | %d | %d | %s |\n"
                              id
                              (truncate-string-to-width title 28 nil nil "…")
                              status
                              (plist-get a :support-count)
                              (plist-get a :oppose-count)
                              gap-str))))
          ;; Align table
          (save-excursion
            (forward-line -1)
            (when (org-at-table-p)
              (org-table-align)))
          ;; Evidence details
          (insert "\n** Evidence Details\n")
          (dolist (a sorted)
            (let* ((id (plist-get a :id))
                   (title (plist-get a :title))
                   (strength (plist-get a :strength))
                   (supporting (plist-get a :supporting))
                   (opposing (plist-get a :opposing)))
              (insert (format "\n*** %s\n" (truncate-string-to-width title 50 nil nil "…")))
              (insert (format "Status: *%s*\n\n" strength))
              ;; Supporting evidence with sources
              (if supporting
                  (progn
                    (insert "**** Supporting\n")
                    (dolist (ev supporting)
                      (let* ((ev-id (plist-get ev :id))
                             (ev-title (plist-get ev :title))
                             (sources (dg-find-outgoing ev-id 'informs))
                             (src-names (mapcar (lambda (s) (plist-get s :title)) sources)))
                        (insert (format "- [[dg:%s][%s]]\n"
                                        ev-id
                                        (truncate-string-to-width ev-title 50 nil nil "…")))
                        (if sources
                            (insert (format "  Sources: %s\n"
                                            (truncate-string-to-width
                                             (string-join src-names ", ") 50 nil nil "…")))
                          (insert "  ⚠ /no source cited/\n")))))
                (insert "**** Supporting\n/None/\n"))
              ;; Opposing evidence
              (if opposing
                  (progn
                    (insert "**** Opposing\n")
                    (dolist (ev opposing)
                      (let* ((ev-id (plist-get ev :id))
                             (ev-title (plist-get ev :title))
                             (sources (dg-find-outgoing ev-id 'informs)))
                        (insert (format "- [[dg:%s][%s]] (%d sources)\n"
                                        ev-id
                                        (truncate-string-to-width ev-title 50 nil nil "…")
                                        (length sources))))))
                (insert "**** Opposing\n/None/\n"))
              ;; Gaps warning
              (when (plist-get a :gaps)
                (insert (format "\n⚠ *Structural gaps:* %s\n"
                                (mapconcat #'symbol-name (plist-get a :gaps) ", ")))))))))))

;;; ============================================================
;;; dg-unanswered-opposition: Find unresponded objections
;;; ============================================================

(defun org-dblock-write:dg-unanswered-opposition (params)
  "Find claims with objections that were never adequately responded to."
  (let* ((limit (or (plist-get params :limit) 20))
         (claims (dg-find-by-type 'claim))
         (with-unanswered
          (seq-filter
           (lambda (c)
             (let* ((id (plist-get c :id))
                    (opposing (dg-find-opposing-evidence id))
                    (supporting (dg-find-supporting-evidence id)))
               (and (> (length opposing) 0)
                    (<= (length supporting) (length opposing)))))
           claims))
         ;; Sort by severity
         (sorted (seq-sort-by
                  (lambda (c)
                    (let* ((id (plist-get c :id))
                           (opp (length (dg-find-opposing-evidence id)))
                           (supp (length (dg-find-supporting-evidence id))))
                      (- opp supp)))
                  #'> with-unanswered))
         (limited (seq-take sorted limit)))
    (insert (format "/Updated: %s/\n\n" (format-time-string "%Y-%m-%d %H:%M")))
    (if (null limited)
        (insert "/All objections have been responded to./\n")
      (insert "| Claim | Objections | Responses | Deficit |\n")
      (insert "|---+---+---+---|\n")
      (dolist (c limited)
        (let* ((id (plist-get c :id))
               (title (plist-get c :title))
               (opp-count (length (dg-find-opposing-evidence id)))
               (supp-count (length (dg-find-supporting-evidence id))))
          (insert (format "| [[dg:%s][%s]] | %d | %d | %d |\n"
                          id
                          (truncate-string-to-width title 35 nil nil "…")
                          opp-count supp-count
                          (- opp-count supp-count)))))
      ;; Align table
      (save-excursion
        (forward-line -1)
        (when (org-at-table-p)
          (org-table-align))))))

;;; ============================================================
;;; dg-argument-gaps: Structural completeness lint
;;; ============================================================

(defun org-dblock-write:dg-argument-gaps (params)
  "Check argument chains for structural completeness."
  (let* ((limit (or (plist-get params :limit) 30))
         (claims (dg-find-by-type 'claim))
         (with-gaps
          (seq-filter
           (lambda (c)
             (> (length (dg--get-argument-gaps (plist-get c :id))) 0))
           claims))
         (sorted (seq-sort-by
                  (lambda (c)
                    (length (dg--get-argument-gaps (plist-get c :id))))
                  #'> with-gaps))
         (limited (seq-take sorted limit)))
    (insert (format "/Updated: %s/\n\n" (format-time-string "%Y-%m-%d %H:%M")))
    (if (null limited)
        (insert "/All claims have complete argument structure./\n")
      (insert "| Claim | Structural Gaps |\n")
      (insert "|---+---|\n")
      (dolist (c limited)
        (let* ((id (plist-get c :id))
               (title (plist-get c :title))
               (gaps (dg--get-argument-gaps id)))
          (insert (format "| [[dg:%s][%s]] | %s |\n"
                          id
                          (truncate-string-to-width title 40 nil nil "…")
                          (mapconcat #'symbol-name gaps ", ")))))
      ;; Align table
      (save-excursion
        (forward-line -1)
        (when (org-at-table-p)
          (org-table-align))))))

;;; ============================================================
;;; dg-overview: Research health overview
;;; ============================================================

(defun org-dblock-write:dg-overview (_params)
  "Overview focusing on argumentation health."
  (let* ((questions (dg-find-by-type 'question))
         (claims (dg-find-by-type 'claim))
         (evidence (dg-find-by-type 'evidence))
         (sources (dg-find-by-type 'source))
         ;; Structural analysis
         (claims-with-gaps (length (seq-filter
                                    (lambda (c)
                                      (> (length (dg--get-argument-gaps (plist-get c :id))) 0))
                                    claims)))
         (claims-unanswered (length (seq-filter
                                     (lambda (c)
                                       (member 'unanswered-opposition
                                               (dg--get-argument-gaps (plist-get c :id))))
                                     claims)))
         (questions-open (length (seq-filter
                                  (lambda (q)
                                    (= (length (dg-find-answers (plist-get q :id))) 0))
                                  questions))))
    (insert (format "/Updated: %s/\n\n" (format-time-string "%Y-%m-%d %H:%M")))
    (insert "| Category | Total | Issues |\n")
    (insert "|---+---+---|\n")
    (insert (format "| Questions | %d | %d open |\n"
                    (length questions) questions-open))
    (insert (format "| Claims | %d | %d with gaps |\n"
                    (length claims) claims-with-gaps))
    (insert (format "| └ Unanswered objections | — | %d |\n" claims-unanswered))
    (insert (format "| Evidence | %d | |\n" (length evidence)))
    (insert (format "| Sources | %d | |\n" (length sources)))
    ;; Align table
    (save-excursion
      (forward-line -1)
      (when (org-at-table-p)
        (org-table-align)))))

;;; ============================================================
;;; Synthesis Dashboard
;;; ============================================================

(defun dg--synthesis-file-path ()
  "Get synthesis file path."
  (or dg-synthesis-file
      (expand-file-name "dg-synthesis.org" (car dg-directories))))

(defun dg-synthesis-open ()
  "Open the synthesis dashboard."
  (interactive)
  (let ((path (dg--synthesis-file-path)))
    (if (file-exists-p path)
        (progn
          (find-file path)
          (when (y-or-n-p "Update? ")
            (org-update-all-dblocks)
            (save-buffer)))
      (dg--synthesis-create path)
      (find-file path)
      (org-update-all-dblocks)
      (save-buffer))))

(defun dg--synthesis-create (path)
  "Create new synthesis dashboard at PATH."
  (let ((dir (file-name-directory path)))
    (unless (file-exists-p dir)
      (make-directory dir t)))
  (with-temp-file path
    (insert "#+TITLE: Argumentation Analysis\n")
    (insert "#+STARTUP: showall\n\n")
    (insert "* Overview\n")
    (insert "#+BEGIN: dg-overview\n#+END:\n\n")
    (insert "* Unanswered Objections\n")
    (insert "/Claims where objections have not been adequately addressed/\n\n")
    (insert "#+BEGIN: dg-unanswered-opposition\n#+END:\n\n")
    (insert "* Structural Gaps\n")
    (insert "/Claims with incomplete argument chains/\n\n")
    (insert "#+BEGIN: dg-argument-gaps\n#+END:\n\n")))

;;; ============================================================
;;; Interactive Commands
;;; ============================================================

(defun dg-analyze-question (question-ref)
  "Create/open synthesis analysis for a question."
  (interactive
   (list (let ((id (dg--get-id-at-point)))
           (if (and id (string= (plist-get (dg-get id) :type) "question"))
               id
             (read-string "Question (ID or title): ")))))
  (let* ((question-id (dg--resolve-node-ref question-ref))
         (question (and question-id (dg-get question-id))))
    (unless question
      (user-error "Question not found: %s" question-ref))
    (let* ((title (plist-get question :title))
           (safe-name (replace-regexp-in-string "[^a-zA-Z0-9]+" "-" title))
           (file-name (format "dg-q-%s.org"
                              (substring safe-name 0 (min 20 (length safe-name)))))
           (file-path (expand-file-name file-name (car dg-directories))))
      (if (file-exists-p file-path)
          (progn
            (find-file file-path)
            (org-update-all-dblocks)
            (save-buffer))
        (with-temp-file file-path
          (insert (format "#+TITLE: Q: %s\n\n" title))
          (insert (format "#+BEGIN: dg-synthesis :id \"%s\"\n" question-id))
          (insert "#+END:\n"))
        (find-file file-path)
        (org-update-all-dblocks)
        (save-buffer)))))

;;; ============================================================
;;; Helper Functions
;;; ============================================================

(defun dg--resolve-node-ref (ref)
  "Resolve REF to a node ID."
  (cond
   ((null ref) nil)
   ((dg-get ref) ref)
   (t (plist-get (car (dg-find-by-title ref)) :id))))

(provide 'discourse-graph)
;;; discourse-graph.el ends here
