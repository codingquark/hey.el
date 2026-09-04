;;; package.el --- Build deterministic multi-file package tar -*- lexical-binding: t -*-

;;; Commentary:

;; Build a byte-for-byte reproducible ustar archive from an explicit runtime
;; allowlist, without depending on package-build.

;;; Code:

(require 'package)
(load (expand-file-name
       "common.el" (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

(defun hey-build-tar-store (header offset width value)
  "Store ASCII VALUE in HEADER at OFFSET within WIDTH bytes."
  (let ((bytes (string-make-unibyte value)))
    (when (> (length bytes) width)
      (error "Tar header value is too long: %s" value))
    (dotimes (index (length bytes))
      (aset header (+ offset index) (aref bytes index)))))

(defun hey-build-tar-octal (value width)
  "Format VALUE as a null-terminated octal field of WIDTH bytes."
  (concat (format (format "%%0%do" (1- width)) value) "\0"))

(defun hey-build-tar-header (name size type mode)
  "Return a deterministic ustar header for NAME, SIZE, TYPE, and MODE."
  (let ((header (string-make-unibyte (make-string 512 0))))
    (hey-build-tar-store header 0 100 name)
    (hey-build-tar-store header 100 8 (hey-build-tar-octal mode 8))
    (hey-build-tar-store header 108 8 (hey-build-tar-octal 0 8))
    (hey-build-tar-store header 116 8 (hey-build-tar-octal 0 8))
    (hey-build-tar-store header 124 12 (hey-build-tar-octal size 12))
    (hey-build-tar-store header 136 12 (hey-build-tar-octal 0 12))
    (hey-build-tar-store header 148 8 "        ")
    (hey-build-tar-store header 156 1 type)
    (hey-build-tar-store header 257 6 "ustar\0")
    (hey-build-tar-store header 263 2 "00")
    (hey-build-tar-store header 265 32 "root")
    (hey-build-tar-store header 297 32 "root")
    (hey-build-tar-store header 329 8 (hey-build-tar-octal 0 8))
    (hey-build-tar-store header 337 8 (hey-build-tar-octal 0 8))
    (let ((checksum 0))
      (dotimes (index 512)
        (setq checksum (+ checksum (aref header index))))
      (hey-build-tar-store header 148 8 (format "%06o\0 " checksum)))
    header))

(defun hey-build-file-bytes (file)
  "Return FILE contents as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(defun hey-build-main-package-description ()
  "Return the package description declared by the main hey.el file."
  (with-temp-buffer
    (insert-file-contents (hey-build-path "hey.el"))
    (package-buffer-info)))

(defun hey-build-package-descriptor-bytes (description)
  "Return generated hey-pkg.el bytes for package DESCRIPTION."
  (let ((temporary (make-temp-file "hey-pkg-" nil ".el")))
    (unwind-protect
        (progn
          (package-generate-description-file description temporary)
          (replace-regexp-in-string
           "\\`;;; Generated package description from [^\n]+"
           ";;; Generated package description from hey.el  -*- no-byte-compile: t -*-"
           (hey-build-file-bytes temporary) t t))
      (when (file-exists-p temporary)
        (delete-file temporary)))))

(defun hey-build-tar-entry (name bytes)
  "Return a deterministic regular-file tar entry NAME containing BYTES."
  (let* ((size (length bytes))
         (padding (mod (- 512 (mod size 512)) 512)))
    (concat (hey-build-tar-header name size "0" #o644)
            bytes
            (string-make-unibyte (make-string padding 0)))))

(let* ((description (hey-build-main-package-description))
       (name (symbol-name (package-desc-name description)))
       (version (package-version-join (package-desc-version description)))
       (directory (format "%s-%s/" name version))
       (expected-output (hey-build-path "dist" (format "%s-%s.tar" name version)))
       (configured-output (or (getenv "HEY_PACKAGE_FILE") expected-output))
       (output (expand-file-name configured-output))
       (archive (hey-build-tar-header directory 0 "5" #o755)))
  (unless (equal name "hey")
    (error "Unexpected package name in hey.el metadata: %s" name))
  (unless (equal output expected-output)
    (error "HEY_PACKAGE_FILE must match descriptor version: %s" expected-output))
  (dolist (relative (hey-build-runtime-files))
    (let ((source (hey-build-path relative)))
      (unless (file-regular-p source)
        (error "Allowlisted package file is missing: %s" source))
      (let ((bytes (hey-build-file-bytes source)))
        (when (string-match-p (regexp-quote hey-build-root) bytes)
          (error "Package file contains the local repository path: %s"
                 relative))
        (setq archive
              (concat archive
                      (hey-build-tar-entry
                       (concat directory relative) bytes))))))
  (setq archive
        (concat archive
                (hey-build-tar-entry
                 (concat directory "hey-pkg.el")
                 (hey-build-package-descriptor-bytes description))))
  (setq archive
        (concat archive (string-make-unibyte (make-string 1024 0))))
  (make-directory (file-name-directory output) t)
  (let ((temporary (make-temp-file
                    (expand-file-name ".hey-package-"
                                      (file-name-directory output)))))
    (unwind-protect
        (let ((coding-system-for-write 'no-conversion))
          (write-region archive nil temporary nil 'silent)
          (rename-file temporary output t))
      (when (file-exists-p temporary)
        (delete-file temporary))))
  (message "Built %s (%s)"
           output (hey-build-file-sha256 output)))
