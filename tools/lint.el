;;; lint.el --- Run checkdoc and package-lint -*- lexical-binding: t -*-

;;; Commentary:

;; Run strict documentation and package metadata linting.

;;; Code:

(require 'cl-lib)
(require 'checkdoc)
(load (expand-file-name
       "common.el" (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

(hey-build-initialize-packages t)

(dolist (file (hey-build-library-files))
  (when-let* ((diagnostics (get-buffer checkdoc-diagnostic-buffer)))
    (kill-buffer diagnostics))
  (setq checkdoc-pending-errors nil)
  (with-current-buffer (find-file-noselect (hey-build-path file))
    (checkdoc-batch)))

(let ((failed nil)
      (main-file (hey-build-path "hey.el")))
  (dolist (file (hey-build-library-files))
    (with-temp-buffer
      (insert-file-contents (hey-build-path file))
      (setq buffer-file-name (hey-build-path file))
      (emacs-lisp-mode)
      (let ((package-lint-main-file main-file))
        (dolist (diagnostic (package-lint-buffer))
          (setq failed t)
          (pcase-let ((`(,line ,column ,type ,message) diagnostic))
            (message "%s:%d:%d: %s: %s"
                     file line column type message))))))
  (when failed
    (error "package-lint reported diagnostics")))

(message "checkdoc and package-lint completed without diagnostics")
