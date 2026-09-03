;;; bootstrap.el --- Install isolated development dependencies -*- lexical-binding: t -*-

;;; Commentary:

;; Install markdown-mode 2.8 and package-lint without using the user's package
;; directory.  MARKDOWN_MODE_DIR may replace the downloaded markdown-mode.

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

(defun hey-build-install-pinned-markdown ()
  "Install the pinned markdown-mode artifact in the isolated package dir."
  (let* ((download-directory (hey-build-path "test/tmp/downloads"))
         (archive (expand-file-name "markdown-mode-2.8.tar"
                                    download-directory)))
    (make-directory download-directory t)
    (unless (file-readable-p archive)
      (message "Downloading pinned markdown-mode 2.8")
      (url-copy-file hey-build-markdown-url archive t))
    (unless (equal (hey-build-file-sha256 archive)
                   hey-build-markdown-sha256)
      (error "Pinned markdown-mode artifact failed its SHA-256 check"))
    (unless (equal (hey-build-installed-version 'markdown-mode)
                   hey-build-markdown-version)
      (package-install-file archive))
    (unless (equal (hey-build-installed-version 'markdown-mode)
                   hey-build-markdown-version)
      (error "Failed to install markdown-mode 2.8"))))

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

(unless (package-installed-p 'package-lint)
  (message "Refreshing package metadata for package-lint")
  (package-refresh-contents)
  (package-install 'package-lint))

(unless (package-installed-p 'package-lint)
  (error "Failed to install package-lint"))

(message "Bootstrap complete in %s" package-user-dir)
