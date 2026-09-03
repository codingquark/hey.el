;;; common.el --- Shared isolated build helpers -*- lexical-binding: t -*-

;;; Commentary:

;; Common path and dependency setup for repository-local build commands.

;;; Code:

(require 'package)
(require 'subr-x)

(defconst hey-build-root
  (file-name-directory
   (directory-file-name
    (file-name-directory (or load-file-name buffer-file-name))))
  "Absolute repository root used by build scripts.")

(defun hey-build-path (&rest parts)
  "Return a path below the repository root assembled from PARTS."
  (let ((path hey-build-root))
    (dolist (part parts path)
      (setq path (expand-file-name part path)))))

(defun hey-build-environment-directory (name &optional required)
  "Return local directory named by environment variable NAME.
When REQUIRED is non-nil, signal an error if NAME is unset."
  (let ((value (getenv name)))
    (cond
     ((and value (not (string-empty-p value)))
      (let ((directory (file-truename (expand-file-name value))))
        (unless (file-directory-p directory)
          (error "%s does not name a directory: %s" name value))
        (when (file-remote-p directory)
          (error "%s must be local: %s" name value))
        directory))
     (required
      (error "%s must be set" name)))))

(defun hey-build-initialize-packages (&optional need-package-lint)
  "Initialize isolated dependencies.
When NEED-PACKAGE-LINT is non-nil, require `package-lint' as well."
  (setq package-enable-at-startup nil
        package-user-dir
        (expand-file-name
         (or (getenv "HEY_ELPA_DIR")
             (hey-build-path "test/tmp/elpa"))))
  (package-initialize)
  (when-let* ((markdown-directory
               (hey-build-environment-directory "MARKDOWN_MODE_DIR")))
    (add-to-list 'load-path markdown-directory))
  (unless (locate-library "markdown-mode")
    (error "markdown-mode is unavailable; run make bootstrap"))
  (when need-package-lint
    (unless (locate-library "package-lint")
      (error "package-lint is unavailable; run make bootstrap"))
    (require 'package-lint)))

(defun hey-build-runtime-files ()
  "Return the ordered explicit runtime package file allowlist."
  '("hey.el" "hey-cli.el" "hey-model.el" "hey-pkg.el"))

(defun hey-build-library-files ()
  "Return the ordered Emacs Lisp library file list."
  '("hey-model.el" "hey-cli.el" "hey.el"))

(defun hey-build-file-sha256 (file)
  "Return the SHA-256 digest of FILE contents."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (secure-hash 'sha256 (current-buffer))))

(provide 'hey-build-common)
;;; common.el ends here
