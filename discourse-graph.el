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
;; - Export to Graphviz DOT and Markdown
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
;;   - informs: Provides background or context
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

(defcustom dg-context-window-width 45
  "Width of the discourse context side window."
  :type 'integer
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

(defcustom dg-queries-file
  (expand-file-name "dg-saved-queries.el" user-emacs-directory)
  "File to save discourse graph queries."
  :type 'file
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

(defvar dg--index-buffer-name "*DG Index*"
  "Name of the node index buffer.")

(defvar dg--query-buffer-name "*DG Query*"
  "Name of the query results buffer.")

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
  ;; Indexes for performance
  (sqlite-execute (dg--db) "CREATE INDEX IF NOT EXISTS idx_nodes_type ON nodes(type)")
  (sqlite-execute (dg--db) "CREATE INDEX IF NOT EXISTS idx_nodes_file ON nodes(file)")
  (sqlite-execute (dg--db) "CREATE INDEX IF NOT EXISTS idx_rel_source ON relations(source_id)")
  (sqlite-execute (dg--db) "CREATE INDEX IF NOT EXISTS idx_rel_target ON relations(target_id)")
  (sqlite-execute (dg--db) "CREATE INDEX IF NOT EXISTS idx_rel_type ON relations(rel_type)"))

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
  "Parse all DG relation properties at current heading."
  (let ((relations '()))
    (dolist (rel-type dg-relation-types)
      (let* ((prop (concat "DG_" (upcase (symbol-name (car rel-type)))))
             (value (org-entry-get nil prop)))
        (when value
          ;; Support multiple targets separated by space or comma
          (dolist (target (split-string value "[ \t,]+" t))
            (push (cons (car rel-type) target) relations)))))
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
                                          :target (cdr rel)
                                          :type (car rel))
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
  "Save REL to database."
  (sqlite-execute
   (dg--db)
   "INSERT OR IGNORE INTO relations (source_id, target_id, rel_type)
    VALUES (?, ?, ?)"
   (list (plist-get rel :source)
         (plist-get rel :target)
         (symbol-name (plist-get rel :type)))))

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
Returns plist with :outgoing and :incoming lists."
  (let ((outgoing (sqlite-select
                   (dg--db)
                   "SELECT 'out', rel_type, target_id, n.title, n.type
                    FROM relations r
                    LEFT JOIN nodes n ON r.target_id = n.id
                    WHERE r.source_id = ?"
                   (list id)))
        (incoming (sqlite-select
                   (dg--db)
                   "SELECT 'in', rel_type, source_id, n.title, n.type
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
;;; Discourse Attributes (Computed Properties)
;;; ============================================================

(defun dg-attr-support-count (id)
  "Count nodes that support ID."
  (or (caar (sqlite-select
             (dg--db)
             "SELECT COUNT(*) FROM relations
              WHERE target_id = ? AND rel_type = 'supports'"
             (list id)))
      0))

(defun dg-attr-oppose-count (id)
  "Count nodes that oppose ID."
  (or (caar (sqlite-select
             (dg--db)
             "SELECT COUNT(*) FROM relations
              WHERE target_id = ? AND rel_type = 'opposes'"
             (list id)))
      0))

(defun dg-attr-evidence-score (id)
  "Calculate evidence score: supports - opposes."
  (- (dg-attr-support-count id)
     (dg-attr-oppose-count id)))

(defun dg-attr-answer-count (id)
  "Count answers to question ID."
  (or (caar (sqlite-select
             (dg--db)
             "SELECT COUNT(*) FROM relations
              WHERE target_id = ? AND rel_type = 'answers'"
             (list id)))
      0))

(defun dg-get-all-attributes (id)
  "Get all computed attributes for ID."
  (list :support-count (dg-attr-support-count id)
        :oppose-count (dg-attr-oppose-count id)
        :evidence-score (dg-attr-evidence-score id)
        :answer-count (dg-attr-answer-count id)))

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

(defun dg-get-source (id)
  "Get the source node ID for node ID (from DG_SOURCE property).
Returns source node ID or nil."
  (let ((node (dg-get id)))
    (when node
      (let ((file (plist-get node :file))
            (pos (plist-get node :pos)))
        (condition-case nil
            (let ((existing-buffer (get-file-buffer file)))
              (with-current-buffer (or existing-buffer
                                       (let ((inhibit-message t))
                                         (find-file-noselect file t)))
                (save-excursion
                  (save-restriction
                    (widen)
                    (goto-char (or pos (point-min)))
                    (or (org-entry-get nil "DG_SOURCE")
                        ;; Check file-level keyword
                        (save-excursion
                          (goto-char (point-min))
                          (when (re-search-forward "^#\\+dg_source:[ \t]*\\(.+\\)" nil t)
                            (string-trim (match-string 1)))))))))
          (error nil))))))

;;; ============================================================
;;; Statistics
;;; ============================================================

(defun dg-stats ()
  "Display discourse graph statistics."
  (interactive)
  (let ((node-count (caar (sqlite-select (dg--db) "SELECT COUNT(*) FROM nodes")))
        (rel-count (caar (sqlite-select (dg--db) "SELECT COUNT(*) FROM relations")))
        (type-stats (sqlite-select (dg--db)
                                   "SELECT type, COUNT(*) FROM nodes GROUP BY type ORDER BY type"))
        (rel-stats (sqlite-select (dg--db)
                                  "SELECT rel_type, COUNT(*) FROM relations GROUP BY rel_type ORDER BY rel_type"))
        (file-count (caar (sqlite-select (dg--db)
                                         "SELECT COUNT(DISTINCT file) FROM nodes"))))
    (with-current-buffer (get-buffer-create "*DG Stats*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Discourse Graph Statistics\n"
                            'face '(:weight bold :height 1.3)))
        (insert (make-string 40 ?═) "\n\n")
        (insert (format "Total nodes:     %d\n" node-count))
        (insert (format "Total relations: %d\n" rel-count))
        (insert (format "Files indexed:   %d\n\n" file-count))
        (insert (propertize "Nodes by Type\n" 'face '(:weight bold)))
        (insert (make-string 20 ?─) "\n")
        (dolist (row type-stats)
          (let* ((type (intern (car row)))
                 (count (cadr row))
                 (info (alist-get type dg-node-types)))
            (insert (format "  %s %-10s %4d\n"
                            (plist-get info :short)
                            (car row)
                            count))))
        (insert (format "\n"))
        (insert (propertize "Relations by Type\n" 'face '(:weight bold)))
        (insert (make-string 20 ?─) "\n")
        (dolist (row rel-stats)
          (insert (format "  %-12s %4d\n" (car row) (cadr row))))
        (goto-char (point-min)))
      (special-mode)
      (pop-to-buffer (current-buffer)))))

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
         (node-type (plist-get node :type))
         (type-sym (intern (or node-type "")))
         (type-info (alist-get type-sym dg-node-types))
         (short (or (plist-get type-info :short) "?"))
         (supp (plist-get attrs :support-count))
         (opp (plist-get attrs :oppose-count))
         (source-id (dg-get-source id)))
    (with-current-buffer (get-buffer-create dg--context-buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)

        ;; Back link if history exists
        (when dg--nav-history
          (let* ((prev-id (car dg--nav-history))
                 (prev-node (dg-get prev-id))
                 (prev-title (or (plist-get prev-node :title) prev-id)))
            (insert (format "[[dg:%s][← Back: %s]]\n\n"
                            prev-id
                            (truncate-string-to-width prev-title 28 nil nil "…")))))

        ;; Header with stats inline (like overlay)
        (insert (format "#+title: [%s] %s"
                        short
                        (or (plist-get node :title) "Unknown")))
        (when (or (> supp 0) (> opp 0))
          (insert (format " [+%d/-%d]" supp opp)))
        (insert "\n")
        (insert (format "#+property: id %s\n" id))

        ;; Source (for evidence nodes)
        (when source-id
          (let ((source-node (dg-get source-id)))
            (if source-node
                (insert (format "#+property: source [[dg:%s][%s]]\n"
                                source-id
                                (plist-get source-node :title)))
              (insert (format "#+property: source %s\n" source-id)))))

        ;; Outgoing relations
        (when outgoing
          (let ((grouped (seq-group-by (lambda (r) (nth 1 r)) outgoing)))
            (dolist (group grouped)
              (let* ((rel-type (intern (car group)))
                     (display-name (capitalize (symbol-name rel-type))))
                (insert (format "\n* → %s\n" display-name))
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
                (insert (format "\n* ← %s\n" inverse-name))
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
  "Insert a node entry for REL in DIRECTION (outgoing or incoming)."
  (let* ((target-id (nth 2 rel))
         (target-title (or (nth 3 rel) "?"))
         (target-type (nth 4 rel))
         (type-sym (and target-type (intern target-type)))
         (type-info (and type-sym (alist-get type-sym dg-node-types)))
         (type-short (or (plist-get type-info :short) "?"))
         (summary (dg-get-summary target-id)))
    ;; Level 2 heading: title + type tag (no link in heading)
    (insert (format "** %s :%s:\n" target-title type-short))
    ;; Link on separate line (hidden when folded)
    (insert (format "[[dg:%s]]\n" target-id))
    ;; Summary as body
    (when summary
      (insert summary)
      (insert "\n"))))

(defun dg-context-toggle ()
  "Toggle discourse context side window."
  (interactive)
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
;;; Node Index
;;; ============================================================

(defun dg-node-index (&optional type sort-by)
  "Display index of nodes, optionally filtered by TYPE and sorted by SORT-BY."
  (interactive
   (list (when current-prefix-arg
           (intern (completing-read "Type (empty for all): "
                                    (cons "" (mapcar #'car dg-node-types))
                                    nil nil)))
         (intern (completing-read "Sort by: "
                                  '("title" "evidence-score" "support-count" "type")
                                  nil nil "title"))))
  (let* ((nodes (if (and type (not (string-empty-p (symbol-name type))))
                    (dg-find-by-type type)
                  (dg-all-nodes)))
         ;; Add attributes
         (nodes-with-attrs
          (mapcar (lambda (n)
                    (let ((id (plist-get n :id)))
                      (append n (list :attrs (dg-get-all-attributes id)))))
                  nodes))
         ;; Sort
         (sorted
          (pcase sort-by
            ('title
             (seq-sort-by (lambda (n) (downcase (plist-get n :title))) #'string< nodes-with-attrs))
            ('evidence-score
             (seq-sort-by (lambda (n) (plist-get (plist-get n :attrs) :evidence-score))
                          #'> nodes-with-attrs))
            ('support-count
             (seq-sort-by (lambda (n) (plist-get (plist-get n :attrs) :support-count))
                          #'> nodes-with-attrs))
            ('type
             (seq-sort-by (lambda (n) (or (plist-get n :type) "")) #'string< nodes-with-attrs))
            (_ nodes-with-attrs))))
    (with-current-buffer (get-buffer-create dg--index-buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize (format "Node Index%s (%d nodes)\n"
                                    (if type (format " [%s]" type) "")
                                    (length sorted))
                            'face '(:weight bold :height 1.2)))
        (insert (make-string 70 ?═) "\n")
        ;; Table header
        (insert (propertize
                 (format "%-3s %-45s %5s %5s %5s\n"
                         "T" "Title" "Supp" "Opp" "Score")
                 'face '(:weight bold)))
        (insert (make-string 70 ?─) "\n")
        ;; Rows
        (dolist (node sorted)
          (let* ((id (plist-get node :id))
                 (ntype-str (plist-get node :type))
                 (ntype-sym (and ntype-str (intern ntype-str)))
                 (type-info (and ntype-sym (alist-get ntype-sym dg-node-types)))
                 (short (or (plist-get type-info :short) "?"))
                 (title (truncate-string-to-width
                         (plist-get node :title) 43 nil nil "…"))
                 (attrs (plist-get node :attrs))
                 (supp (plist-get attrs :support-count))
                 (opp (plist-get attrs :oppose-count))
                 (score (plist-get attrs :evidence-score)))
            (insert (propertize (format "%-3s " short) 'face 'font-lock-type-face))
            (insert-text-button
             (format "%-45s" title)
             'action (lambda (_) (dg-goto-node-by-id id))
             'node-id id
             'face 'link)
            (insert (format " %5d %5d %+5d\n" supp opp score))))
        (goto-char (point-min)))
      (dg-index-mode)
      (pop-to-buffer (current-buffer)))))

(define-derived-mode dg-index-mode special-mode "DG-Index"
  "Major mode for discourse graph node index."
  (setq-local truncate-lines t))

;;; ============================================================
;;; Query Builder
;;; ============================================================

(defun dg-query-relations ()
  "Query relations of current node or selected node.
More intuitive: select a node, pick relation type, see results."
  (interactive)
  (let* ((current-id (dg--get-id-at-point))
         (use-current (and current-id
                           (y-or-n-p (format "Query from current node? "))))
         (node-id (if use-current
                      current-id
                    (let* ((all-nodes (dg-all-nodes))
                           (choice (completing-read
                                    "Select node: "
                                    (mapcar (lambda (n)
                                              (let* ((type-str (plist-get n :type))
                                                     (type-sym (and type-str (intern type-str)))
                                                     (type-info (and type-sym (alist-get type-sym dg-node-types)))
                                                     (short (or (plist-get type-info :short) "?")))
                                                (cons (format "[%s] %s" short (plist-get n :title))
                                                      (plist-get n :id))))
                                            all-nodes)
                                    nil t)))
                      (cdr (assoc choice
                                  (mapcar (lambda (n)
                                            (let* ((type-str (plist-get n :type))
                                                   (type-sym (and type-str (intern type-str)))
                                                   (type-info (and type-sym (alist-get type-sym dg-node-types)))
                                                   (short (or (plist-get type-info :short) "?")))
                                              (cons (format "[%s] %s" short (plist-get n :title))
                                                    (plist-get n :id))))
                                          all-nodes))))))
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
          (insert (format "* → Outgoing (%d)\n" (length outgoing)))
          (dolist (n outgoing)
            (let* ((id (plist-get n :id))
                   (title (plist-get n :title))
                   (type-str (plist-get n :type))
                   (type-sym (and type-str (intern type-str)))
                   (type-info (and type-sym (alist-get type-sym dg-node-types)))
                   (type-short (or (plist-get type-info :short) "?")))
              (insert (format "** %s :%s:\n[[dg:%s]]\n" title type-short id)))))

        (when incoming
          (insert (format "* ← Incoming (%d)\n" (length incoming)))
          (dolist (n incoming)
            (let* ((id (plist-get n :id))
                   (title (plist-get n :title))
                   (type-str (plist-get n :type))
                   (type-sym (and type-str (intern type-str)))
                   (type-info (and type-sym (alist-get type-sym dg-node-types)))
                   (type-short (or (plist-get type-info :short) "?")))
              (insert (format "** %s :%s:\n[[dg:%s]]\n" title type-short id)))))

        (when (and (null outgoing) (null incoming))
          (insert "No relations found.\n"))

        (goto-char (point-min))
        (org-content 1)
        (read-only-mode 1)))
    (pop-to-buffer buf)))

(defun dg-query-builder ()
  "Interactive query builder for discourse graph.
Find all nodes of a type, optionally filtered by relations."
  (interactive)
  (let* ((source-type (intern (completing-read
                               "Find nodes of type: "
                               (mapcar #'car dg-node-types))))
         (add-rel (y-or-n-p "Add relation filter? "))
         (rel-type (when add-rel
                     (intern (completing-read
                              "With relation: "
                              (mapcar #'car dg-relation-types)))))
         (rel-dir (when add-rel
                    (intern (completing-read
                             "Direction: "
                             '("outgoing" "incoming")))))
         (target-type (when add-rel
                        (let ((sel (completing-read
                                    "To/from type: "
                                    (cons "any" (mapcar (lambda (x) (symbol-name (car x)))
                                                        dg-node-types)))))
                          (unless (string= sel "any")
                            (intern sel)))))
         (results (dg--execute-query source-type rel-type rel-dir target-type)))
    (dg--display-query-results results
                               (format "%s %s %s %s"
                                       source-type
                                       (or rel-type "")
                                       (or rel-dir "")
                                       (or target-type "any")))))

(defun dg--execute-query (source-type &optional rel-type rel-dir target-type)
  "Execute query with given parameters."
  (let ((sql "SELECT DISTINCT n.id, n.type, n.title, n.file, n.pos, n.outline_path
              FROM nodes n")
        (conditions (list (format "n.type = '%s'" source-type)))
        (joins ""))
    (when rel-type
      (pcase rel-dir
        ('outgoing
         (setq joins " JOIN relations r ON n.id = r.source_id")
         (push (format "r.rel_type = '%s'" rel-type) conditions)
         (when target-type
           (setq joins (concat joins " JOIN nodes n2 ON r.target_id = n2.id"))
           (push (format "n2.type = '%s'" target-type) conditions)))
        ('incoming
         (setq joins " JOIN relations r ON n.id = r.target_id")
         (push (format "r.rel_type = '%s'" rel-type) conditions)
         (when target-type
           (setq joins (concat joins " JOIN nodes n2 ON r.source_id = n2.id"))
           (push (format "n2.type = '%s'" target-type) conditions)))))
    (let ((full-sql (format "%s%s WHERE %s ORDER BY n.title"
                            sql joins
                            (string-join conditions " AND "))))
      (mapcar #'dg--row-to-plist
              (sqlite-select (dg--db) full-sql)))))

(defun dg--display-query-results (results query-desc)
  "Display RESULTS in query buffer with QUERY-DESC description."
  (let ((buf (get-buffer-create dg--query-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "#+title: Query Results\n"))
        (insert (format "#+property: query %s\n" query-desc))
        (insert (format "#+property: count %d\n\n" (length results)))
        (if (null results)
            (insert "No results found.\n")
          (dolist (node results)
            (let* ((id (plist-get node :id))
                   (type-str (plist-get node :type))
                   (type-sym (and type-str (intern type-str)))
                   (type-info (and type-sym (alist-get type-sym dg-node-types)))
                   (short (or (plist-get type-info :short) "?")))
              (insert (format "** %s :%s:\n[[dg:%s]]\n" (plist-get node :title) short id)))))
        (goto-char (point-min))
        (org-mode)
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

(defun dg-set-source (source-id)
  "Set DG_SOURCE property to SOURCE-ID for current node.
Typically used for Evidence nodes to reference their Source."
  (interactive
   (list (dg--completing-read-node "Source: " 'source)))
  (unless (dg--get-id-at-point)
    (user-error "No discourse graph node at point"))
  (when source-id
    (org-set-property "DG_SOURCE" source-id)
    (let ((source-node (dg-get source-id)))
      (message "Set source: %s (save to update)"
               (or (plist-get source-node :title) source-id)))))

;;; ============================================================
;;; Relation Management
;;; ============================================================

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
                        (cons (format "%s → %s (%s)"
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
          (message "Removed: %s → %s (save to update context)" rel-type target-id))))))

(defun dg-remove-source ()
  "Remove DG_SOURCE property from current node."
  (interactive)
  (unless (dg--get-id-at-point)
    (user-error "No discourse graph node at point"))
  (if (org-entry-get nil "DG_SOURCE")
      (progn
        (org-delete-property "DG_SOURCE")
        (message "Removed source (save to update context)"))
    (message "No source to remove")))

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
;;; Export: Graphviz DOT
;;; ============================================================

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

(defun dg-export-dot (&optional file)
  "Export discourse graph to Graphviz DOT format.
If FILE is nil, prompt for output path."
  (interactive "FExport to DOT file: ")
  (let ((nodes (sqlite-select (dg--db) "SELECT id, type, title FROM nodes"))
        (relations (sqlite-select (dg--db) "SELECT source_id, target_id, rel_type FROM relations")))
    (with-temp-file file
      (insert "digraph DiscourseGraph {\n")
      (insert "  rankdir=LR;\n")
      (insert "  node [shape=box, style=filled, fontname=\"Helvetica\"];\n")
      (insert "  edge [fontname=\"Helvetica\", fontsize=10];\n\n")
      ;; Nodes with colors by type
      (insert "  // Nodes\n")
      (dolist (node nodes)
        (let* ((id (nth 0 node))
               (ntype (intern (nth 1 node)))
               (title (nth 2 node))
               (type-info (alist-get ntype dg-node-types))
               (color (or (plist-get type-info :color) "white"))
               (safe-title (replace-regexp-in-string "\"" "\\\\\""
                           (truncate-string-to-width title 40 nil nil "..."))))
          (insert (format "  \"%s\" [label=\"%s\", fillcolor=\"%s\"];\n"
                          id safe-title color))))
      (insert "\n  // Relations\n")
      ;; Relations with colors and styles
      (dolist (rel relations)
        (let* ((rel-type (intern (nth 2 rel)))
               (rel-info (alist-get rel-type dg-relation-types))
               (color (or (plist-get rel-info :color) "black"))
               (style (or (plist-get rel-info :style) "solid")))
          (insert (format "  \"%s\" -> \"%s\" [label=\"%s\", color=\"%s\", style=\"%s\"];\n"
                          (nth 0 rel) (nth 1 rel) (nth 2 rel) color style))))
      (insert "}\n"))
    (message "Exported to %s" file)))

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
          (insert (format "- **Support Score**: %+d (↑%d ↓%d)\n"
                          (plist-get attrs :evidence-score)
                          (plist-get attrs :support-count)
                          (plist-get attrs :oppose-count)))
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

(defun dg--make-overlay-string (id)
  "Create overlay string for node ID."
  (let ((supp (dg-attr-support-count id))
        (opp (dg-attr-oppose-count id)))
    (when (or (> supp 0) (> opp 0))
      (concat " "
              (propertize (format "[+%d -%d]" supp opp)
                          'face 'dg-overlay-face)))))

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

(defun dg--link-id-at-point ()
  "Get the target ID of org link at point, if any."
  (let ((context (org-element-context)))
    (when (eq (org-element-type context) 'link)
      (let ((link-type (org-element-property :type context))
            (path (org-element-property :path context)))
        (cond
         ((string= link-type "id") path)
         ((string= link-type "dg") path)
         ((string= link-type "denote")
          (when (string-match "^\\([0-9T]+\\)" path)
            (match-string 1 path)))
         (t nil))))))

(defun dg-link (rel-type)
  "Add relation from current node.
If cursor is on a link, use that as target; otherwise prompt.
REL-TYPE is the relation type symbol."
  (interactive
   (list (intern (completing-read
                  "Relation: "
                  (mapcar #'car dg-relation-types)
                  nil t))))
  (let ((source-id (dg--get-id-at-point)))
    (unless source-id
      (user-error "Not on a discourse node"))
    (let* ((link-target (dg--link-id-at-point))
           (target-id (or link-target
                          (dg--completing-read-node "Target: "))))
      (when target-id
        (let* ((prop (concat "DG_" (upcase (symbol-name rel-type))))
               (existing (org-entry-get nil prop)))
          (org-set-property prop
                            (if existing
                                (concat existing " " target-id)
                              target-id))
          (let ((target-node (dg-get target-id)))
            (message "%s → %s (save to update)"
                     rel-type
                     (or (plist-get target-node :title) target-id))))))))

;;; ============================================================
;;; Save/Load Queries
;;; ============================================================

(defvar dg--saved-queries nil
  "Alist of saved queries. Each entry: (NAME . QUERY-PLIST).")

(defun dg-save-query (name query)
  "Save QUERY with NAME to saved queries."
  (setf (alist-get name dg--saved-queries nil nil #'equal) query)
  (dg--persist-queries))

(defun dg--persist-queries ()
  "Save queries to file."
  (with-temp-file dg-queries-file
    (insert ";;; Discourse Graph Saved Queries -*- lexical-binding: t -*-\n")
    (insert ";; Auto-generated, do not edit manually\n\n")
    (prin1 `(setq dg--saved-queries ',dg--saved-queries) (current-buffer))
    (insert "\n")))

(defun dg--load-queries ()
  "Load queries from file."
  (when (file-exists-p dg-queries-file)
    (load dg-queries-file t t)))

(defun dg-query-save ()
  "Save current query interactively."
  (interactive)
  (let* ((name (read-string "Query name: "))
         (node-type (intern (completing-read
                             "Node type (or 'all'): "
                             (cons "all" (mapcar #'car dg-node-types)))))
         (rel-filter (y-or-n-p "Add relation filter? "))
         (query (list :node-type node-type)))
    (when rel-filter
      (let* ((direction (intern (completing-read "Direction: " '("outgoing" "incoming"))))
             (rel-type (intern (completing-read "Relation type: "
                                                (mapcar #'car dg-relation-types))))
             (target-type (intern (completing-read
                                   "Target type (or 'any'): "
                                   (cons "any" (mapcar #'car dg-node-types))))))
        (setq query (plist-put query :rel-direction direction))
        (setq query (plist-put query :rel-type rel-type))
        (setq query (plist-put query :target-type target-type))))
    (dg-save-query name query)
    (message "Saved query: %s" name)))

(defun dg-query-load ()
  "Load and run a saved query."
  (interactive)
  (dg--load-queries)
  (if (not dg--saved-queries)
      (message "No saved queries")
    (let* ((name (completing-read "Load query: "
                                  (mapcar #'car dg--saved-queries)
                                  nil t))
           (query (alist-get name dg--saved-queries nil nil #'equal)))
      (dg--run-saved-query name query))))

(defun dg--run-saved-query (name query)
  "Run saved QUERY with NAME and display results."
  (let* ((node-type (plist-get query :node-type))
         (rel-direction (plist-get query :rel-direction))
         (rel-type (plist-get query :rel-type))
         (target-type (plist-get query :target-type))
         (nodes (if (eq node-type 'all)
                    (dg-get-all)
                  (dg-find-by-type (symbol-name node-type))))
         (results nodes))
    ;; Apply relation filter if present
    (when rel-direction
      (setq results
            (seq-filter
             (lambda (node)
               (let* ((id (plist-get node :id))
                      (rels (if (eq rel-direction 'outgoing)
                                (dg-find-outgoing id)
                              (dg-find-incoming id)))
                      (filtered (seq-filter
                                 (lambda (r)
                                   (and (string= (nth 1 r) (symbol-name rel-type))
                                        (or (eq target-type 'any)
                                            (let ((target (dg-get (nth 2 r))))
                                              (and target
                                                   (string= (plist-get target :type)
                                                            (symbol-name target-type)))))))
                                 rels)))
                 (> (length filtered) 0)))
             results)))
    ;; Display results
    (dg--display-saved-query-results name results)))

(defun dg--display-saved-query-results (name results)
  "Display saved query RESULTS with NAME in a buffer."
  (let ((buf (get-buffer-create "*DG Query Results*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (org-mode)
        (insert (format "#+title: Query: %s\n" name))
        (insert (format "#+property: results %d\n\n" (length results)))
        (if (null results)
            (insert "No results found.\n")
          (dolist (node results)
            (let* ((id (plist-get node :id))
                   (title (plist-get node :title))
                   (type-str (plist-get node :type))
                   (type-sym (and type-str (intern type-str)))
                   (type-info (and type-sym (alist-get type-sym dg-node-types)))
                   (type-short (or (plist-get type-info :short) "?")))
              (insert (format "** %s :%s:\n[[dg:%s]]\n" title type-short id)))))
        (goto-char (point-min))
        (read-only-mode 1)))
    (pop-to-buffer buf)))

(defun dg-query-delete ()
  "Delete a saved query."
  (interactive)
  (dg--load-queries)
  (if (not dg--saved-queries)
      (message "No saved queries")
    (let ((name (completing-read "Delete query: "
                                 (mapcar #'car dg--saved-queries)
                                 nil t)))
      (setq dg--saved-queries (assoc-delete-all name dg--saved-queries))
      (dg--persist-queries)
      (message "Deleted query: %s" name))))

;;; ============================================================
;;; Graph Preview (using Graphviz)
;;; ============================================================

(defcustom dg-graphviz-command "dot"
  "Graphviz command for rendering graphs."
  :type 'string
  :group 'discourse-graph)

(defun dg-graph-preview ()
  "Generate and preview graph of current node's neighborhood."
  (interactive)
  (let ((id (dg--get-id-at-point)))
    (if (not id)
        (user-error "No discourse node at point")
      (dg--preview-neighborhood id 2))))

(defun dg--preview-neighborhood (center-id depth)
  "Preview graph neighborhood around CENTER-ID up to DEPTH levels."
  (let* ((nodes-seen (make-hash-table :test 'equal))
         (edges nil)
         (dot-file (make-temp-file "dg-preview" nil ".dot"))
         (png-file (concat (file-name-sans-extension dot-file) ".png")))
    ;; Collect nodes and edges using BFS
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
    ;; Generate DOT
    (with-temp-file dot-file
      (insert "digraph discourse_graph {\n")
      (insert "  rankdir=LR;\n")
      (insert "  node [shape=box, style=rounded];\n")
      ;; Nodes
      (maphash
       (lambda (id _)
         (let* ((node (dg-get id))
                (title (or (plist-get node :title) id))
                (type-str (plist-get node :type))
                (type-sym (and type-str (intern type-str)))
                (type-info (and type-sym (alist-get type-sym dg-node-types)))
                (color (or (and type-info (plist-get type-info :color)) "white"))
                (is-center (string= id center-id)))
           (insert (format "  \"%s\" [label=\"%s\", fillcolor=\"%s\", style=\"%s\"];\n"
                           id
                           (dg--dot-escape (truncate-string-to-width title 25 nil nil "…"))
                           color
                           (if is-center "filled,bold,rounded" "filled,rounded")))))
       nodes-seen)
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
      (insert "}\n"))
    ;; Render
    (if (executable-find dg-graphviz-command)
        (progn
          (call-process dg-graphviz-command nil nil nil
                        "-Tpng" dot-file "-o" png-file)
          (if (file-exists-p png-file)
              (progn
                (find-file png-file)
                (message "Graph preview generated"))
            (find-file dot-file)
            (message "PNG generation failed, showing DOT file")))
      (find-file dot-file)
      (message "Graphviz not found, showing DOT file"))))

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
        (nodes (dg-get-all))
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
            (push (format "Dangling source: %s in relation %s→%s" source rel-type target) issues))
          (unless (gethash target node-ids)
            (push (format "Dangling target: %s in relation %s→%s" target rel-type source) issues)))))
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

(defun dg-cleanup-dangling ()
  "Remove relations with dangling references."
  (interactive)
  (when (yes-or-no-p "Remove all relations pointing to non-existent nodes? ")
    (let ((node-ids (make-hash-table :test 'equal))
          (removed 0))
      ;; Build ID set
      (dolist (node (dg-get-all))
        (puthash (plist-get node :id) t node-ids))
      ;; Find and remove dangling
      (let ((rows (sqlite-select (dg--db)
                                 "SELECT rowid, source_id, target_id FROM relations")))
        (dolist (row rows)
          (let ((rowid (nth 0 row))
                (source (nth 1 row))
                (target (nth 2 row)))
            (unless (and (gethash source node-ids)
                         (gethash target node-ids))
              (sqlite-execute (dg--db)
                              "DELETE FROM relations WHERE rowid = ?"
                              (list rowid))
              (cl-incf removed)))))
      (message "Removed %d dangling relations" removed))))

;;; ============================================================
;;; Transient Menus
;;; ============================================================

(transient-define-prefix dg-menu ()
  "Discourse Graph main menu."
  ["Discourse Graph"
   ["Create"
    ("c" "Create node..." dg-create-node)
    ("q" "Question" dg-create-question)
    ("l" "Claim" dg-create-claim)
    ("e" "Evidence" dg-create-evidence)
    ("s" "Source" dg-create-source)]
   ["Relations"
    ("r" "Add relation" dg-link)
    ("S" "Set source" dg-set-source)
    ("D" "Remove relation" dg-remove-relation)]
   ["Navigate"
    ("g" "Go to node" dg-goto-node)
    ("x" "Toggle context" dg-context-toggle)
    ("p" "Graph preview" dg-graph-preview)]]
  [["View"
    ("i" "Node index" dg-node-index)
    ("t" "Statistics" dg-stats)
    ("o" "Toggle overlays" dg-overlay-toggle)]
   ["Query"
    ("?" "Query this node" dg-query-relations)
    ("/" "Query builder" dg-query-builder)
    ("L" "Load query" dg-query-load)]
   ["Export"
    ("E d" "DOT" dg-export-dot)
    ("E m" "Markdown" dg-export-markdown)]]
  [["Maintain"
    ("!" "Rebuild cache" dg-rebuild-cache)
    ("v" "Validate" dg-validate)
    ("X" "Cleanup" dg-cleanup-dangling)]
   ["Config"
    ("C" "Configure..." dg-configure)]])

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
        ;; Load saved queries
        (dg--load-queries)
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
    (when-let ((ctx-buf (get-buffer dg--context-buffer-name)))
      (when-let ((win (get-buffer-window ctx-buf)))
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

(provide 'discourse-graph)
;;; discourse-graph.el ends here
