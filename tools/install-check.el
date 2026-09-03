;;; install-check.el --- Verify a fresh package installation -*- lexical-binding: t -*-

;;; Commentary:

;; Install the generated tar and its pinned dependency into a fresh temporary
;; package-user-dir, verify autoload discovery, and require all runtime features.

;;; Code:

(require 'package)
(load (expand-file-name
       "common.el" (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

(defconst hey-build-install-markdown-version '(2 8)
  "Expected markdown-mode dependency version for install checks.")

(defconst hey-build-install-markdown-sha256
  "74220b9337e064a185123dfa1f9e307ded19159aa42917d7c568b77807664ba2"
  "Expected digest of the markdown-mode 2.8 install artifact.")

(defun hey-build-install-local-markdown (directory)
  "Install markdown-mode.el from DIRECTORY into the current package dir."
  (let ((source (expand-file-name "markdown-mode.el" directory)))
    (unless (file-readable-p source)
      (error "Local markdown-mode package is missing: %s" source))
    (package-install-file source)))

(defun hey-build-install-cached-markdown ()
  "Install the verified pinned markdown-mode tar into the current package dir."
  (let* ((override (getenv "MARKDOWN_MODE_ARCHIVE"))
         (source
          (if (and override (not (string-empty-p override)))
              (expand-file-name override)
            (hey-build-path "test/tmp/downloads/markdown-mode-2.8.tar"))))
    (when (file-remote-p source)
      (error "MARKDOWN_MODE_ARCHIVE must name a local archive"))
    (unless (file-readable-p source)
      (error "Pinned markdown-mode tar is absent; run make bootstrap"))
    (unless (equal (hey-build-file-sha256 source)
                   hey-build-install-markdown-sha256)
      (error "Pinned markdown-mode tar failed its SHA-256 check"))
    (package-install-file source)))

(let* ((temporary-root (hey-build-path "test/tmp"))
       (installation (progn
                       (make-directory temporary-root t)
                       (make-temp-file
                        (expand-file-name "install-check-" temporary-root)
                        t)))
       (package-file
        (expand-file-name
         (or (getenv "HEY_PACKAGE_FILE")
             (hey-build-path "dist/hey-0.1.0.tar")))))
  (unwind-protect
      (progn
        (unless (file-readable-p package-file)
          (error "Built package is missing: %s" package-file))
        (setq package-enable-at-startup nil
              package-user-dir (expand-file-name "elpa" installation)
              package-alist nil
              package-activated-list nil
              load-path (copy-sequence load-path))
        (make-directory package-user-dir t)
        (package-initialize)
        (if-let* ((local-markdown
                   (hey-build-environment-directory "MARKDOWN_MODE_DIR")))
            (hey-build-install-local-markdown local-markdown)
          (hey-build-install-cached-markdown))
        (package-initialize)
        (unless (equal
                 (package-desc-version
                  (car (cdr (assq 'markdown-mode package-alist))))
                 hey-build-install-markdown-version)
          (error "Fresh install did not contain markdown-mode 2.8"))
        (package-install-file package-file)
        (package-initialize)
        (unless (autoloadp (symbol-function 'hey))
          (error "Installed package did not expose an autoload for `hey'"))
        ;; A require must never discover or start a real HEY executable.
        (setq hey-executable "/nonexistent/hey-install-check")
        (require 'hey)
        (dolist (feature '(hey-model hey-cli hey))
          (unless (featurep feature)
            (error "Installed package failed to provide %s" feature)))
        (unless (equal hey-executable "/nonexistent/hey-install-check")
          (error "Package load replaced the fail-closed executable sentinel"))
        (message "Fresh package install, autoload, and require succeeded"))
    (when (file-directory-p installation)
      (delete-directory installation t))))
