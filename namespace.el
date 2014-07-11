;;; namespace.el --- C++-like namespaces for emacs-lisp. Avoids name clobbering.

;; Copyright (C) 2014 Artur Malabarba <bruce.connor.am@gmail.com>

;; Author: Artur Malabarba <bruce.connor.am@gmail.com>
;; URL: http://github.com/Bruce-Connor/namespace
;; Version: 0.1a
;; Keywords:
;; Prefix: namespace
;; Separator: -

;;; Commentary:
;;
;; 

;;; Instructions:
;;
;; INSTALLATION
;;
;; This package is available fom Melpa, you may install it by calling
;; M-x package-install.
;;
;; Alternatively, you can download it manually, place it in your
;; `load-path' and require it with
;;
;;     (require 'namespace)

;;; License:
;;
;; This file is NOT part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 2
;; of the License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;; 

;;; Change Log:
;; 0.1a - 2014/05/20 - Created File.
;;; Code:


(defconst namespace-version "0.1a" "Version of the namespace.el package.")

(defvar namespace--name nil)
(defvar namespace--bound nil)
(defvar namespace--fbound nil)

(defvar namespace--keywords nil
  "Keywords that were passed to the current namespace.

:let-vars")

(defvar namespace--local-vars nil
  "Non-global vars that are let/lambda bound at the moment.
These won't be namespaced, as local takes priority over namespace.")

;;;###autoload
(defmacro namespace (name &rest body)
  "Execute BODY inside the namespace NAME.
NAME can be any symbol (not quoted), but it's highly recommended
to use some form of separator (such as on of : / -).

This has two main effects:

1. Any definitions inside BODY will have NAME prepended to the
symbol given. Ex:
    (namespace foo:
    (defvar bar 1 \"docs\")
    )
expands to
    (defvar foo:bar 1 \"docs\")


2. Any function calls and variable names get NAME prepended to
them if possible. Ex:
    (namespace foo:
    (message \"%s\" my-var)
    )
expands to
    (foo:message \"%s\" foo:my-var)
but only if `foo:message' has a function definition. Similarly,
`my-var' becomes `foo:my-var', but only if `foo:my-var' has
a variable definition.

If `foo:message' is not a defined function, the above would
expand instead to
    (message \"%s\" foo:my-var)

===============================

Immediately after NAME you may add keywords which customize this
behaviour:

1. :let-vars

   If this is present, variables defined in let forms become
   namespaced (just like defvars). If this is absent, they are
   preserved.

   For example, assuming `foo:mo' has a variable definition, the
   code
      (namespace foo-
      (let ((bar mo)) ...)
      )
   expands to
      (let ((bar foo-mo)) ...)
   while
      (namespace foo- :let-vars
      (let ((bar mo)) ...)
      )
   expands to
      (let ((foo-bar foo-mo)) ...)

\(fn NAME [KEYWORDS] BODY)"
  (declare (indent (lambda (&rest x) 0)))
  (let ((namespace--name name)
        (namespace--keywords))
    (while (keywordp (car-safe body))
      (push (car-safe body) namespace--keywords)
      (!cdr body))
    (cons 'progn (mapcar 'namespace-convert-form body))))

;;;###autoload
(defun namespace-convert-form (form)
  "Do namespace conversion on FORM.
FORM is any legal elisp form.
Namespace name is defined by the global variable
`namespace--name'."
  (cond
   ((null form) form)
   ;; Function calls
   ((listp form)
    (let ((kar (car form)))
      (when (namespace--defvar-p kar)
        (add-to-list 'namespace--bound (cadr form)))
      (cond ;; Special forms:
       ;; Namespaced Functions
       ((namespace--fboundp kar)
        (let ((name (namespace--prepend kar)))
          (if (macrop name)
              (namespace-convert-form (macroexpand (cons name (cdr form))))
            (cons name
                  (mapcar 'namespace-convert-form (cdr form))))))
       ;; Functions-like forms that get special handling
       ;; That's anything with a namespace--convert-%s function defined
       ;; Currently they are quote/function, lambda, let, cond
       ((fboundp (intern (format "namespace--convert-%s" kar)))
        (funcall (intern (format "namespace--convert-%s" kar)) form))
       ;; Macros
       ((macrop kar)
        (namespace-convert-form (macroexpand form)))
       ;; General functions
       (t (cons kar (mapcar 'namespace-convert-form (cdr form)))))))
   ;; Variables
   ((symbolp form)
    (if (namespace--boundp form)
        (namespace--prepend form)
      form))
   ;; Values
   (t form)))

(defun namespace--convert-defalias (form)
  "Special treatment for defalias FORM."
  (let ((name (ignore-errors (eval (cadr form)))))
    (add-to-list 'namespace--fbound name)
    (list
     (car form)
     (list 'quote (namespace--prepend name))
     (namespace-convert-form (cadr (cdr form))))))

(defun namespace--convert-quote (form)
  "Special treatment for quote/function FORM."
  (let ((kadr (cadr form)))
    (if (or (symbolp kadr) (eq (car-safe kadr) lambda) (macrop kadr))
        (list (car form) (namespace-convert-form kadr))
      form)))

(defun namespace--convert-lambda (form)
  "Special treatment for lambda FORM."
  (let ((namespace--local-vars
         (append (remove '&rest (remove '&optional (cadr form)))
                 namespace--local-vars))
        (forms (cdr (cdr form))))
    (append
     (list (car form)
           (cadr form))
     (when (stringp (car forms))
       (let ((out (car forms)))
         (!cdr forms)
         (list out)))
     (when (eq 'interactive (car-safe (car forms)))
       (let ((out (car forms)))
         (!cdr forms)
         (list (cons (car out) (mapcar 'namespace-convert-form (cdr out))))))
     (mapcar 'namespace-convert-form forms))))

(defun namespace--let-var-convert-then-add (sym add)
  "Try to convert SYM if :let-vars is in use.
If ADD is non-nil, add resulting symbol to `namespace--local-vars'."
  (let ((name (if (memq :let-vars namespace--keywords)
                  (namespace-convert-form sym)
                sym)))
    (when add (add-to-list 'namespace--local-vars name))
    name))

(defun namespace--convert-let (form &optional star)
  "Special treatment for let FORM.
If STAR is non-nil, parse as a `let*'."
  (let* ((namespace--local-vars namespace--local-vars)
         (vars
          (mapcar
           (lambda (x)
             (if (car-safe x)
                 (list (namespace--let-var-convert-then-add (car x) star)
                       (namespace-convert-form (cadr x)))
               (namespace--let-var-convert-then-add x star)))
           (cadr form))))
    ;; Each var defined in a regular `let' only becomes protected after
    ;; all others have been defined.
    (unless star
      (setq namespace--local-vars
            (append
             (mapcar (lambda (x) (or (car-safe x) x)) vars)
             namespace--local-vars)))
    (append
     (list (car form) vars)
     (mapcar 'namespace-convert-form (cddr form)))))

(defun namespace--convert-let* (form)
  "Special treatment for let FORM."
  (namespace--convert-let form t))

(defun namespace--convert-cond (form)
  "Special treatment for cond FORM."
  (cons
   (car form)
   (mapcar
    (lambda (x)
      (cons (namespace-convert-form (car x))
            (mapcar 'namespace-convert-form (cdr x))))
    (cdr form))))

(defun namespace--quote-p (sbl)
  "Is SBL a function which quotes its argument?"
  (member sbl '(quote function lambda)))

(defun namespace--defvar-p (sbl)
  "Is SBL a function which defines variables?"
  (member sbl '(defvar defvaralias defvar-local defconst defcustom defstruct)))

(defun namespace--defun-p (sbl)
  "Is SBL a function which defines functions?"
  (member sbl '(defun defmacro defmacro* defalias defsubst defsubst*)))

(defun namespace--fboundp (sbl)
  "Is namespace+SBL a fboundp symbol?"
  (or (member sbl namespace--fbound)
      (fboundp (namespace--prepend sbl))))

(defun namespace--boundp (sbl)
  "Is namespace+SBL a boundp symbol?
If SBL has a let binding, that takes precendence so this also
returns nil."
  (and (null (member sbl namespace--local-vars))
       (or (member sbl namespace--bound)
           (boundp (namespace--prepend sbl)))))

(defmacro namespace--prepend (sbl)
  "Return namespace+SBL."
  `(intern (format "%s%s" namespace--name ,sbl)))

;;; TODO: This isn't actually used.
(defun namespace--convert (sbl pred)
  "Convert SBL to namespace+SBL, if (PRED SBL) is non-nil."
  (if (funcall pred sbl)
      (namespace--prepend sbl)
    sbl))

(provide 'namespace)

;;; namespace.el ends here.


