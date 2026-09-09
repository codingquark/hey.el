;;; hey.el --- Read HEY mail without mailbox mutations  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 codingquark
;; SPDX-License-Identifier: MIT

;; Author: Dhavan Vaidya <456712+codingquark@users.noreply.github.com>
;; Assisted-by: Codex:gpt-5, gpt-6
;; Version: 0.2.0
;; Package-Requires: ((emacs "28.2") (markdown-mode "2.8"))
;; Keywords: mail, comm
;; URL: https://github.com/codingquark/hey.el

;;; Commentary:

;; Read HEY mail through the official CLI.  Browse sources, search, read
;; threads, and save attachments with `hey'.  Requests run asynchronously;
;; the package exposes no mailbox mutation commands.

;;; Code:

(require 'button)
(require 'cl-lib)
(require 'hl-line)
(require 'subr-x)
(require 'tabulated-list)
(require 'markdown-mode)
(require 'hey-model)
(require 'hey-cli)

(defface hey-thread-subject-face
  '((t :inherit bold))
  "Face for the subject value in a HEY thread preamble."
  :group 'hey)

(defface hey-metadata-label-face
  '((t :inherit shadow))
  "Face for field labels in a HEY thread preamble."
  :group 'hey)

(defface hey-status-face
  '((t :inherit shadow))
  "Face for non-fatal HEY state and orientation annotations."
  :group 'hey)

(defface hey-warning-face
  '((t :inherit warning))
  "Face for partial or malformed HEY results."
  :group 'hey)

(defface hey-error-face
  '((t :inherit error))
  "Face for HEY operation failures."
  :group 'hey)

;; Keep header elements independently customizable.  Earlier inherited faces
;; take priority over the `header-line' fallback.

(defface hey-header-account-face
  '((t :inherit header-line))
  "Face for the account element in a HEY header line."
  :group 'hey)

(defface hey-header-source-face
  '((t :inherit (mode-line-buffer-id header-line)))
  "Face for the source element in a HEY header line."
  :group 'hey)

(defface hey-header-subject-face
  '((t :inherit (hey-thread-subject-face header-line)))
  "Face for the subject element in a HEY thread header line."
  :group 'hey)

(defface hey-header-count-face
  '((t :inherit header-line))
  "Face for the row-count element in a HEY header line."
  :group 'hey)

(defface hey-header-updated-face
  '((t :inherit (shadow header-line)))
  "Face for the last-refresh element in a HEY header line."
  :group 'hey)

(defface hey-header-separator-face
  '((t :inherit (shadow header-line)))
  "Face for the separator between HEY header-line elements."
  :group 'hey)

(defface hey-header-status-face
  '((t :inherit (hey-status-face header-line)))
  "Face for ordinary HEY state text in a header line."
  :group 'hey)

(defface hey-header-warning-face
  '((t :inherit (hey-warning-face header-line)))
  "Face for partial-result HEY state text in a header line."
  :group 'hey)

(defface hey-header-error-face
  '((t :inherit (hey-error-face header-line)))
  "Face for failed HEY state text in a header line."
  :group 'hey)

(defcustom hey-account nil
  "Linked account ID used by `hey'.

Nil means use the account selected by the HEY CLI.  The string `all' selects
all linked accounts.  Account changes made inside a list buffer are local to
that session and never change this option or the CLI configuration."
  :type '(choice (const :tag "HEY CLI configured account" nil) string)
  :group 'hey)

(defcustom hey-initial-box "imbox"
  "HEY box command identifier opened by `hey'."
  :type 'string
  :group 'hey)

(defcustom hey-highlight-current-row t
  "Whether `hey-list-mode' highlights the current row.

The highlight is buffer-local and uses the theme-owned `hl-line' face."
  :type 'boolean
  :group 'hey)

(defcustom hey-list-subject-max-width 70
  "Maximum Subject column width in `hey-list-mode'."
  :type 'integer
  :group 'hey)

(defcustom hey-list-sender-max-width 24
  "Maximum Sender column width in `hey-list-mode'."
  :type 'integer
  :group 'hey)

(defvar hey-common-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "b") #'hey-browse-url)
    (define-key map (kbd "y") #'hey-copy-url)
    (define-key map (kbd "?") #'describe-mode)
    (define-key map (kbd "q") #'hey-quit)
    map)
  "Keymap shared by HEY list and thread buffers.")

(defvar hey-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map hey-common-map)
    (define-key map (kbd "RET") #'hey-open)
    (define-key map (kbd "o") #'hey-open-other-window)
    (define-key map (kbd "n") #'hey-next-row)
    (define-key map (kbd "p") #'hey-previous-row)
    (define-key map (kbd "g") #'hey-refresh)
    (define-key map (kbd "M") #'hey-load-more)
    (define-key map (kbd "B") #'hey-choose-box)
    (define-key map (kbd "/") #'hey-search)
    (define-key map (kbd "a") #'hey-choose-account)
    (define-key map (kbd "L") #'hey-choose-label)
    (define-key map (kbd "C") #'hey-choose-collection)
    map)
  "Keymap for `hey-list-mode'.")

(defvar hey-thread-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map hey-common-map)
    (define-key map (kbd "n") #'hey-next-entry)
    (define-key map (kbd "p") #'hey-previous-entry)
    (define-key map (kbd "SPC") #'scroll-up-command)
    (define-key map (kbd "DEL") #'scroll-down-command)
    (define-key map (kbd "RET") #'hey-follow-link)
    (define-key map (kbd "A") #'hey-list-attachments)
    ;; Keep Markdown table and folding commands unavailable.
    (define-key map (kbd "TAB") #'ignore)
    (define-key map (kbd "<backtab>") #'ignore)
    map)
  "Keymap for `hey-thread-mode': navigation and reading only.")

(defvar-local hey--account nil)
(defvar-local hey--configured-account nil)
(defvar-local hey--source nil)
(defvar-local hey--records nil)
(defvar-local hey--generation 0)
(defvar-local hey--request nil)
(defvar-local hey--loading nil)
(defvar-local hey--stale nil)
(defvar-local hey--last-refreshed nil)
(defvar-local hey--error nil)
(defvar-local hey--warnings nil)
(defvar-local hey--layout nil)
(defvar-local hey--columns nil)
(defvar-local hey--columns-key nil)
(defvar-local hey--thread nil)
(defvar-local hey--thread-key nil)
(defvar-local hey--origin nil)
(defvar-local hey--operation-overrides nil)

(defvar-local hey--attachments nil)
(defvar-local hey--attachment-thread nil)
(defvar-local hey--attachment-origin nil)
(defvar-local hey--attachment-notice nil)
(defvar-local hey--attachment-directory nil)
(defvar-local hey--attachment-save-request nil)
(defvar-local hey--attachment-save-token nil)
(defvar-local hey--attachment-save-status nil)

(defvar hey--main-buffer nil
  "Live primary HEY list buffer; `hey' reuses it across renamings.")

(defconst hey--list-layouts
  '((wide . ((subject "Subject" 30)
             (sender "Sender" 18)
             (memberships "Labels / collections" 20)
             (date "When" 12)))
    (medium . ((subject "Subject" 30)
               (sender "Sender" 18)
               (memberships "Labels / collections" 16)
               (date "When" 12)))
    (narrow . ((subject "Subject" 12)
               (sender "Sender" 14)
               (memberships "Labels / collections" 16)
               (date "When" 12)))
    (minimal . ((subject "Subject" 1)
                (date "When" 12))))
  "Column fields, titles, and preferred widths for each list layout.")

(defconst hey--list-right-gutter 2
  "Preferred empty columns to the right of the table.
Column minimums take priority when the window cannot fit the gutter.")

(defun hey--call (operation &rest arguments)
  "Call named CLI OPERATION with ARGUMENTS.

Buffer-local overrides exist for the demo and tests.  An override replaces
a named operation, never the private process primitive."
  (let ((override (alist-get operation hey--operation-overrides)))
    (apply (or override operation) arguments)))

(defun hey--cancel-request ()
  "Cancel the current request, if any, without surfacing cleanup errors."
  (when hey--request
    (ignore-errors (hey-cli-cancel-request hey--request))
    (setq hey--request nil)))

(defun hey--next-generation ()
  "Cancel existing work and return the next request generation."
  ;; Process deletion can deliver the old callback synchronously.
  (cl-incf hey--generation)
  (hey--cancel-request)
  hey--generation)

(defun hey--commit-p (buffer source-key generation)
  "Return non-nil when BUFFER still accepts SOURCE-KEY and GENERATION."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and (= generation hey--generation)
              (equal source-key
                     (and hey--source (hey-source-key hey--source)))))))

(defun hey--account-title ()
  "Return the current account's safe display title."
  (if (hey-account-p hey--account)
      (let ((name (hey-account-name hey--account)))
        (if (string-empty-p name) (hey-account-id hey--account) name))
    "Account"))

(defun hey--source-title ()
  "Return the current source's safe display title."
  (if (hey-source-p hey--source)
      (let ((title (hey-source-title hey--source)))
        (if (string-empty-p title)
            (capitalize (symbol-name (hey-source-kind hey--source)))
          title))
    "Mail"))

(defun hey--public-list-name ()
  "Return a non-private name for the current list buffer."
  (let* ((account (if (hey-account-p hey--account)
                      (hey-account-id hey--account)
                    "loading"))
         (source (if (and (hey-source-p hey--source)
                          (eq (hey-source-kind hey--source) 'search))
                     "Search"
                   (hey--source-title))))
    (format "*HEY: %s / %s*" account source)))

(defun hey--thread-buffer-name (account-id topic-id)
  "Return the public thread buffer name for ACCOUNT-ID and TOPIC-ID."
  (format "*HEY thread: %s/%s*" account-id topic-id))

(defun hey--bundle-buffer-name (account-id posting-id)
  "Return the public bundle buffer name for ACCOUNT-ID and POSTING-ID."
  (format "*HEY bundle: %s/%s*" account-id posting-id))

(defun hey--minimum-window-width ()
  "Return the minimum body width of windows showing the current buffer."
  (let ((windows (get-buffer-window-list (current-buffer) nil t)))
    (if windows
        (apply #'min (mapcar #'window-body-width windows))
      (window-body-width nil t))))

(defun hey--layout-for-width (width)
  "Return the fixed HEY layout appropriate for WIDTH."
  (cond ((>= width 120) 'wide)
        ((>= width 85) 'medium)
        ((>= width 58) 'narrow)
        (t 'minimal)))

(defun hey--memberships-present-p ()
  "Return non-nil when any cached posting has a membership."
  (cl-some (lambda (posting)
             (or (hey-posting-labels posting)
                 (hey-posting-collections posting)))
           hey--records))

(defun hey--columns-for-layout (layout)
  "Return the visible column specifications for LAYOUT.

The memberships column is omitted when it would be empty for every cached
posting, and at the narrow breakpoint where Subject takes priority."
  (let ((columns (alist-get layout hey--list-layouts)))
    (if (and (not (eq layout 'narrow))
             (hey--memberships-present-p))
        columns
      (cl-remove 'memberships columns :key #'car))))

(defun hey--column-format (layout columns width)
  "Return the table format for LAYOUT's COLUMNS at window WIDTH.
Subject and Sender grow up to their configured limits; When stays fixed.
Reserve `hey--list-right-gutter' while column minimums fit."
  (let* ((layout-columns (alist-get layout hey--list-layouts))
         (subject-base (nth 2 (assq 'subject layout-columns)))
         (sender-column (assq 'sender columns))
         (sender-base (and sender-column
                           (nth 2 (assq 'sender layout-columns))))
         (subject-limit (max 1 hey-list-subject-max-width))
         (sender-limit (and sender-column
                            (max 1 hey-list-sender-max-width)))
         (subject-floor (min subject-base subject-limit))
         (sender-floor (and sender-column
                            (min sender-base sender-limit)))
         (fixed-width
          (cl-loop for (field _title preferred) in columns
                   unless (memq field '(subject sender))
                   sum preferred))
         (inter-column-padding (max 0 (1- (length columns))))
         (available (- width tabulated-list-padding inter-column-padding
                       fixed-width hey--list-right-gutter))
         (subject-width
          (min subject-limit
               (max subject-floor (- available (or sender-floor 0)))))
         (sender-width
          (and sender-column
               (min sender-limit
                    (max sender-floor (- available subject-width))))))
    (vconcat
     (mapcar (lambda (column)
               (pcase-let ((`(,field ,title ,preferred) column))
                 (append
                  (list title (pcase field
                                ('subject subject-width)
                                ('sender sender-width)
                                (_ preferred))
                        nil)
                  (and (eq field 'date) '(:right-align t)))))
             columns))))

(defun hey--fit-list-cell (value title width)
  "Fit string VALUE to WIDTH for list column TITLE.

When truncation is necessary, retain VALUE without text properties in the
cell's help text, except when the cell already carries its own help text."
  (if (<= (string-width value) width)
      value
    (let ((display (truncate-string-to-width value width nil nil t)))
      (add-text-properties
       0 (length display)
       `(help-echo ,(or (get-text-property 0 'help-echo value)
                        (format "%s: %s" title
                                (substring-no-properties value))))
       display)
      display)))

(defun hey--configure-columns (&optional width)
  "Configure list columns for WIDTH and return non-nil when they changed."
  (let* ((width (or width (hey--minimum-window-width)))
         (layout (hey--layout-for-width width))
         (columns (hey--columns-for-layout layout))
         (format (hey--column-format layout columns width))
         (key (list layout (mapcar #'car columns) format)))
    (unless (equal key hey--columns-key)
      (setq hey--layout layout
            hey--columns columns
            hey--columns-key key
            tabulated-list-format format)
      (tabulated-list-init-header)
      t)))

(defun hey--row-vector (posting now)
  "Return the display vector for normalized POSTING at time NOW."
  (let* ((layout-columns (alist-get hey--layout hey--list-layouts))
         (row (hey-model-posting-row posting hey--layout))
         (subject-index (cl-position 'subject layout-columns :key #'car))
         (date-index (cl-position 'date layout-columns :key #'car)))
    (aset row date-index
          (hey-model-format-posting-timestamp
           (aref row date-index) now))
    (when (eq (hey-posting-kind posting) 'bundle)
      (aset row subject-index
            (concat (aref row subject-index)
                    (propertize "  ◇ Bundle" 'face 'hey-status-face))))
    (vconcat
     (cl-loop for column in layout-columns
              for value across row
              when (assq (car column) hey--columns)
              collect
              (let* ((field (car column))
                     (visible-index
                      (cl-position field hey--columns :key #'car))
                     (format (aref tabulated-list-format visible-index)))
                (if (memq field '(subject sender date memberships))
                    (hey--fit-list-cell value (car format) (cadr format))
                  value))))))

(defun hey--tabulated-entries ()
  "Return tabulated entries from buffer-local normalized records."
  (let ((now (current-time)))
    (mapcar (lambda (posting)
              (list (hey-posting-key posting) (hey--row-vector posting now)))
            hey--records)))

(defun hey--state-message ()
  "Return an actionable non-row message for the current list state."
  (cond
   ((and hey--loading (null hey--records))
    (propertize "Loading HEY mail…" 'face 'hey-status-face))
   ((and hey--error (null hey--records))
    (propertize
     (format "HEY could not load this source: %s\n\nPress g to retry."
             (hey-error-message hey--error))
     'face 'hey-error-face))
   ((and hey--warnings (null hey--records))
    (propertize
     "HEY returned no usable rows. Some malformed results were skipped.\n\nPress g to retry."
     'face 'hey-warning-face))
   ((null hey--records)
    (propertize
     (if (and (hey-source-p hey--source) (hey-source-exhausted hey--source))
         "No mail in this source."
       "No mail returned.")
     'face 'hey-status-face))
   ((and hey--error hey--stale)
    (propertize
     (format "\nShowing stale results. Refresh failed: %s\nPress g to retry."
             (hey-error-message hey--error))
     'face 'hey-error-face))
   ((and hey--warnings (hey-source-exhausted hey--source))
    (propertize
     "\nSome malformed results were skipped; no more results are available."
     'face 'hey-warning-face))
   (hey--warnings
    (propertize "\nSome malformed results were skipped."
                'face 'hey-warning-face))
   (t nil)))

(defun hey--first-row ()
  "Move point to the first real posting row, when one exists."
  (goto-char (point-min))
  (while (and (not (eobp)) (null (tabulated-list-get-id)))
    (forward-line 1)))

(defun hey--last-row ()
  "Move point to the last real posting row, when one exists."
  (goto-char (point-max))
  (while (and (> (line-number-at-pos) 1) (null (tabulated-list-get-id)))
    (forward-line -1)))

(defun hey--insert-footer-line (text)
  "Insert footer TEXT below the table, leaving a blank line above it."
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))
  (insert "\n" text "\n"))

(defun hey--render-list (&optional preserve-point width)
  "Render cached state, preserving identity when PRESERVE-POINT is non-nil.

When WIDTH is non-nil, use it for responsive column selection."
  (let ((identity (and preserve-point (tabulated-list-get-id)))
        (line (line-number-at-pos))
        (column (current-column))
        (inhibit-read-only t))
    (hey--configure-columns width)
    (setq tabulated-list-entries #'hey--tabulated-entries)
    (tabulated-list-print preserve-point)
    (dolist (text (list (hey--state-message) (hey--load-more-button)))
      (when text (hey--insert-footer-line text)))
    (cond
     ((and identity (equal identity (tabulated-list-get-id))) nil)
     (identity
      (goto-char (point-min))
      (let ((found nil))
        (while (and (not found) (not (eobp)))
          (if (equal identity (tabulated-list-get-id))
              (setq found t)
            (forward-line 1)))
        (unless found
          (goto-char (point-min))
          (forward-line (1- (max 1 line)))
          (move-to-column column))))
     (hey--records (hey--first-row))
     (t (goto-char (point-min)) (forward-line 1)))))

(defconst hey--header-separator
  (propertize " · " 'face 'hey-header-separator-face)
  "Separator between HEY header elements.")

(defun hey--header-element (text face)
  "Return header TEXT with FACE, or nil for absent or empty TEXT."
  (when (and (stringp text) (not (string-empty-p text)))
    (propertize text 'face face)))

(defun hey--header-join (parts)
  "Join non-nil header PARTS with `hey--header-separator'."
  (string-join (delq nil parts) hey--header-separator))

(defun hey--status-header ()
  "Return account, source, unread/displayed counts, and list status.
Omit lower-priority elements as the window narrows."
  (let* ((count (length hey--records))
         (base-state (cond
                      (hey--loading "loading")
                      ((and hey--error hey--stale) "stale")
                      (hey--error "error")
                      ((hey--continuation-p) nil)
                      (t "up to date")))
         (state (when (or base-state hey--warnings)
                  (hey--header-element
                   (mapconcat #'identity
                              (delq nil (list base-state
                                              (and hey--warnings "partial")))
                              ", ")
                   (cond
                    (hey--error 'hey-header-error-face)
                    (hey--warnings 'hey-header-warning-face)
                    (t 'hey-header-status-face)))))
         (updated (when hey--last-refreshed
                    (hey--header-element
                     (format-time-string "updated %H:%M" hey--last-refreshed)
                     'hey-header-updated-face)))
         (account (hey--header-element (hey--account-title)
                                       'hey-header-account-face))
         (source (hey--header-element (hey--source-title)
                                      'hey-header-source-face))
         (shown (hey--header-element
                 (format "%s/%d"
                         (if (cl-some (lambda (posting)
                                        (eq (hey-posting-seen posting) 'unknown))
                                      hey--records)
                             "?"
                           (cl-count 'unseen hey--records
                                     :key #'hey-posting-seen))
                         count)
                 'hey-header-count-face))
         (layout (or hey--layout
                     (hey--layout-for-width (hey--minimum-window-width)))))
    (hey--header-join
     (pcase layout
       ('wide (list account source shown state updated))
       ('medium (list account source shown state))
       ('narrow (list source shown state))
       (_ (list source shown state))))))

(defun hey--resize-buffer (&optional width)
  "Redraw this list for WIDTH using cached records."
  (when (and (derived-mode-p 'hey-list-mode)
             (hey--configure-columns width))
    (hey--render-list t width)))

(defun hey--window-size-change (_frame)
  "Update visible HEY list layouts after a window size change."
  (dolist (buffer (buffer-list))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (and (derived-mode-p 'hey-list-mode)
                   (get-buffer-window-list buffer nil t))
          (hey--resize-buffer))))))

(defun hey--reset-source (source)
  "Return SOURCE copied with first-page pagination state."
  (let ((copy (copy-hey-source source)))
    (setf (hey-source-continuation copy) nil
          (hey-source-consumed copy) nil
          (hey-source-exhausted copy) nil
          (hey-source-current-page copy) nil)
    copy))

(defun hey--continuation-p ()
  "Return non-nil when the current source has an unconsumed next page."
  (and (hey-source-p hey--source)
       (not (hey-source-exhausted hey--source))
       (hey-source-continuation hey--source)))

(defun hey--dispatch-source (source page owner source-key generation success failure)
  "Read SOURCE at PAGE for OWNER and deliver callbacks tagged by state.

SOURCE-KEY and GENERATION identify the session; SUCCESS and FAILURE receive
the named operation's result."
  (let ((operation
         (pcase (hey-source-kind source)
           ('box 'hey-cli-box-view)
           ('bundle 'hey-cli-bundle-view)
           ('contact-threads 'hey-cli-contact-threads)
           ('search 'hey-cli-search)
           ('label 'hey-cli-label-view)
           ('collection 'hey-cli-collection-view)
           (_ (error "Unsupported HEY source kind: %S" (hey-source-kind source))))))
    (hey--call operation (hey-source-account-id source)
               (if (eq (hey-source-kind source) 'search)
                   (hey-source-query source)
                 (hey-source-id source))
               page owner source-key generation success failure)))

(defun hey--deduplicate (existing additions)
  "Append unique ADDITIONS to EXISTING by composite posting identity."
  (let ((seen (make-hash-table :test 'equal)) result)
    (dolist (posting existing)
      (puthash (hey-posting-key posting) t seen)
      (push posting result))
    (dolist (posting additions)
      (unless (gethash (hey-posting-key posting) seen)
        (puthash (hey-posting-key posting) t seen)
        (push posting result)))
    (nreverse result)))

(defun hey--refresh (&optional append)
  "Refresh the current source, or APPEND its next page."
  (unless (and (derived-mode-p 'hey-list-mode) (hey-source-p hey--source))
    (user-error "This is not an initialized HEY list"))
  (when (and append
             (or (hey-source-exhausted hey--source)
                 (null (hey-source-continuation hey--source))))
    (user-error "No more HEY results are available"))
  (let* ((buffer (current-buffer))
         (generation (hey--next-generation))
         (source-key (hey-source-key hey--source))
         (request-source (if append hey--source (hey--reset-source hey--source)))
         (page (and append (hey-source-continuation hey--source)))
         (old-count (length hey--records)))
    (setq hey--loading t
          hey--error nil
          hey--stale (and (not append) (not (null hey--records))))
    (hey--render-list t)
    (condition-case error-data
        (setq hey--request
              (hey--dispatch-source
               request-source page buffer source-key generation
               (lambda (envelope)
                 (when (hey--commit-p buffer source-key generation)
                   (with-current-buffer buffer
                     (let* ((normalized
                             (hey-model-normalize-postings envelope request-source))
                            (incoming (plist-get normalized :value))
                            (updated-source (plist-get normalized :source))
                            (combined (hey--deduplicate
                                       (and append hey--records) incoming)))
                       ;; Stop cursor pagination when it adds no new rows.
                       (when (and append
                                  (= old-count (length combined))
                                  (eq (hey-source-continuation-kind updated-source)
                                      'cursor))
                         (setf (hey-source-continuation updated-source) nil
                               (hey-source-exhausted updated-source) t))
                       (setq hey--records combined
                             hey--source updated-source
                             hey--warnings (plist-get normalized :warnings)
                             hey--loading nil
                             hey--stale nil
                             hey--error nil
                             hey--request nil
                             hey--last-refreshed (current-time))
                       (hey--render-list t)))))
               (lambda (error)
                 (when (hey--commit-p buffer source-key generation)
                   (with-current-buffer buffer
                     (setq hey--loading nil
                           hey--stale (not (null hey--records))
                           hey--error error
                           hey--request nil)
                     (hey--render-list t))))))
      (error
       (setq hey--loading nil
             hey--stale (not (null hey--records))
             hey--error
             (make-hey-error :category 'configuration
                             :message (error-message-string error-data))
             hey--request nil)
       (hey--render-list t)))))

(defun hey-refresh ()
  "Refresh the current HEY source from its first page."
  (interactive)
  (hey--refresh nil))

(defun hey-load-more ()
  "Append the next page of the current HEY source."
  (interactive)
  (hey--refresh t))

(defun hey--load-more-button ()
  "Return the footer load-more button, or nil when nothing more can load."
  (when (and hey--records (not hey--loading) (hey--continuation-p))
    (with-temp-buffer
      (insert-text-button "[Load more]" :type 'hey-load-more-button)
      (buffer-string))))

(defun hey--load-more-action (_button)
  "Append the next page for BUTTON, anchoring point on the last loaded row."
  (hey--last-row)
  (hey-load-more))

;; Standard button bindings provide RET and mouse-2.
(define-button-type 'hey-load-more-button
  'action #'hey--load-more-action
  'help-echo "Load the next page (RET, mouse-2, or M)")

(defun hey--select-account (accounts requested)
  "Return REQUESTED from normalized ACCOUNTS, or signal a clear error."
  (or (cl-find requested accounts :key #'hey-account-id :test #'equal)
      (user-error "HEY account %s is not linked" requested)))

(defun hey--activate-account (account)
  "Activate ACCOUNT in the current list session and load its initial box."
  (setq hey--account account
        hey--source
        (make-hey-source
         :key (list 'box (hey-account-id account) hey-initial-box)
         :kind 'box :account-id (hey-account-id account)
         :id hey-initial-box :title (if (string= hey-initial-box "imbox")
                                        "Imbox"
                                      (capitalize hey-initial-box))
         :continuation-kind 'cursor)
        hey--records nil hey--warnings nil hey--error nil hey--stale nil)
  (rename-buffer (hey--public-list-name) t)
  (hey--refresh nil))

(defun hey--start-account-list (buffer generation tag requested-account)
  "Select REQUESTED-ACCOUNT from a linked-account read for BUFFER.

GENERATION and TAG identify the startup session."
  (with-current-buffer buffer
    (setq hey--request
          (hey--call
           'hey-cli-account-list buffer tag generation
           (lambda (envelope)
             (when (and (buffer-live-p buffer)
                        (= generation (buffer-local-value 'hey--generation buffer)))
               (with-current-buffer buffer
                 (let* ((normalized (hey-model-normalize-accounts envelope))
                        (accounts (plist-get normalized :value)))
                   (setq hey--warnings
                         (append hey--warnings
                                 (plist-get normalized :warnings)))
                   (condition-case error-data
                       (hey--activate-account
                        (hey--select-account accounts requested-account))
                     (error
                      (hey--startup-failure
                       buffer generation
                       (make-hey-error
                        :category 'account
                        :message (error-message-string error-data)))))))))
           (lambda (error) (hey--startup-failure buffer generation error))))))

(defun hey--start-account-resolution (buffer generation tag)
  "Resolve an account in BUFFER for startup GENERATION and TAG."
  (with-current-buffer buffer
    (if hey--configured-account
        (hey--start-account-list
         buffer generation tag hey--configured-account)
      ;; Query auth first so a logged-out CLI reaches the tailored auth error
      ;; rather than an account-list failure.
      (setq hey--request
            (hey--call
             'hey-cli-auth-status buffer tag generation
             (lambda (envelope)
               (when (and (buffer-live-p buffer)
                          (= generation
                             (buffer-local-value 'hey--generation buffer)))
                 (with-current-buffer buffer
                   (condition-case error-data
                       (let* ((normalized
                               (hey-model-normalize-auth-status envelope))
                              (status (plist-get normalized :value)))
                         (setq hey--warnings
                               (append hey--warnings
                                       (plist-get normalized :warnings)))
                         (unless (and (hey-auth-status-p status)
                                      (hey-auth-status-authenticated status))
                           (user-error
                            "HEY is not authenticated; run `hey auth login' interactively"))
                         (hey--start-account-list
                          buffer generation tag
                          (hey-auth-status-account-id status)))
                     (error
                      (hey--startup-failure
                       buffer generation
                       (make-hey-error
                        :category 'account
                        :message (error-message-string error-data))))))))
             (lambda (error)
               (hey--startup-failure buffer generation error)))))))

(defun hey--start-session ()
  "Run the read-only preflight, resolve an account, and open its Imbox."
  (let* ((buffer (current-buffer))
         (generation (hey--next-generation))
         (tag '(startup)))
    (setq hey--configured-account hey-account
          hey--loading t hey--error nil hey--records nil)
    (hey--render-list)
    (setq hey--request
          (hey--call
           'hey-cli-version buffer tag generation
           (lambda (envelope)
             (when (and (buffer-live-p buffer)
                        (= generation (buffer-local-value 'hey--generation buffer)))
               (with-current-buffer buffer
                 (let* ((result (hey-model-normalize-version envelope))
                        (version (plist-get result :value)))
                   (setq hey--warnings (append hey--warnings
                                               (plist-get result :warnings)))
                   (if (and (hey-version-p version)
                            (hey--supported-cli-version-p
                             (hey-version-version version)))
                       (hey--start-account-resolution buffer generation tag)
                     (hey--startup-failure
                      buffer generation
                      (make-hey-error
                       :category 'version
                       :message
                       (format "HEY CLI %s or newer is required."
                               hey-cli-minimum-version))))))))
           (lambda (error) (hey--startup-failure buffer generation error))))))

(defun hey--supported-cli-version-p (version)
  "Return non-nil when VERSION meets `hey-cli-minimum-version'."
  (and (stringp version)
       (condition-case nil
           (not (version< version hey-cli-minimum-version))
         (error nil))))

(defun hey--startup-failure (buffer generation error)
  "Commit startup ERROR to BUFFER for GENERATION."
  (when (and (buffer-live-p buffer)
             (= generation (buffer-local-value 'hey--generation buffer)))
    (with-current-buffer buffer
      (setq hey--loading nil hey--error error hey--request nil)
      (hey--render-list))))

;;;###autoload
(defun hey ()
  "Open a read-only HEY list at the configured account's Imbox."
  (interactive)
  (let ((buffer (if (buffer-live-p hey--main-buffer)
                    hey--main-buffer
                  (setq hey--main-buffer (get-buffer-create "*HEY*")))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'hey-list-mode)
        (hey-list-mode))
      (hey--start-session))
    (hey-display-buffer buffer 'same-window)))

(defun hey-display-buffer (buffer intent)
  "Display BUFFER according to explicit INTENT.

INTENT is `same-window' or `other-window'.  Return the selected window."
  (pcase intent
    ('same-window
     (pop-to-buffer buffer '(display-buffer-same-window)))
    ('other-window
     (pop-to-buffer buffer '(display-buffer-pop-up-window)))
    (_ (error "Unknown HEY display intent: %S" intent)))
  (selected-window))

(defun hey--restore-origin-point ()
  "Restore the originating list row for the current buffer, if still valid."
  (when-let* ((origin hey--origin)
              (buffer (plist-get origin :list-buffer))
              (source-key (plist-get origin :source-key))
              (row-id (plist-get origin :row-id))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'hey-list-mode)
                 (equal source-key
                        (and hey--source (hey-source-key hey--source))))
        (goto-char (point-min))
        (let (found)
          (while (and (not found) (not (eobp)))
            (if (equal row-id (tabulated-list-get-id))
                (setq found t)
              (forward-line 1)))
          found)))))

(defun hey-quit ()
  "Quit the current HEY view after restoring its originating row."
  (interactive)
  (hey--restore-origin-point)
  (quit-window))

(defun hey--inventory (operation normalizer prompt)
  "Fetch OPERATION, normalize with NORMALIZER, then prompt using PROMPT."
  (unless (hey-account-p hey--account)
    (user-error "HEY account is still loading"))
  (let* ((buffer (current-buffer))
         (generation (hey--next-generation))
         (source-key (and hey--source (hey-source-key hey--source)))
         (account-id (hey-account-id hey--account)))
    (setq hey--loading t)
    (hey--render-list t)
    (setq hey--request
          (hey--call
           operation account-id buffer source-key generation
           (lambda (envelope)
             (when (hey--commit-p buffer source-key generation)
               (with-current-buffer buffer
                 (let* ((result (funcall normalizer envelope account-id))
                        (sources (plist-get result :value))
                        (choices (mapcar
                                  (lambda (source)
                                    (cons (hey-source-title source) source))
                                  sources)))
                   (setq hey--loading nil
                         hey--warnings (plist-get result :warnings)
                         hey--request nil)
                   (if (null choices)
                       (progn
                         (setq hey--stale (not (null hey--records))
                               hey--error
                               (make-hey-error
                                :category 'empty-inventory
                                :message "No selectable HEY sources were returned."))
                         (hey--render-list t))
                     (condition-case nil
                         (let ((choice
                                (completing-read prompt choices nil t)))
                           (hey--switch-source (cdr (assoc choice choices))))
                       (quit (hey--render-list t))))))))
           (lambda (error)
             (when (hey--commit-p buffer source-key generation)
               (with-current-buffer buffer
                 (setq hey--loading nil
                       hey--stale (not (null hey--records))
                       hey--error error hey--request nil)
                 (hey--render-list t))))))))

(defun hey--switch-source (source)
  "Switch the current session to normalized SOURCE and refresh it."
  (setq hey--source source hey--records nil hey--warnings nil
        hey--error nil hey--stale nil)
  (rename-buffer (hey--public-list-name) t)
  (hey--refresh nil))

(defun hey-choose-box ()
  "Choose a HEY box for the current list session."
  (interactive)
  (hey--inventory 'hey-cli-box-list #'hey-model-normalize-boxes "HEY box: "))

(defun hey-choose-label ()
  "Choose a HEY label as the current read source."
  (interactive)
  (hey--inventory 'hey-cli-label-list #'hey-model-normalize-labels "HEY label: "))

(defun hey-choose-collection ()
  "Choose a HEY collection as the current read source."
  (interactive)
  (hey--inventory 'hey-cli-collection-list
                  #'hey-model-normalize-collections "HEY collection: "))

(defun hey-choose-account ()
  "Choose an account for this list session without changing HEY CLI state."
  (interactive)
  (let* ((buffer (current-buffer))
         (generation (hey--next-generation))
         (source-key (and hey--source (hey-source-key hey--source))))
    (setq hey--loading t)
    (hey--render-list t)
    (setq hey--request
          (hey--call
           'hey-cli-account-list buffer source-key generation
           (lambda (envelope)
             (when (hey--commit-p buffer source-key generation)
               (with-current-buffer buffer
                 (let* ((result (hey-model-normalize-accounts envelope))
                        (accounts (plist-get result :value))
                        (choices
                         (mapcar
                          (lambda (account)
                            (cons (format "%s%s"
                                          (hey-account-name account)
                                          (if (string-empty-p
                                               (hey-account-email account))
                                              ""
                                            (format " <%s>"
                                                    (hey-account-email account))))
                                  account))
                          accounts)))
                   (setq hey--loading nil hey--request nil)
                   (if (null choices)
                       (progn
                         (setq hey--stale (not (null hey--records))
                               hey--error
                               (make-hey-error
                                :category 'empty-inventory
                                :message "No linked HEY accounts were returned."))
                         (hey--render-list t))
                     (condition-case nil
                         (let ((choice
                                (completing-read "HEY account: "
                                                 choices nil t)))
                           (hey--activate-account
                            (cdr (assoc choice choices))))
                       (quit (hey--render-list t))))))))
           (lambda (error)
             (when (hey--commit-p buffer source-key generation)
               (with-current-buffer buffer
                 (setq hey--loading nil
                       hey--stale (not (null hey--records))
                       hey--error error hey--request nil)
                 (hey--render-list t))))))))

(defun hey-search (query)
  "Search the current HEY account for QUERY without recording history."
  (interactive
   (list
    (let ((history (make-symbol "hey-private-search-history")))
      (set history nil)
      (read-string "Search HEY: " nil history))))
  (when (string-empty-p query)
    (user-error "Search query must not be empty"))
  (unless (hey-account-p hey--account)
    (user-error "HEY account is still loading"))
  (let ((account-id (hey-account-id hey--account)))
    (hey--switch-source
     (make-hey-source
      :key (list 'search account-id query)
      :kind 'search :account-id account-id :title "Search" :query query
      :continuation-kind 'page))))

(defun hey-next-row ()
  "Move to the next real posting row."
  (interactive)
  (let ((start (point)))
    (forward-line 1)
    (while (and (not (eobp)) (null (tabulated-list-get-id)))
      (forward-line 1))
    (when (null (tabulated-list-get-id))
      (goto-char start)
      (user-error "No next HEY row"))))

(defun hey-previous-row ()
  "Move to the previous real posting row."
  (interactive)
  (let ((start (point)))
    (forward-line -1)
    (while (and (> (line-number-at-pos) 1) (null (tabulated-list-get-id)))
      (forward-line -1))
    (when (null (tabulated-list-get-id))
      (goto-char start)
      (user-error "No previous HEY row"))))

(defun hey--posting-at-point ()
  "Return the normalized posting at point, or signal a user error."
  (let ((identity (tabulated-list-get-id)))
    (or (cl-find identity hey--records :key #'hey-posting-key :test #'equal)
        (user-error "No HEY posting at point"))))

(defun hey--origin-for (posting)
  "Return origin metadata for POSTING in the current list."
  (list :list-buffer (current-buffer)
        :source-key (hey-source-key hey--source)
        :row-id (hey-posting-key posting)
        :window (selected-window)))

(defun hey--thread-context (posting)
  "Return normalized thread context derived from POSTING and current state."
  (list :account-id (hey-account-id hey--account)
        :account-name (hey--account-title)
        :topic-id (hey-posting-topic-id posting)
        :subject (hey-posting-subject posting)
        :source-title (if (eq (hey-source-kind hey--source) 'search)
                          "Search"
                        (hey--source-title))
        :labels (hey-posting-labels posting)
        :labels-known-p (not (eq (hey-source-kind hey--source) 'search))
        :collections (hey-posting-collections posting)
        :collections-known-p (not (eq (hey-source-kind hey--source) 'search))))

(defun hey--open-posting (posting intent)
  "Open normalized POSTING according to display INTENT."
  (if (and (eq (hey-posting-kind posting) 'bundle)
           (null (hey-posting-topic-id posting)))
      (let* ((account hey--account)
             (account-id (hey-account-id account))
             (contact-id (hey-posting-contact-id posting))
             (origin (hey--origin-for posting))
             (overrides hey--operation-overrides)
             (source (make-hey-source
                      :key (list (if contact-id 'contact-threads 'bundle)
                                 account-id
                                 (or contact-id (hey-posting-id posting)))
                      :kind (if contact-id 'contact-threads 'bundle)
                      :account-id account-id
                      :id (or contact-id (hey-posting-id posting))
                      :title "Bundle"
                      :continuation-kind 'cursor))
             (buffer (get-buffer-create
                      (hey--bundle-buffer-name
                       account-id (hey-posting-id posting)))))
        (with-current-buffer buffer
          (unless (derived-mode-p 'hey-list-mode)
            (hey-list-mode))
          (setq hey--account account
                hey--source source
                hey--origin origin
                hey--records nil
                hey--warnings nil
                hey--error nil
                hey--stale nil
                hey--operation-overrides overrides)
          (hey--refresh nil))
        (hey-display-buffer buffer intent))
    (unless (hey-posting-topic-id posting)
      (user-error "This HEY row has no readable thread identifier"))
    (hey--open-thread posting intent)))

(defun hey--open-thread (posting intent)
  "Fetch and display the thread represented by POSTING using INTENT."
  (let* ((origin-buffer (current-buffer))
         (origin (hey--origin-for posting))
         (context (hey--thread-context posting))
         (topic-id (hey-posting-topic-id posting))
         (account-id (plist-get context :account-id))
         (thread-key (list account-id topic-id))
         (buffer (get-buffer-create
                  (hey--thread-buffer-name account-id topic-id))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'hey-thread-mode)
        (hey-thread-mode))
      (hey--next-generation)
      (setq hey--origin origin
            hey--thread nil
            hey--thread-key thread-key
            hey--loading t
            hey--error nil
            hey--operation-overrides
            (buffer-local-value 'hey--operation-overrides origin-buffer))
      (hey--render-thread-state "Loading HEY thread…")
      (let ((generation hey--generation)
            (source-key (cons 'thread thread-key)))
        (setq hey--request
              (hey--call
               'hey-cli-thread-read (plist-get context :account-id) topic-id
               buffer source-key generation
               (lambda (envelope)
                 (when (and (buffer-live-p buffer)
                            (= generation
                               (buffer-local-value 'hey--generation buffer))
                            (equal thread-key
                                   (buffer-local-value 'hey--thread-key buffer)))
                   (with-current-buffer buffer
                     (let ((result (hey-model-normalize-thread envelope context)))
                       (setq hey--thread (plist-get result :value)
                             hey--warnings (plist-get result :warnings)
                             hey--loading nil hey--error nil hey--request nil)
                       (hey--render-thread)))))
               (lambda (error)
                 (when (and (buffer-live-p buffer)
                            (= generation
                               (buffer-local-value 'hey--generation buffer))
                            (equal thread-key
                                   (buffer-local-value 'hey--thread-key buffer)))
                   (with-current-buffer buffer
                     (setq hey--loading nil hey--error error hey--request nil)
                     (hey--render-thread-state
                      (format "HEY could not load this thread: %s"
                              (hey-error-message error))
                      'hey-error-face))))))))
    (hey-display-buffer buffer intent)))

(defun hey-open ()
  "Open the posting at point in the selected window."
  (interactive)
  (hey--open-posting (hey--posting-at-point) 'same-window))

(defun hey-open-other-window ()
  "Open the posting at point in another window."
  (interactive)
  (hey--open-posting (hey--posting-at-point) 'other-window))

(defun hey--current-app-url ()
  "Return the validated HEY application URL for the current view."
  (hey-model-validate-app-url
   (cond
    ((derived-mode-p 'hey-list-mode)
     (hey-posting-app-url (hey--posting-at-point)))
    ((and (derived-mode-p 'hey-thread-mode) (hey-thread-p hey--thread))
     (hey-thread-app-url hey--thread)))))

(defun hey-browse-url ()
  "Open the current view's validated URL in the official HEY application."
  (interactive)
  (if-let* ((url (hey--current-app-url)))
      (browse-url url)
    (user-error "No validated HEY application URL is available here")))

(defun hey-copy-url ()
  "Copy the current view's validated HEY application URL."
  (interactive)
  (if-let* ((url (hey--current-app-url)))
      (progn (kill-new url) (message "Copied validated HEY URL"))
    (user-error "No validated HEY application URL is available here")))

(defun hey--render-thread-state (message &optional face)
  "Render thread loading or failure MESSAGE using FACE.

FACE defaults to `hey-status-face'."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert (propertize message 'face (or face 'hey-status-face)) "\n")
    (goto-char (point-min))))

(defun hey--thread-header ()
  "Return thread context and message count, adapted to window width."
  (if (not (hey-thread-p hey--thread))
      (if hey--loading
          (hey--header-element "loading" 'hey-header-status-face)
        (hey--header-element "error" 'hey-header-error-face))
    (let* ((width (hey--minimum-window-width))
           (account (hey--header-element
                     (hey-thread-account-name hey--thread)
                     'hey-header-account-face))
           (source (hey--header-element
                    (hey-thread-source-title hey--thread)
                    'hey-header-source-face))
           (subject (hey--header-element
                     (hey-thread-subject hey--thread)
                     'hey-header-subject-face))
           (count (hey--header-element
                   (format "%d shown"
                           (length (hey-thread-entries hey--thread)))
                   'hey-header-count-face)))
      (hey--header-join
       (cond
        ((>= width 100) (list account source subject count))
        ((>= width 65) (list account source count))
        (t (list source count)))))))

(defun hey--render-thread ()
  "Render the normalized buffer-local HEY thread."
  (let ((inhibit-read-only t)
        preamble-end warning-start)
    (erase-buffer)
    (insert (hey-model-thread-markdown hey--thread))
    (setq preamble-end
          (text-property-any (point-min) (point-max) 'hey-entry-start t))
    (when hey--warnings
      (goto-char (point-max))
      (setq warning-start (point))
      (insert "\n> Some malformed thread entries were skipped.\n"))
    (font-lock-ensure)
    (save-excursion
      (when warning-start
        (add-face-text-property warning-start (point-max)
                                'hey-warning-face t))
      (goto-char (point-min))
      (while (re-search-forward
              "^\\(Subject:\\|Senders:\\|Messages shown:\\|Account:\\|Opened from:\\|Labels:\\|Collections:\\|Notice:\\)"
              preamble-end t)
        (add-face-text-property (match-beginning 1) (match-end 1)
                                'hey-metadata-label-face t))
      (goto-char (point-min))
      (when (re-search-forward "^Subject:[[:space:]]*\\(.*\\)$" nil t)
        (add-face-text-property (match-beginning 1) (match-end 1)
                                'hey-thread-subject-face t)))
    (goto-char (point-min))))

(defun hey--entry-starts ()
  "Return positions of all package-owned HEY entry boundaries."
  (let ((position (point-min)) result next)
    (while (setq next (text-property-any position (point-max)
                                         'hey-entry-start t))
      (push next result)
      (setq position (1+ next)))
    (nreverse result)))

(defun hey-next-entry ()
  "Move to the next package-owned HEY entry boundary."
  (interactive)
  (let ((next (cl-find-if (lambda (position) (> position (point)))
                          (hey--entry-starts))))
    (if next (goto-char next) (user-error "No next HEY entry"))))

(defun hey-previous-entry ()
  "Move to the previous package-owned HEY entry boundary."
  (interactive)
  (let ((previous (car (last (cl-remove-if-not
                              (lambda (position) (< position (point)))
                              (hey--entry-starts))))))
    (if previous (goto-char previous) (user-error "No previous HEY entry"))))

(defun hey-follow-link ()
  "Follow only a validated official HEY link at point."
  (interactive)
  (let* ((candidate (markdown-link-url))
         (url (hey-model-resolve-body-url candidate)))
    (if url
        (browse-url url)
      (user-error "Point is not at a supported HEY application link"))))

(defun hey--revert-buffer (_ignore-auto _noconfirm)
  "Asynchronously refresh the current list with `hey--refresh'."
  (hey--refresh nil))

(define-derived-mode hey-list-mode tabulated-list-mode "HEY-List"
  "Browse HEY posting lists without changing mailbox state."
  (setq-local hey--account nil
              hey--configured-account nil
              hey--source nil
              hey--records nil
              hey--generation 0
              hey--request nil
              hey--loading nil
              hey--stale nil
              hey--last-refreshed nil
              hey--error nil
              hey--warnings nil
              hey--layout nil
              hey--columns nil
              hey--columns-key nil
              hey--origin nil
              hey--operation-overrides nil
              tabulated-list-padding 2
              tabulated-list-sort-key nil
              tabulated-list-use-header-line nil
              tabulated-list-entries #'hey--tabulated-entries
              revert-buffer-function #'hey--revert-buffer
              header-line-format '(:eval (hey--status-header))
              truncate-lines t)
  (buffer-disable-undo)
  (hl-line-mode (if hey-highlight-current-row 1 -1))
  (hey--configure-columns)
  (tabulated-list-init-header))

(define-derived-mode hey-thread-mode markdown-view-mode "HEY-Thread"
  "Read a HEY thread without changing mailbox state."
  (setq-local hey--thread nil
              hey--thread-key nil
              hey--origin nil
              hey--generation 0
              hey--request nil
              hey--loading nil
              hey--error nil
              hey--warnings nil
              hey--operation-overrides nil
              header-line-format '(:eval (hey--thread-header))
              markdown-display-remote-images nil
              markdown-enable-math nil
              markdown-fontify-code-blocks-natively nil
              markdown-open-command nil
              markdown-open-image-command nil
              markdown-mouse-follow-link nil
              markdown-mode-mouse-map nil
              buffer-file-name nil
              buffer-offer-save nil
              backup-inhibited t
              auto-save-default nil
              default-directory temporary-file-directory)
  (buffer-disable-undo)
  (read-only-mode 1))

;; Keep text navigation while excluding Markdown editing, export, and process
;; commands.
(set-keymap-parent hey-thread-mode-map hey-common-map)

(add-hook 'window-size-change-functions #'hey--window-size-change)

;;; Attachments

(defun hey--attachment-header ()
  "Return the attachment view's account, count, and operation state."
  (hey--header-join
   (list
    (hey--header-element
     (and (hey-thread-p hey--attachment-thread)
          (hey-thread-account-name hey--attachment-thread)) 'hey-header-account-face)
    (hey--header-element "Attachments" 'hey-header-source-face)
    (hey--header-element (format "%d shown" (length hey--attachments))
                         'hey-header-count-face)
    (cond (hey--error
           (hey--header-element (hey-error-message hey--error) 'hey-header-error-face))
          (hey--loading (hey--header-element "Loading…" 'hey-header-status-face))
          (hey--stale (hey--header-element "Stale" 'hey-header-warning-face)))
    (hey--header-element hey--attachment-save-status 'hey-header-status-face))))

(defun hey--attachment-message (attachment)
  "Return the known sender and date for ATTACHMENT, or its message ID."
  (let ((entry (cl-find (hey-attachment-message-id attachment)
                        (hey-thread-entries hey--attachment-thread)
                        :key #'hey-entry-id :test #'equal)))
    (if entry
        (string-join (delq nil (list (hey-entry-sender entry)
                                     (hey-entry-timestamp entry))) " ")
      (hey-attachment-message-id attachment))))

(defun hey--attachment-row (attachment)
  "Return a table row for normalized ATTACHMENT."
  (let* ((size (hey-attachment-byte-size attachment))
         (filename (hey-attachment-filename attachment))
         (message (hey--attachment-message attachment)))
    (list (hey-attachment-id attachment)
          (vector (propertize (if (string-empty-p filename) "(unnamed)" filename)
                              'help-echo filename)
                  (hey-attachment-content-type attachment)
                  (propertize (if size (file-size-human-readable size) "?")
                              'hey-byte-size (or size -1))
                  (propertize message 'help-echo message)))))

(defun hey--attachment-size-less-p (left right)
  "Return whether attachment row LEFT has fewer bytes than RIGHT."
  (< (get-text-property 0 'hey-byte-size (aref (cadr left) 2))
     (get-text-property 0 'hey-byte-size (aref (cadr right) 2))))

(defun hey--render-attachments ()
  "Render attachments while retaining the selected identity."
  (let ((id (tabulated-list-get-id))
        (inhibit-read-only t))
    (setq tabulated-list-entries (mapcar #'hey--attachment-row hey--attachments))
    (tabulated-list-print t)
    (save-excursion
      (goto-char (point-max))
      (when (and (not hey--loading) (not hey--error) (not hey--attachments))
        (insert "\nNo attachments found.\n"))
      (when hey--error
        (insert "\n" (hey-error-message hey--error) " Press g to retry.\n"))
      (dolist (notice (append (when hey--attachment-notice
                                (list hey--attachment-notice))
                              hey--warnings))
        (insert "\n" (propertize notice 'face 'hey-warning-face) "\n")))
    (when id
      (goto-char (point-min))
      (while (and (not (eobp)) (not (equal id (tabulated-list-get-id))))
        (forward-line 1))
      (when (eobp) (goto-char (point-min))))
    (force-mode-line-update)))

(defun hey--attachment-current-p (buffer key generation)
  "Return whether BUFFER still accepts attachment KEY and GENERATION."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (and (derived-mode-p 'hey-attachment-mode)
              (= generation hey--generation)
              (hey-thread-p hey--attachment-thread)
              (equal key (list (hey-thread-account-id hey--attachment-thread)
                               (hey-thread-topic-id hey--attachment-thread)))))))

(defun hey-refresh-attachments ()
  "Refresh the current thread's attachment list on demand."
  (interactive)
  (unless (derived-mode-p 'hey-attachment-mode)
    (user-error "Open an attachment list first"))
  (let* ((buffer (current-buffer))
         (thread hey--attachment-thread)
         (key (list (hey-thread-account-id thread) (hey-thread-topic-id thread)))
         (generation (hey--next-generation)))
    (setq hey--loading t hey--error nil)
    (hey--render-attachments)
    (setq hey--request
          (hey--call
           'hey-cli-attachment-list (car key) (cadr key)
           buffer (cons 'attachments key) generation
           (lambda (envelope)
             (when (hey--attachment-current-p buffer key generation)
               (with-current-buffer buffer
                 (let ((result (hey-model-normalize-attachments envelope)))
                   (setq hey--attachments (plist-get result :value)
                         hey--warnings (plist-get result :warnings)
                         hey--attachment-notice (plist-get result :notice)
                         hey--loading nil hey--error nil hey--stale nil
                         hey--request nil)
                   (hey--render-attachments)))))
           (lambda (error)
             (when (hey--attachment-current-p buffer key generation)
               (with-current-buffer buffer
                 (setq hey--loading nil hey--error error hey--request nil
                       hey--stale (and hey--attachments t))
                 (hey--render-attachments))))))))

(defun hey-list-attachments ()
  "Show the current thread's attachments in a separate list."
  (interactive)
  (unless (and (derived-mode-p 'hey-thread-mode) (hey-thread-p hey--thread))
    (user-error "Wait for a readable HEY thread"))
  (let* ((thread hey--thread)
         (origin (point-marker))
         (overrides hey--operation-overrides)
         (name (format "*HEY attachments %s %s*"
                       (hey-thread-account-id thread) (hey-thread-topic-id thread)))
         (existing (get-buffer name))
         (buffer (get-buffer-create name))
         (fresh (not (and existing
                          (with-current-buffer existing
                            (derived-mode-p 'hey-attachment-mode))))))
    (with-current-buffer buffer
      (when fresh (hey-attachment-mode))
      (when (markerp hey--attachment-origin)
        (set-marker hey--attachment-origin nil))
      (setq hey--attachment-thread thread
            hey--attachment-origin origin
            hey--operation-overrides overrides)
      (when fresh (hey-refresh-attachments)))
    (hey-display-buffer buffer 'same-window)))

(defun hey-quit-attachments ()
  "Return to the originating thread without canceling downloads."
  (interactive)
  (if (and (markerp hey--attachment-origin)
           (marker-buffer hey--attachment-origin))
      (let ((origin hey--attachment-origin))
        ;; Preserve the thread's return path to its originating mail list.
        (quit-window)
        (unless (eq (current-buffer) (marker-buffer origin))
          (hey-display-buffer (marker-buffer origin) 'same-window))
        (goto-char origin))
    (quit-window)))

(defun hey--attachment-basename (filename)
  "Return a portable suggested basename for attachment FILENAME."
  (let* ((base (file-name-nondirectory
                (subst-char-in-string ?\\ ?/ filename)))
         (clean (replace-regexp-in-string "[<>:\"/\\\\|?*]" "_"
                                          (hey-model-sanitize-metadata base))))
    (setq clean (string-trim clean "[ .]+" "[ .]+"))
    (when (string-match-p
           "\\`\\(?:CON\\|PRN\\|AUX\\|NUL\\|COM[1-9]\\|LPT[1-9]\\)\\(?:\\.\\|\\'\\)"
           (upcase clean))
      (setq clean (concat "_" clean)))
    (if (string-empty-p clean) "attachment" clean)))

(defun hey--attachment-destination (path)
  "Validate PATH and return its absolute name under a canonical parent."
  (unless (and (stringp path) (not (file-remote-p path))
               (not (string-match-p "[\0-\x1f\x7f]" path)))
    (user-error "Choose a local attachment destination"))
  (let* ((absolute (expand-file-name path))
         (parent (file-name-directory absolute)))
    (when (or (file-exists-p absolute) (file-symlink-p absolute))
      (user-error "Destination already exists; choose another filename"))
    (unless (and (file-directory-p parent) (file-writable-p parent))
      (user-error "Choose an existing writable destination directory"))
    (expand-file-name (file-name-nondirectory absolute) (file-truename parent))))

(defun hey--publish-attachment (result id staged destination)
  "Publish RESULT for ID from STAGED to DESTINATION without replacement."
  (let ((attributes (file-attributes staged 'integer)))
    (unless (and (hey-saved-attachment-p result)
                 (equal id (hey-saved-attachment-id result))
                 (equal staged (hey-saved-attachment-path result))
                 attributes (null (file-attribute-type attributes))
                 (= (file-attribute-size attributes)
                    (hey-saved-attachment-byte-size result)))
      (error "Attachment download could not be verified")))
  (when (or (file-exists-p destination) (file-symlink-p destination))
    (signal 'file-already-exists '("Attachment destination already exists")))
  (add-name-to-file staged destination nil))

(defun hey--attachment-save-state (buffer token status)
  "Finish TOKEN's save in BUFFER and report STATUS in the echo area."
  (when (and (buffer-live-p buffer)
             (eq token (buffer-local-value 'hey--attachment-save-token buffer)))
    (with-current-buffer buffer
      (setq hey--attachment-save-request nil
            hey--attachment-save-token nil
            hey--attachment-save-status nil)
      (force-mode-line-update)
      (message "%s" status))))

(defun hey--start-attachment-save (attachment destination)
  "Download ATTACHMENT to validated DESTINATION with private staging."
  (when hey--attachment-save-token
    (user-error "An attachment is already downloading; press c to cancel"))
  (setq destination (hey--attachment-destination destination))
  (let* ((buffer (current-buffer))
         (account (hey-thread-account-id hey--attachment-thread))
         (id (hey-attachment-id attachment))
         (token (list id destination))
         (directory (make-temp-file
                     (expand-file-name ".hey-attachment-"
                                       (file-name-directory destination)) t))
         (staged (expand-file-name "download" directory))
         (finish (lambda ()
                   (unwind-protect
                       (condition-case nil
                           (when (file-directory-p directory)
                             (delete-directory directory t))
                         (file-error
                          (message "Attachment temporary files could not be removed.")))
                     (hey--attachment-save-state
                      buffer token "Attachment download did not complete."))))
         handed-off)
    (setq hey--attachment-save-token token
          hey--attachment-save-status "Saving attachment…")
    (force-mode-line-update)
    (unwind-protect
        (progn
          (message "%s" hey--attachment-save-status)
          (setq hey--attachment-save-request
                (hey--call
                 'hey-cli-attachment-save account id staged
                 buffer (list 'attachment-save account id) 0
                 (lambda (envelope)
                   (when (and (buffer-live-p buffer)
                              (eq token (buffer-local-value
                                         'hey--attachment-save-token buffer)))
                     (condition-case nil
                         (progn
                           (hey--publish-attachment
                            (hey-model-normalize-saved-attachment envelope)
                            id staged destination)
                           (hey--attachment-save-state
                            buffer token "Attachment saved."))
                       (file-already-exists
                        (hey--attachment-save-state
                         buffer token "Destination exists; choose another filename."))
                       (file-error
                        (hey--attachment-save-state
                         buffer token
                         "Cannot create the file; choose a destination supporting hard links."))
                       (error
                        (hey--attachment-save-state
                         buffer token
                         "Attachment could not be verified or saved; choose another destination.")))))
                 (lambda (error)
                   (hey--attachment-save-state
                    buffer token
                    (pcase (hey-error-category error)
                      ('canceled "Attachment download canceled.")
                      ('timeout "Attachment download timed out; retry saving.")
                      (_ "Attachment download failed; retry saving."))))
                 finish))
          (setq handed-off t))
      (unless handed-off
        (funcall finish)
        (hey--attachment-save-state buffer token "Attachment download failed.")))))

(defun hey-save-attachment ()
  "Save the attachment at point to a new local file."
  (interactive)
  (unless (derived-mode-p 'hey-attachment-mode)
    (user-error "Open an attachment list first"))
  (when hey--attachment-save-token
    (user-error "An attachment is already downloading; press c to cancel"))
  (let ((attachment (cl-find (tabulated-list-get-id) hey--attachments
                             :key #'hey-attachment-id :test #'equal)))
    (unless attachment (user-error "Choose an attachment row"))
    (let* ((directory (or hey--attachment-directory
                          (and (file-directory-p (expand-file-name "~/Downloads/"))
                               (expand-file-name "~/Downloads/"))
                          (expand-file-name "~/")))
           (suggestion (hey--attachment-basename (hey-attachment-filename attachment)))
           destination)
      (while (not destination)
        (let ((chosen (read-file-name "Save attachment as: " directory
                                      (expand-file-name suggestion directory)
                                      nil suggestion)))
          (condition-case error
              (setq destination (hey--attachment-destination chosen))
            (user-error (message "%s" (error-message-string error))))))
      (setq hey--attachment-directory (file-name-directory destination))
      (hey--start-attachment-save attachment destination))))

(defun hey-cancel-attachment-save ()
  "Cancel the attachment download owned by the current list."
  (interactive)
  (unless hey--attachment-save-request
    (user-error "No attachment download is running"))
  (hey-cli-cancel-request hey--attachment-save-request))

(defvar hey-attachment-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'hey-save-attachment)
    (define-key map (kbd "RET") #'hey-save-attachment)
    (define-key map (kbd "c") #'hey-cancel-attachment-save)
    (define-key map (kbd "g") #'hey-refresh-attachments)
    (define-key map (kbd "q") #'hey-quit-attachments)
    (define-key map (kbd "n") #'next-line)
    (define-key map (kbd "p") #'previous-line)
    (define-key map (kbd "?") #'describe-mode)
    map)
  "Keymap for attachment listing and explicit local saving.")

(define-derived-mode hey-attachment-mode tabulated-list-mode "HEY-Attachments"
  "List attachments and save selected files without mailbox mutations."
  (setq-local tabulated-list-format
              [("Filename" 30 t) ("Type" 22 t)
               ("Size" 8 hey--attachment-size-less-p) ("Message" 30 t)]
              tabulated-list-use-header-line nil
              tabulated-list-sort-key nil
              header-line-format '(:eval (hey--attachment-header))
              default-directory temporary-file-directory
              revert-buffer-function (lambda (&rest _) (hey-refresh-attachments)))
  (tabulated-list-init-header)
  (buffer-disable-undo)
  (hl-line-mode (if hey-highlight-current-row 1 -1)))

(provide 'hey)
;;; hey.el ends here
