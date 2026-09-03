;;; bootstrap.el --- Install isolated development dependencies -*- lexical-binding: t -*-

;;; Commentary:

;; Install pinned markdown-mode and package-lint artifacts without using the
;; user's package directory.  Local directories/artifacts may replace network
;; downloads for reproducible offline bootstrap.

;;; Code:

(require 'package)
(require 'url)
(load (expand-file-name
       "common.el" (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

(defconst hey-build-markdown-version '(2 8)
  "Exact markdown-mode version used by development and CI.")

(defconst hey-build-markdown-url
  "https://stable.melpa.org/packages/markdown-mode-2.8.tar"
  "Pinned markdown-mode package artifact URL.")

(defconst hey-build-markdown-sha256
  "74220b9337e064a185123dfa1f9e307ded19159aa42917d7c568b77807664ba2"
  "Expected SHA-256 digest of the pinned markdown-mode package artifact.")

(defconst hey-build-package-lint-version '(0 26)
  "Exact package-lint version used by development and CI.")

(defconst hey-build-package-lint-url
  "https://stable.melpa.org/packages/package-lint-0.26.tar"
  "Pinned package-lint artifact URL.")

(defconst hey-build-package-lint-sha256
  "ecc19ae4bb8a3447f020eab13a76ab4e04c1a787c3b596b28028313222cacbfb"
  "Expected SHA-256 digest of the pinned package-lint artifact.")

(defun hey-build-package-file-version (file)
  "Return the package version declared by Emacs Lisp package FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (package-desc-version (package-buffer-info))))

(defun hey-build-verify-local-markdown (directory)
  "Verify markdown-mode 2.8 is present in DIRECTORY."
  (let ((file (expand-file-name "markdown-mode.el" directory)))
    (unless (file-readable-p file)
      (error "MARKDOWN_MODE_DIR lacks markdown-mode.el: %s" directory))
    (unless (equal (hey-build-package-file-version file)
                   hey-build-markdown-version)
      (error "MARKDOWN_MODE_DIR must provide markdown-mode 2.8"))
    (add-to-list 'load-path directory)
    (message "Using local markdown-mode 2.8 from %s" directory)))

(defun hey-build-installed-version (package-name)
  "Return the highest installed version of PACKAGE-NAME, or nil."
  (when-let* ((descriptors (cdr (assq package-name package-alist))))
    (package-desc-version (car descriptors))))

(defun hey-build-pinned-archive (environment-name filename url sha256)
  "Return a verified pinned package archive.

ENVIRONMENT-NAME may name a local archive for offline use.  Otherwise cache
FILENAME below `test/tmp/downloads', downloading it from URL when absent.
Require its digest to equal SHA256 in every case."
  (let* ((override (getenv environment-name))
         (download-directory (hey-build-path "test/tmp/downloads"))
         (archive (if (and override (not (string-empty-p override)))
                      (expand-file-name override)
                    (expand-file-name filename download-directory))))
    (when (file-remote-p archive)
      (error "%s must name a local archive" environment-name))
    (unless (file-readable-p archive)
      (when override
        (error "%s is not readable: %s" environment-name archive))
      (make-directory download-directory t)
      (message "Downloading pinned package artifact %s" filename)
      (url-copy-file url archive t))
    (unless (equal (hey-build-file-sha256 archive) sha256)
      (error "Pinned package artifact failed its SHA-256 check: %s" filename))
    archive))

(defun hey-build-install-pinned-markdown ()
  "Install the pinned markdown-mode artifact in the isolated package dir."
  (let ((archive
         (hey-build-pinned-archive
          "MARKDOWN_MODE_ARCHIVE" "markdown-mode-2.8.tar"
          hey-build-markdown-url hey-build-markdown-sha256)))
    (unless (equal (hey-build-installed-version 'markdown-mode)
                   hey-build-markdown-version)
      (package-install-file archive))
    (unless (equal (hey-build-installed-version 'markdown-mode)
                   hey-build-markdown-version)
      (error "Failed to install markdown-mode 2.8"))))

(defun hey-build-install-pinned-package-lint ()
  "Install the pinned package-lint artifact in the isolated package dir."
  (let ((archive
         (hey-build-pinned-archive
          "PACKAGE_LINT_ARCHIVE" "package-lint-0.26.tar"
          hey-build-package-lint-url hey-build-package-lint-sha256)))
    (unless (equal (hey-build-installed-version 'package-lint)
                   hey-build-package-lint-version)
      (package-install-file archive))
    (unless (equal (hey-build-installed-version 'package-lint)
                   hey-build-package-lint-version)
      (error "Failed to install package-lint 0.26"))))

(setq package-enable-at-startup nil
      package-user-dir
      (expand-file-name
       (or (getenv "HEY_ELPA_DIR")
           (hey-build-path "test/tmp/elpa")))
      package-archives
      '(("gnu" . "https://elpa.gnu.org/packages/")
        ("melpa-stable" . "https://stable.melpa.org/packages/")))
(make-directory package-user-dir t)
(package-initialize)

(if-let* ((local-markdown
           (hey-build-environment-directory "MARKDOWN_MODE_DIR")))
    (hey-build-verify-local-markdown local-markdown)
  (hey-build-install-pinned-markdown))

(hey-build-install-pinned-package-lint)

(message "Bootstrap complete in %s" package-user-dir)
