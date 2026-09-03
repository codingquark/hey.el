;;; read-only-audit.el --- Audit the closed process boundary -*- lexical-binding: t -*-

;;; Commentary:

;; Perform a source-level call-graph check that only the frozen named read
;; operations can reach the package's private subprocess primitive.

;;; Code:

(require 'cl-lib)
(load (expand-file-name
       "common.el" (file-name-directory (or load-file-name buffer-file-name)))
      nil 'nomessage)

(defconst hey-build-read-operations
  '((hey-cli-version . hey-cli-build-version)
    (hey-cli-auth-status . hey-cli-build-auth-status)
    (hey-cli-account-list . hey-cli-build-account-list)
    (hey-cli-box-list . hey-cli-build-box-list)
    (hey-cli-box-view . hey-cli-build-box-view)
    (hey-cli-bundle-view . hey-cli-build-bundle-view)
    (hey-cli-search . hey-cli-build-search)
    (hey-cli-thread-read . hey-cli-build-thread-read)
    (hey-cli-label-list . hey-cli-build-label-list)
    (hey-cli-label-view . hey-cli-build-label-view)
    (hey-cli-collection-list . hey-cli-build-collection-list)
    (hey-cli-collection-view . hey-cli-build-collection-view))
  "Frozen mapping from named read operations to pure argv builders.")

(defconst hey-build-process-primitives
  '(async-shell-command call-process call-process-region make-network-process
    make-pipe-process make-process open-network-stream process-file shell-command
    shell-command-on-region start-file-process start-process url-retrieve
    url-retrieve-synchronously)
  "Process and network primitives forbidden outside the private transport.")

(defun hey-build-read-forms (file)
  "Read and return every top-level Lisp form in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (let (forms form)
      (condition-case nil
          (while t
            (setq form (read (current-buffer)))
            (push form forms))
        (end-of-file))
      (nreverse forms))))

(defun hey-build-form-calls (form)
  "Return unquoted function-position symbols contained in FORM."
  (let (calls)
    (cl-labels ((walk
                 (value)
                 (when (consp value)
                   (unless (memq (car value) '(quote function))
                     (when (symbolp (car value))
                       (push (car value) calls))
                     (mapc #'walk (cdr value))))))
      (walk form))
    (delete-dups calls)))

(defun hey-build-function-call-graph (forms)
  "Return a function call graph for top-level defuns in FORMS."
  (let (graph)
    (dolist (form forms (nreverse graph))
      (when (eq (car-safe form) 'defun)
        (push (cons (nth 1 form)
                    (hey-build-form-calls (cdddr form)))
              graph)))))

(defun hey-build-reaches-p (from target graph &optional seen)
  "Return non-nil when FROM can reach TARGET in call GRAPH.
SEEN contains functions already visited during recursion."
  (if (eq from target)
      t
    (unless (memq from seen)
      (cl-some (lambda (callee)
                 (hey-build-reaches-p
                  callee target graph (cons from seen)))
               (cdr (assq from graph))))))

(let* ((cli-file (hey-build-path "hey-cli.el"))
       (cli-forms (hey-build-read-forms cli-file))
       (graph (hey-build-function-call-graph cli-forms))
       (allowed-operations (mapcar #'car hey-build-read-operations)))
  (dolist (pair hey-build-read-operations)
    (pcase-let ((`(,operation . ,builder) pair))
      (unless (assq operation graph)
        (error "Missing named read operation: %s" operation))
      (unless (assq builder graph)
        (error "Missing pure command builder: %s" builder))
      (unless (hey-build-reaches-p operation builder graph)
        (error "%s does not reach its frozen builder %s" operation builder))
      (when (hey-build-reaches-p builder 'hey-cli--start-process graph)
        (error "Builder reaches subprocess transport: %s" builder))))
  (unless (assq 'hey-cli--start-process graph)
    (error "Missing private process primitive hey-cli--start-process"))
  (unless (memq 'make-process (cdr (assq 'hey-cli--start-process graph)))
    (error "Private process primitive does not call make-process"))
  (dolist (entry graph)
    (let ((name (car entry))
          (calls (cdr entry)))
      (dolist (primitive hey-build-process-primitives)
        (when (and (memq primitive calls)
                   (not (and (eq name 'hey-cli--start-process)
                             (memq primitive '(make-pipe-process
                                               make-process)))))
          (error "%s calls forbidden process primitive %s" name primitive)))
      (when (and (string-prefix-p "hey-cli-" (symbol-name name))
                 (not (string-prefix-p "hey-cli--" (symbol-name name)))
                 (hey-build-reaches-p name 'hey-cli--start-process graph)
                 (not (memq name allowed-operations)))
        (error "Public function reaches transport outside allowlist: %s" name))))
  (dolist (file '("hey-model.el" "hey.el"))
    (dolist (form (hey-build-read-forms (hey-build-path file)))
      (dolist (primitive hey-build-process-primitives)
        (when (memq primitive (hey-build-form-calls form))
          (error "%s contains forbidden process primitive %s"
                 file primitive)))))
  (message "Closed read-operation process boundary verified"))
