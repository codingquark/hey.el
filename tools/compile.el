;;; compile.el --- Strict isolated byte compilation -*- lexical-binding: t -*-

;;; Commentary:

;; Byte-compile runtime libraries into test/tmp rather than the source tree.

;;; Code:

(require 'bytecomp)
(load (expand-file-name
       "common.el" (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

(hey-build-initialize-packages)
(add-to-list 'load-path hey-build-root)

(let ((output-directory (hey-build-path "test/tmp/byte-compile")))
  (make-directory output-directory t)
  (setq byte-compile-error-on-warn t)
  (let ((byte-compile-dest-file-function
         (lambda (source)
           (expand-file-name
            (concat (file-name-base source) ".elc")
            output-directory))))
    (dolist (file (hey-build-library-files))
      (let ((source (hey-build-path file)))
        (unless (file-readable-p source)
          (error "Missing runtime library: %s" source))
        (unless (byte-compile-file source)
          (error "Byte compilation failed: %s" source))))))

(message "Byte compilation completed without warnings")
