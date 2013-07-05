;;; compiler.lisp ---

;; Copyright (C) 2012, 2013 David Vazquez
;; Copyright (C) 2012 Raimon Grau

;; JSCL is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; JSCL is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with JSCL.  If not, see <http://www.gnu.org/licenses/>.

;;;; Compiler

(/debug "loading compiler.lisp!")

(define-js-macro selfcall (&body body)
  `(call (function () ,@body)))

(define-js-macro bool (expr)
  `(if ,expr ,(ls-compile t) ,(ls-compile nil)))

;;; Translate the Lisp code to Javascript. It will compile the special
;;; forms. Some primitive functions are compiled as special forms
;;; too. The respective real functions are defined in the target (see
;;; the beginning of this file) as well as some primitive functions.

(defun interleave (list element &optional after-last-p)
  (unless (null list)
    (with-collect
      (collect (car list))
      (dolist (x (cdr list))
        (collect element)
        (collect x))
      (when after-last-p
        (collect element)))))

(defun code (&rest args)
  (mapconcat (lambda (arg)
               (cond
                 ((null arg) "")
                 ((integerp arg) (integer-to-string arg))
                 ((floatp arg) (float-to-string arg))
                 ((stringp arg) arg)
                 (t
                  (with-output-to-string (*standard-output*)
                    (js-expr arg)))))
             args))

;;; Like CODE, but prefix each line with four spaces. Two versions
;;; of this function are available, because the Ecmalisp version is
;;; very slow and bootstraping was annoying.

;;; A Form can return a multiple values object calling VALUES, like
;;; values(arg1, arg2, ...). It will work in any context, as well as
;;; returning an individual object. However, if the special variable
;;; `*multiple-value-p*' is NIL, is granted that only the primary
;;; value will be used, so we can optimize to avoid the VALUES
;;; function call.
(defvar *multiple-value-p* nil)

;;; Environment

(def!struct binding
  name
  type
  value
  declarations)

(def!struct lexenv
  variable
  function
  block
  gotag)

(defun lookup-in-lexenv (name lexenv namespace)
  (find name (ecase namespace
                (variable (lexenv-variable lexenv))
                (function (lexenv-function lexenv))
                (block    (lexenv-block    lexenv))
                (gotag    (lexenv-gotag    lexenv)))
        :key #'binding-name))

(defun push-to-lexenv (binding lexenv namespace)
  (ecase namespace
    (variable (push binding (lexenv-variable lexenv)))
    (function (push binding (lexenv-function lexenv)))
    (block    (push binding (lexenv-block    lexenv)))
    (gotag    (push binding (lexenv-gotag    lexenv)))))

(defun extend-lexenv (bindings lexenv namespace)
  (let ((env (copy-lexenv lexenv)))
    (dolist (binding (reverse bindings) env)
      (push-to-lexenv binding env namespace))))


(defvar *environment* (make-lexenv))
(defvar *variable-counter* 0)

(defun gvarname (symbol)
  (declare (ignore symbol))
  (incf *variable-counter*)
  (concat "v" (integer-to-string *variable-counter*)))

(defun translate-variable (symbol)
  (awhen (lookup-in-lexenv symbol *environment* 'variable)
    (binding-value it)))

(defun extend-local-env (args)
  (let ((new (copy-lexenv *environment*)))
    (dolist (symbol args new)
      (let ((b (make-binding :name symbol :type 'variable :value (gvarname symbol))))
        (push-to-lexenv b new 'variable)))))

;;; Toplevel compilations
(defvar *toplevel-compilations* nil)

(defun toplevel-compilation (string)
  (push string *toplevel-compilations*))

(defun get-toplevel-compilations ()
  (reverse *toplevel-compilations*))

(defun %compile-defmacro (name lambda)
  (toplevel-compilation (ls-compile `',name))
  (let ((binding (make-binding :name name :type 'macro :value lambda)))
    (push-to-lexenv binding  *environment* 'function))
  name)

(defun global-binding (name type namespace)
  (or (lookup-in-lexenv name *environment* namespace)
      (let ((b (make-binding :name name :type type :value nil)))
        (push-to-lexenv b *environment* namespace)
        b)))

(defun claimp (symbol namespace claim)
  (let ((b (lookup-in-lexenv symbol *environment* namespace)))
    (and b (member claim (binding-declarations b)))))

(defun !proclaim (decl)
  (case (car decl)
    (special
     (dolist (name (cdr decl))
       (let ((b (global-binding name 'variable 'variable)))
         (push 'special (binding-declarations b)))))
    (notinline
     (dolist (name (cdr decl))
       (let ((b (global-binding name 'function 'function)))
         (push 'notinline (binding-declarations b)))))
    (constant
     (dolist (name (cdr decl))
       (let ((b (global-binding name 'variable 'variable)))
         (push 'constant (binding-declarations b)))))))

#+jscl
(fset 'proclaim #'!proclaim)

(defun %define-symbol-macro (name expansion)
  (let ((b (make-binding :name name :type 'macro :value expansion)))
    (push-to-lexenv b *environment* 'variable)
    name))

#+jscl
(defmacro define-symbol-macro (name expansion)
  `(%define-symbol-macro ',name ',expansion))


;;; Special forms

(defvar *compilations* nil)

(defmacro define-compilation (name args &body body)
  ;; Creates a new primitive `name' with parameters args and
  ;; @body. The body can access to the local environment through the
  ;; variable *ENVIRONMENT*.
  `(push (list ',name (lambda ,args (block ,name ,@body)))
         *compilations*))

(define-compilation if (condition true &optional false)
  `(if (!== ,(ls-compile condition) ,(ls-compile nil))
       ,(ls-compile true *multiple-value-p*)
       ,(ls-compile false *multiple-value-p*)))

(defvar *ll-keywords* '(&optional &rest &key))

(defun list-until-keyword (list)
  (if (or (null list) (member (car list) *ll-keywords*))
      nil
      (cons (car list) (list-until-keyword (cdr list)))))

(defun ll-section (keyword ll)
  (list-until-keyword (cdr (member keyword ll))))

(defun ll-required-arguments (ll)
  (list-until-keyword ll))

(defun ll-optional-arguments-canonical (ll)
  (mapcar #'ensure-list (ll-section '&optional ll)))

(defun ll-optional-arguments (ll)
  (mapcar #'car (ll-optional-arguments-canonical ll)))

(defun ll-rest-argument (ll)
  (let ((rest (ll-section '&rest ll)))
    (when (cdr rest)
      (error "Bad lambda-list `~S'." ll))
    (car rest)))

(defun ll-keyword-arguments-canonical (ll)
  (flet ((canonicalize (keyarg)
	   ;; Build a canonical keyword argument descriptor, filling
	   ;; the optional fields. The result is a list of the form
	   ;; ((keyword-name var) init-form svar).
           (let ((arg (ensure-list keyarg)))
             (cons (if (listp (car arg))
                       (car arg)
                       (list (intern (symbol-name (car arg)) "KEYWORD") (car arg)))
                   (cdr arg)))))
    (mapcar #'canonicalize (ll-section '&key ll))))

(defun ll-keyword-arguments (ll)
  (mapcar (lambda (keyarg) (second (first keyarg)))
	  (ll-keyword-arguments-canonical ll)))

(defun ll-svars (lambda-list)
  (let ((args
         (append
          (ll-keyword-arguments-canonical lambda-list)
          (ll-optional-arguments-canonical lambda-list))))
    (remove nil (mapcar #'third args))))

(defun lambda-name/docstring-wrapper (name docstring code)
  (if (or name docstring)
      `(selfcall
        (var (func ,code))
        ,(when name `(= (get func "fname") ,name))
        ,(when docstring `(= (get func "docstring") ,docstring))
        (return func))
      code))

(defun lambda-check-argument-count
    (n-required-arguments n-optional-arguments rest-p)
  ;; Note: Remember that we assume that the number of arguments of a
  ;; call is at least 1 (the values argument).
  (let ((min n-required-arguments)
        (max (if rest-p 'n/a (+ n-required-arguments n-optional-arguments))))
    (block nil
      ;; Special case: a positive exact number of arguments.
      (when (and (< 0 min) (eql min max))
        (return `(call |checkArgs| |nargs| ,min)))
      ;; General case:
      `(progn
         ,(when (< 0 min)     `(call |checkArgsAtLeast| |nargs| ,min))
         ,(when (numberp max) `(call |checkArgsAtMost|  |nargs| ,max))))))

(defun compile-lambda-optional (ll)
  (let* ((optional-arguments (ll-optional-arguments-canonical ll))
	 (n-required-arguments (length (ll-required-arguments ll)))
	 (n-optional-arguments (length optional-arguments)))
    (when optional-arguments
      `(switch |nargs|
               ,@(with-collect
                  (dotimes (idx n-optional-arguments)
                    (let ((arg (nth idx optional-arguments)))
                      (collect `(case ,(+ idx n-required-arguments)))
                      (collect `(= ,(make-symbol (translate-variable (car arg)))
                                   ,(ls-compile (cadr arg))))
                      (collect (when (third arg)
                                 `(= ,(make-symbol (translate-variable (third arg)))
                                     ,(ls-compile nil))))))
                  (collect 'default)
                  (collect '(break)))))))

(defun compile-lambda-rest (ll)
  (let ((n-required-arguments (length (ll-required-arguments ll)))
	(n-optional-arguments (length (ll-optional-arguments ll)))
	(rest-argument (ll-rest-argument ll)))
    (when rest-argument
      (let ((js!rest (make-symbol (translate-variable rest-argument))))
        `(progn
           (var (,js!rest ,(ls-compile nil)))
           (var i)
           (for ((= i (- |nargs| 1))
                 (>= i ,(+ n-required-arguments n-optional-arguments))
                 (post-- i))
                (= ,js!rest (object "car" (property |arguments| (+ i 2))
                                    "cdr" ,js!rest))))))))

(defun compile-lambda-parse-keywords (ll)
  (let ((n-required-arguments
	 (length (ll-required-arguments ll)))
	(n-optional-arguments
	 (length (ll-optional-arguments ll)))
	(keyword-arguments
	 (ll-keyword-arguments-canonical ll)))
    `(progn
       ;; Declare variables
       ,@(with-collect
          (dolist (keyword-argument keyword-arguments)
            (destructuring-bind ((keyword-name var) &optional initform svar)
                keyword-argument
              (declare (ignore keyword-name initform))
              (collect `(var ,(make-symbol (translate-variable var))))
              (when svar
                (collect
                    `(var (,(make-symbol (translate-variable svar))
                            ,(ls-compile nil))))))))
       
       ;; Parse keywords
       ,(flet ((parse-keyword (keyarg)
                (destructuring-bind ((keyword-name var) &optional initform svar) keyarg
                  ;; ((keyword-name var) init-form svar)
                  `(progn
                     (for ((= i ,(+ n-required-arguments n-optional-arguments))
                           (< i |nargs|)
                           (+= i 2))
                          ;; ....
                          (if (=== (property |arguments| (+ i 2))
                                   ,(ls-compile keyword-name))
                              (progn
                                (= ,(make-symbol (translate-variable var))
                                   (property |arguments| (+ i 3)))
                                ,(when svar `(= ,(make-symbol (translate-variable svar))
                                                ,(ls-compile t)))
                                (break))))
                     (if (== i |nargs|)
                         (= ,(make-symbol (translate-variable var))
                            ,(ls-compile initform)))))))
         (when keyword-arguments
           `(progn
              (var i)
              ,@(mapcar #'parse-keyword keyword-arguments))))
       
       ;; Check for unknown keywords
       ,(when keyword-arguments
         `(progn
            (var (start ,(+ n-required-arguments n-optional-arguments)))
            (if (== (% (- |nargs| start) 2) 1)
                (throw "Odd number of keyword arguments."))
            (for ((= i start) (< i |nargs|) (+= i 2))
                 (if (and ,@(mapcar (lambda (keyword-argument)
                                 (destructuring-bind ((keyword-name var) &optional initform svar)
                                     keyword-argument
                                   (declare (ignore var initform svar))
                                   `(!== (property |arguments| (+ i 2)) ,(ls-compile keyword-name))))
                               keyword-arguments))
                     (throw (+ "Unknown keyword argument "
                               (call |xstring|
                                     (property
                                      (property |arguments| (+ i 2))
                                      "name")))))))))))

(defun parse-lambda-list (ll)
  (values (ll-required-arguments ll)
          (ll-optional-arguments ll)
          (ll-keyword-arguments  ll)
          (ll-rest-argument      ll)))

;;; Process BODY for declarations and/or docstrings. Return as
;;; multiple values the BODY without docstrings or declarations, the
;;; list of declaration forms and the docstring.
(defun parse-body (body &key declarations docstring)
  (let ((value-declarations)
        (value-docstring))
    ;; Parse declarations
    (when declarations
      (do* ((rest body (cdr rest))
            (form (car rest) (car rest)))
           ((or (atom form) (not (eq (car form) 'declare)))
            (setf body rest))
        (push form value-declarations)))
    ;; Parse docstring
    (when (and docstring
               (stringp (car body))
               (not (null (cdr body))))
      (setq value-docstring (car body))
      (setq body (cdr body)))
    (values body value-declarations value-docstring)))

;;; Compile a lambda function with lambda list LL and body BODY. If
;;; NAME is given, it should be a constant string and it will become
;;; the name of the function. If BLOCK is non-NIL, a named block is
;;; created around the body. NOTE: No block (even anonymous) is
;;; created if BLOCk is NIL.
(defun compile-lambda (ll body &key name block)
  (multiple-value-bind (required-arguments
                        optional-arguments
                        keyword-arguments
                        rest-argument)
      (parse-lambda-list ll)
    (multiple-value-bind (body decls documentation)
        (parse-body body :declarations t :docstring t)
      (declare (ignore decls))
      (let ((n-required-arguments (length required-arguments))
            (n-optional-arguments (length optional-arguments))
            (*environment* (extend-local-env
                            (append (ensure-list rest-argument)
                                    required-arguments
                                    optional-arguments
                                    keyword-arguments
                                    (ll-svars ll)))))
        (lambda-name/docstring-wrapper name documentation
         `(function (|values| |nargs| ,@(mapcar (lambda (x)
                                                  (make-symbol (translate-variable x)))
                                                (append required-arguments optional-arguments)))
                     ;; Check number of arguments
                    ,(lambda-check-argument-count n-required-arguments
                                                  n-optional-arguments
                                                  (or rest-argument keyword-arguments))
                    ,(compile-lambda-optional ll)
                    ,(compile-lambda-rest ll)
                    ,(compile-lambda-parse-keywords ll)

                    ,(let ((*multiple-value-p* t))
                          (if block
                              (ls-compile-block `((block ,block ,@body)) t)
                              (ls-compile-block body t)))))))))


(defun setq-pair (var val)
  (let ((b (lookup-in-lexenv var *environment* 'variable)))
    (cond
      ((and b
            (eq (binding-type b) 'variable)
            (not (member 'special (binding-declarations b)))
            (not (member 'constant (binding-declarations b))))
       ;; TODO: Unnecesary make-symbol when codegen migration is
       ;; finished.
       `(= ,(make-symbol (binding-value b)) ,(ls-compile val)))
      ((and b (eq (binding-type b) 'macro))
       (ls-compile `(setf ,var ,val)))
      (t
       (ls-compile `(set ',var ,val))))))


(define-compilation setq (&rest pairs)
  (let ((result nil))
    (when (null pairs)
      (return-from setq (ls-compile nil)))
    (while t
      (cond
	((null pairs)
         (return))
	((null (cdr pairs))
	 (error "Odd pairs in SETQ"))
	(t
         (push `,(setq-pair (car pairs) (cadr pairs)) result)
	 (setq pairs (cddr pairs)))))
    `(progn ,@(reverse result))))


;;; Compilation of literals an object dumping

;;; BOOTSTRAP MAGIC: We record the macro definitions as lists during
;;; the bootstrap. Once everything is compiled, we want to dump the
;;; whole global environment to the output file to reproduce it in the
;;; run-time. However, the environment must contain expander functions
;;; rather than lists. We do not know how to dump function objects
;;; itself, so we mark the list definitions with this object and the
;;; compiler will be called when this object has to be dumped.
;;; Backquote/unquote does a similar magic, but this use is exclusive.
;;;
;;; Indeed, perhaps to compile the object other macros need to be
;;; evaluated. For this reason we define a valid macro-function for
;;; this symbol.
(defvar *magic-unquote-marker* (gensym "MAGIC-UNQUOTE"))

#-jscl
(setf (macro-function *magic-unquote-marker*)
      (lambda (form &optional environment)
        (declare (ignore environment))
        (second form)))

(defvar *literal-table* nil)
(defvar *literal-counter* 0)

(defun genlit ()
  (incf *literal-counter*)
  (concat "l" (integer-to-string *literal-counter*)))

(defun dump-symbol (symbol)
  #-jscl
  (let ((package (symbol-package symbol)))
    (if (eq package (find-package "KEYWORD"))
        `(new (call |Symbol| ,(dump-string (symbol-name symbol)) ,(dump-string (package-name package))))
        `(new (call |Symbol| ,(dump-string (symbol-name symbol))))))
  #+jscl
  (let ((package (symbol-package symbol)))
    (if (null package)
        `(new (call |Symbol| ,(dump-string (symbol-name symbol))))
        (ls-compile `(intern ,(symbol-name symbol) ,(package-name package))))))

(defun dump-cons (cons)
  (let ((head (butlast cons))
        (tail (last cons)))
    `(call |QIList|
           ,@(mapcar (lambda (x) (literal x t)) head)
           ,(literal (car tail) t)
           ,(literal (cdr tail) t))))

(defun dump-array (array)
  (let ((elements (vector-to-list array)))
    (list-to-vector (mapcar #'literal elements))))

(defun dump-string (string)
  `(call |make_lisp_string| ,string))

(defun literal (sexp &optional recursive)
  (cond
    ((integerp sexp) sexp)
    ((floatp sexp) sexp)
    ((characterp sexp)
     ;; TODO: Remove selfcall after migration
     `(selfcall (return ,(string sexp))))
    (t
     (or (cdr (assoc sexp *literal-table* :test #'eql))
         (let ((dumped (typecase sexp
                         (symbol (dump-symbol sexp))
                         (string (dump-string sexp))
                         (cons
                          ;; BOOTSTRAP MAGIC: See the root file
                          ;; jscl.lisp and the function
                          ;; `dump-global-environment' for futher
                          ;; information.
                          (if (eq (car sexp) *magic-unquote-marker*)
                              (ls-compile (second sexp))
                              (dump-cons sexp)))
                         (array (dump-array sexp)))))
           (if (and recursive (not (symbolp sexp)))
               dumped
               (let ((jsvar (genlit)))
                 (push (cons sexp (make-symbol jsvar)) *literal-table*)
                 (toplevel-compilation `(var (,(make-symbol jsvar) ,dumped)))
                 (when (keywordp sexp)
                   (toplevel-compilation `(= ,(get (make-symbol jsvar) "value") ,(make-symbol jsvar))))
                 (make-symbol jsvar))))))))


(define-compilation quote (sexp)
  (literal sexp))

(define-compilation %while (pred &rest body)
  `(selfcall
    (while (!== ,(ls-compile pred) ,(ls-compile nil))
      0                                 ; TODO: Force
                                        ; braces. Unnecesary when code
                                        ; is gone
      ,(ls-compile-block body))
    (return ,(ls-compile nil))))

(define-compilation function (x)
  (cond
    ((and (listp x) (eq (car x) 'lambda))
     (compile-lambda (cadr x) (cddr x)))
    ((and (listp x) (eq (car x) 'named-lambda))
     (destructuring-bind (name ll &rest body) (cdr x)
       (compile-lambda ll body
                       :name (symbol-name name)
                       :block name)))
    ((symbolp x)
     (let ((b (lookup-in-lexenv x *environment* 'function)))
       (if b
	   (make-symbol (binding-value b))
	   (ls-compile `(symbol-function ',x)))))))

(defun make-function-binding (fname)
  (make-binding :name fname :type 'function :value (gvarname fname)))

(defun compile-function-definition (list)
  (compile-lambda (car list) (cdr list)))

(defun translate-function (name)
  (let ((b (lookup-in-lexenv name *environment* 'function)))
    (and b (binding-value b))))

(define-compilation flet (definitions &rest body)
  (let* ((fnames (mapcar #'car definitions))
         (cfuncs (mapcar (lambda (def)
                           (compile-lambda (cadr def)
                                           `((block ,(car def)
                                               ,@(cddr def)))))
                         definitions))
         (*environment*
          (extend-lexenv (mapcar #'make-function-binding fnames)
                         *environment*
                         'function)))
    `(call (function ,(mapcar #'make-symbol (mapcar #'translate-function fnames))
                ,(ls-compile-block body t))
           ,@cfuncs)))

(define-compilation labels (definitions &rest body)
  (let* ((fnames (mapcar #'car definitions))
	 (*environment*
          (extend-lexenv (mapcar #'make-function-binding fnames)
                         *environment*
                         'function)))
    `(selfcall
      ,@(mapcar (lambda (func)
                  `(var (,(make-symbol (translate-function (car func)))
                          ,(compile-lambda (cadr func)
                                           `((block ,(car func) ,@(cddr func)))))))
                definitions)
      ,(ls-compile-block body t))))


(defvar *compiling-file* nil)
(define-compilation eval-when-compile (&rest body)
  (if *compiling-file*
      (progn
        (eval (cons 'progn body))
        (ls-compile 0))
      (ls-compile `(progn ,@body))))

(defmacro define-transformation (name args form)
  `(define-compilation ,name ,args
     (ls-compile ,form)))

(define-compilation progn (&rest body)
  (if (null (cdr body))
      (ls-compile (car body) *multiple-value-p*)
      `(progn
         ,@(append (mapcar #'ls-compile (butlast body))
                   (list (ls-compile (car (last body)) t))))))

(define-compilation macrolet (definitions &rest body)
  (let ((*environment* (copy-lexenv *environment*)))
    (dolist (def definitions)
      (destructuring-bind (name lambda-list &body body) def
        (let ((binding (make-binding :name name :type 'macro :value
                                     (let ((g!form (gensym)))
                                       `(lambda (,g!form)
                                          (destructuring-bind ,lambda-list ,g!form
                                            ,@body))))))
          (push-to-lexenv binding  *environment* 'function))))
    (ls-compile `(progn ,@body) *multiple-value-p*)))


(defun special-variable-p (x)
  (and (claimp x 'variable 'special) t))

;;; Wrap CODE to restore the symbol values of the dynamic
;;; bindings. BINDINGS is a list of pairs of the form
;;; (SYMBOL . PLACE),  where PLACE is a Javascript variable
;;; name to initialize the symbol value and where to stored
;;; the old value.
(defun let-binding-wrapper (bindings body)
  (when (null bindings)
    (return-from let-binding-wrapper body))
  `(progn
     (try (var tmp)
          ,@(with-collect
             (dolist (b bindings)
               (let ((s (ls-compile `',(car b))))
                 (collect `(= tmp (get ,s "value")))
                 (collect `(= (get ,s "value") ,(cdr b)))
                 (collect `(= ,(cdr b) tmp)))))
          ,body)
     (finally
      ,@(with-collect
         (dolist (b bindings)
           (let ((s (ls-compile `(quote ,(car b)))))
             (collect `(= (get ,s "value") ,(cdr b)))))))))

(define-compilation let (bindings &rest body)
  (let* ((bindings (mapcar #'ensure-list bindings))
         (variables (mapcar #'first bindings))
         (cvalues (mapcar #'ls-compile (mapcar #'second bindings)))
         (*environment* (extend-local-env (remove-if #'special-variable-p variables)))
         (dynamic-bindings))
    `(call (function ,(mapcar (lambda (x)
                                (if (special-variable-p x)
                                    (let ((v (gvarname x)))
                                      (push (cons x (make-symbol v)) dynamic-bindings)
                                      (make-symbol v))
                                    (make-symbol (translate-variable x))))
                              variables)
                     ,(let ((body (ls-compile-block body t t)))
                           `,(let-binding-wrapper dynamic-bindings body)))
           ,@cvalues)))


;;; Return the code to initialize BINDING, and push it extending the
;;; current lexical environment if the variable is not special.
(defun let*-initialize-value (binding)
  (let ((var (first binding))
        (value (second binding)))
    (if (special-variable-p var)
        (ls-compile `(setq ,var ,value))
        (let* ((v (gvarname var))
               (b (make-binding :name var :type 'variable :value v)))
          (prog1 `(var (,(make-symbol v) ,(ls-compile value)))
            (push-to-lexenv b *environment* 'variable))))))

;;; Wrap BODY to restore the symbol values of SYMBOLS after body. It
;;; DOES NOT generate code to initialize the value of the symbols,
;;; unlike let-binding-wrapper.
(defun let*-binding-wrapper (symbols body)
  (when (null symbols)
    (return-from let*-binding-wrapper body))
  (let ((store (mapcar (lambda (s) (cons s (gvarname s)))
                       (remove-if-not #'special-variable-p symbols))))
    `(progn
       (try
        ,@(mapcar (lambda (b)
                    (let ((s (ls-compile `(quote ,(car b)))))
                      `(var (,(make-symbol (cdr b)) (get ,s "value")))))
                  store)
        ,body)
       (finally
        ,@(mapcar (lambda (b)
                    (let ((s (ls-compile `(quote ,(car b)))))
                      `(= (get ,s "value") ,(make-symbol (cdr b)))))
                  store)))))

(define-compilation let* (bindings &rest body)
  (let ((bindings (mapcar #'ensure-list bindings))
        (*environment* (copy-lexenv *environment*)))
    (let ((specials (remove-if-not #'special-variable-p (mapcar #'first bindings)))
          (body `(progn
                   ,@(mapcar #'let*-initialize-value bindings)
                   ,(ls-compile-block body t t))))
      `(selfcall ,(let*-binding-wrapper specials body)))))


(define-compilation block (name &rest body)
  ;; We use Javascript exceptions to implement non local control
  ;; transfer. Exceptions has dynamic scoping, so we use a uniquely
  ;; generated object to identify the block. The instance of a empty
  ;; array is used to distinguish between nested dynamic Javascript
  ;; exceptions. See https://github.com/davazp/jscl/issues/64 for
  ;; futher details.
  (let* ((idvar (gvarname name))
         (b (make-binding :name name :type 'block :value idvar)))
    (when *multiple-value-p*
      (push 'multiple-value (binding-declarations b)))
    (let* ((*environment* (extend-lexenv (list b) *environment* 'block))
           (cbody (ls-compile-block body t)))
      (if (member 'used (binding-declarations b))
          `(selfcall
            (try
             (var (,(make-symbol idvar) #()))
             ,cbody)
            (catch (cf)
              (if (and (== (get cf "type") "block")
                       (== (get cf "id") ,(make-symbol idvar)))
                  ,(if *multiple-value-p*
                       `(return (call (get |values| "apply") this (call |forcemv| (get cf "values"))))
                       `(return (get cf "values")))
                  (throw cf))))
          ;; TODO: is selfcall necessary here?
          `(selfcall ,cbody)))))

(define-compilation return-from (name &optional value)
  (let* ((b (lookup-in-lexenv name *environment* 'block))
         (multiple-value-p (member 'multiple-value (binding-declarations b))))
    (when (null b)
      (error "Return from unknown block `~S'." (symbol-name name)))
    (push 'used (binding-declarations b))
    ;; The binding value is the name of a variable, whose value is the
    ;; unique identifier of the block as exception. We can't use the
    ;; variable name itself, because it could not to be unique, so we
    ;; capture it in a closure.
    `(selfcall
      ,(when multiple-value-p `(var (|values| |mv|)))
      (throw
          (object
           "type" "block"
           "id" ,(make-symbol (binding-value b))
           "values" ,(ls-compile value multiple-value-p)
           "message" ,(concat "Return from unknown block '" (symbol-name name) "'."))))))

(define-compilation catch (id &rest body)
  `(selfcall
    (var (|id| ,(ls-compile id)))
    (try
     ,(ls-compile-block body t))
    (catch (|cf|)
      (if (and (== (get |cf| "type") "catch")
               (== (get |cf| "id") |id|))
          ,(if *multiple-value-p*
               `(return (call (get |values| "apply")
                              this
                              (call |forcemv| (get |cf| "values"))))
               `(return (call (get |pv| "apply")
                              this
                              (call |forcemv| (get |cf| "values")))))
          (throw |cf|)))))

(define-compilation throw (id value)
  `(selfcall
    (var (|values| |mv|))
    (throw (object
            |type| "catch"
            |id| ,(ls-compile id)
            |values| ,(ls-compile value t)
            |message| "Throw uncatched."))))

(defun go-tag-p (x)
  (or (integerp x) (symbolp x)))

(defun declare-tagbody-tags (tbidx body)
  (let* ((go-tag-counter 0)
         (bindings
          (mapcar (lambda (label)
                    (let ((tagidx (incf go-tag-counter)))
                      (make-binding :name label :type 'gotag :value (list tbidx tagidx))))
                  (remove-if-not #'go-tag-p body))))
    (extend-lexenv bindings *environment* 'gotag)))

(define-compilation tagbody (&rest body)
  ;; Ignore the tagbody if it does not contain any go-tag. We do this
  ;; because 1) it is easy and 2) many built-in forms expand to a
  ;; implicit tagbody, so we save some space.
  (unless (some #'go-tag-p body)
    (return-from tagbody (ls-compile `(progn ,@body nil))))
  ;; The translation assumes the first form in BODY is a label
  (unless (go-tag-p (car body))
    (push (gensym "START") body))
  ;; Tagbody compilation
  (let ((branch (gvarname 'branch))
        (tbidx (gvarname 'tbidx)))
    (let ((*environment* (declare-tagbody-tags tbidx body))
          initag)
      (let ((b (lookup-in-lexenv (first body) *environment* 'gotag)))
        (setq initag (second (binding-value b))))
      `(selfcall
        ;; TAGBODY branch to take
        (var (,(make-symbol branch) ,initag))
        (var (,(make-symbol tbidx) #()))
        (label tbloop
               (while true
                 (try
                  (switch ,(make-symbol branch)
                          ,@(with-collect
                             (collect `(case ,initag))
                             (dolist (form (cdr body))
                               (if (go-tag-p form)
                                   (let ((b (lookup-in-lexenv form *environment* 'gotag)))
                                     (collect `(case ,(second (binding-value b)))))
                                   (collect (ls-compile form)))))
                          default
                          (break tbloop)))
                 (catch (jump)
                   (if (and (== (get jump "type") "tagbody")
                            (== (get jump "id") ,(make-symbol tbidx)))
                       (= ,(make-symbol branch) (get jump "label"))
                       (throw jump)))))
        (return ,(ls-compile nil))))))

(define-compilation go (label)
  (let ((b (lookup-in-lexenv label *environment* 'gotag))
        (n (cond
             ((symbolp label) (symbol-name label))
             ((integerp label) (integer-to-string label)))))
    (when (null b)
      (error "Unknown tag `~S'" label))
    `(selfcall
      (throw
          (object
           "type" "tagbody"
           "id" ,(make-symbol (first (binding-value b)))
           "label" ,(second (binding-value b))
           "message" ,(concat "Attempt to GO to non-existing tag " n))))))

(define-compilation unwind-protect (form &rest clean-up)
  `(selfcall
    (var (|ret| ,(ls-compile nil)))
    (try
     (= |ret| ,(ls-compile form)))
    (finally
     ,(ls-compile-block clean-up))
    (return |ret|)))

(define-compilation multiple-value-call (func-form &rest forms)
  `(selfcall
    (var (func ,(ls-compile func-form)))
    (var (args ,(vector (if *multiple-value-p* '|values| '|pv|) 0)))
    (return
      (selfcall
       (var (|values| |mv|))
       (var vs)
       (progn
         ,@(with-collect
            (dolist (form forms)
              (collect `(= vs ,(ls-compile form t)))
              (collect `(if (and (=== (typeof vs) "object")
                                 (in "multiple-value" vs))
                            (= args (call (get args "concat") vs))
                            (call (get args "push") vs))))))
       (= (property args 1) (- (property args "length") 2))
       (return (call (get func "apply") |window| args))))))

(define-compilation multiple-value-prog1 (first-form &rest forms)
  `(selfcall
    (var (args ,(ls-compile first-form *multiple-value-p*)))
    ;; TODO: Interleave is temporal
    (progn ,@(mapcar #'ls-compile forms))
    (return args)))

(define-transformation backquote (form)
  (bq-completely-process form))


;;; Primitives

(defvar *builtins* nil)

(defmacro define-raw-builtin (name args &body body)
  ;; Creates a new primitive function `name' with parameters args and
  ;; @body. The body can access to the local environment through the
  ;; variable *ENVIRONMENT*.
  `(push (list ',name (lambda ,args (block ,name ,@body)))
         *builtins*))

(defmacro define-builtin (name args &body body)
  `(define-raw-builtin ,name ,args
     (let ,(mapcar (lambda (arg) `(,arg (ls-compile ,arg))) args)
       ,@body)))

;;; VARIABLE-ARITY compiles variable arity operations. ARGS stands for
;;; a variable which holds a list of forms. It will compile them and
;;; store the result in some Javascript variables. BODY is evaluated
;;; with ARGS bound to the list of these variables to generate the
;;; code which performs the transformation on these variables.
(defun variable-arity-call (args function)
  (unless (consp args)
    (error "ARGS must be a non-empty list"))
  (let ((counter 0)
        (fargs '())
        (prelude '()))
    (dolist (x args)
      (if (or (floatp x) (numberp x))
          (push x fargs)
          (let ((v (make-symbol (concat "x" (integer-to-string (incf counter))))))
            (push v fargs)
            (push `(var (,v ,(ls-compile x)))
                  prelude)
            (push `(if (!= (typeof ,v) "number")
                       (throw "Not a number!"))
                  prelude))))
    `(selfcall
      (progn ,@(reverse prelude))
      ,(funcall function (reverse fargs)))))


(defmacro variable-arity (args &body body)
  (unless (symbolp args)
    (error "`~S' is not a symbol." args))
  `(variable-arity-call ,args (lambda (,args) `(return  ,,@body))))

(define-raw-builtin + (&rest numbers)
  (if (null numbers)
      0
      (variable-arity numbers
        `(+ ,@numbers))))

(define-raw-builtin - (x &rest others)
  (let ((args (cons x others)))
    (variable-arity args `(- ,@args))))

(define-raw-builtin * (&rest numbers)
  (if (null numbers)
      1
      (variable-arity numbers `(* ,@numbers))))

(define-raw-builtin / (x &rest others)
  (let ((args (cons x others)))
    (variable-arity args
      (if (null others)
          `(/ 1 ,(car args))
          (reduce (lambda (x y) `(/ ,x ,y))
                  args)))))

(define-builtin mod (x y)
  `(% ,x ,y))


(defun comparison-conjuntion (vars op)
  (cond
    ((null (cdr vars))
     'true)
    ((null (cddr vars))
     `(,op ,(car vars) ,(cadr vars)))
    (t
     `(and (,op ,(car vars) ,(cadr vars))
           ,(comparison-conjuntion (cdr vars) op)))))

(defmacro define-builtin-comparison (op sym)
  `(define-raw-builtin ,op (x &rest args)
     (let ((args (cons x args)))
       (variable-arity args
	 `(bool ,(comparison-conjuntion args ',sym))))))

(define-builtin-comparison > >)
(define-builtin-comparison < <)
(define-builtin-comparison >= >=)
(define-builtin-comparison <= <=)
(define-builtin-comparison = ==)
(define-builtin-comparison /= !=)

(define-builtin numberp (x)
  `(bool (== (typeof ,x) "number")))

(define-builtin floor (x)
  `(call (get |Math| |floor|) ,x))

(define-builtin expt (x y)
  `(call (get |Math| |pow|) ,x ,y))

(define-builtin float-to-string (x)
  `(call |make_lisp_string| (call (get ,x |toString|))))

(define-builtin cons (x y)
  `(object "car" ,x "cdr" ,y))

(define-builtin consp (x)
  `(selfcall
    (var (tmp ,x))
    (return (bool (and (== (typeof tmp) "object")
                       (in "car" tmp))))))

(define-builtin car (x)
  `(selfcall
    (var (tmp ,x))
    (return (if (=== tmp ,(ls-compile nil))
                ,(ls-compile nil)
                (get tmp "car")))))

(define-builtin cdr (x)
  `(selfcall
    (var (tmp ,x))
    (return (if (=== tmp ,(ls-compile nil))
                ,(ls-compile nil)
                (get tmp "cdr")))))

(define-builtin rplaca (x new)
  `(= (get ,x "car") ,new))

(define-builtin rplacd (x new)
  `(= (get ,x "cdr") ,new))

(define-builtin symbolp (x)
  `(bool (instanceof ,x |Symbol|)))

(define-builtin make-symbol (name)
  `(new (call |Symbol| ,name)))

(define-builtin symbol-name (x)
  `(get ,x "name"))

(define-builtin set (symbol value)
  `(= (get ,symbol "value") ,value))

(define-builtin fset (symbol value)
  `(= (get ,symbol "fvalue") ,value))

(define-builtin boundp (x)
  `(bool (!== (get ,x "value") undefined)))

(define-builtin fboundp (x)
  `(bool (!== (get ,x "fvalue") undefined)))

(define-builtin symbol-value (x)
  `(selfcall
    (var (symbol ,x)
         (value (get symbol "value")))
    (if (=== value undefined)
        (throw (+ "Variable `" (call |xstring| (get symbol "name")) "' is unbound.")))
    (return value)))

(define-builtin symbol-function (x)
  `(selfcall
    (var (symbol ,x)
         (func (get symbol "fvalue")))
    (if (=== func undefined)
        (throw (+ "Function `" (call |xstring| (get symbol "name")) "' is undefined.")))
    (return func)))

(define-builtin symbol-plist (x)
  `(or (get ,x "plist") ,(ls-compile nil)))

(define-builtin lambda-code (x)
  `(call |make_lisp_string| (call (get ,x "toString"))))

(define-builtin eq (x y)
  `(bool (=== ,x ,y)))

(define-builtin char-code (x)
  `(call |char_to_codepoint| ,x))

(define-builtin code-char (x)
  `(call |char_from_codepoint| ,x))

(define-builtin characterp (x)
  `(selfcall
    (var (x ,x))
    (return (bool
             (and (== (typeof x) "string")
                  (or (== (get x "length") 1)
                      (== (get x "length") 2)))))))

(define-builtin char-upcase (x)
  `(call |safe_char_upcase| ,x))

(define-builtin char-downcase (x)
  `(call |safe_char_downcase| ,x))

(define-builtin stringp (x)
  `(selfcall
    (var (x ,x))
    (return (bool
             (and (and (===(typeof x) "object")
                       (in "length" x))
                  (== (get x "stringp") 1))))))

(define-raw-builtin funcall (func &rest args)
  `(selfcall
    (var (f ,(ls-compile func)))
    (return (call (if (=== (typeof f) "function")
                      f
                      (get f "fvalue"))
                  ,@(list* (if *multiple-value-p* '|values| '|pv|)
                           (length args)
                           (mapcar #'ls-compile args))))))

(define-raw-builtin apply (func &rest args)
  (if (null args)
      (ls-compile func)
      (let ((args (butlast args))
            (last (car (last args))))
        `(selfcall
           (var (f ,(ls-compile func)))
           (var (args ,(list-to-vector
                        (list* (if *multiple-value-p* '|values| '|pv|)
                               (length args)
                               (mapcar #'ls-compile args)))))
           (var (tail ,(ls-compile last)))
           (while (!= tail ,(ls-compile nil))
             (call (get args "push") (get tail "car"))
             (post++ (property args 1))
             (= tail (get tail "cdr")))
           (return (call (get (if (=== (typeof f) "function")
                                  f
                                  (get f "fvalue"))
                              "apply")
                         this
                         args))))))

(define-builtin js-eval (string)
  (if *multiple-value-p*
      `(selfcall
        (var (v (call |globalEval| (call |xstring| ,string))))
        (return (call (get |values| "apply") this (call |forcemv| v))))
      `(call |globalEval| (call |xstring| ,string))))

(define-builtin %throw (string)
  `(selfcall (throw ,string)))

(define-builtin functionp (x)
  `(bool (=== (typeof ,x) "function")))

(define-builtin %write-string (x)
  `(call (get |lisp| "write") ,x))

(define-builtin /debug (x)
  `(call (get |console| "log") (call |xstring| ,x)))


;;; Storage vectors. They are used to implement arrays and (in the
;;; future) structures.

(define-builtin storage-vector-p (x)
  `(selfcall
    (var (x ,x))
    (return (bool (and (=== (typeof x) "object") (in "length" x))))))

(define-builtin make-storage-vector (n)
  `(selfcall
    (var (r #()))
    (= (get r "length") ,n)
    (return r)))

(define-builtin storage-vector-size (x)
  `(get ,x "length"))

(define-builtin resize-storage-vector (vector new-size)
  `(= (get ,vector "length") ,new-size))

(define-builtin storage-vector-ref (vector n)
  `(selfcall
    (var (x (property ,vector ,n)))
    (if (=== x undefined) (throw "Out of range."))
    (return x)))

(define-builtin storage-vector-set (vector n value)
  `(selfcall
    (var (x ,vector))
    (var (i ,n))
    (if (or (< i 0) (>= i (get x "length")))
        (throw "Out of range."))
    (return (= (property x i) ,value))))

(define-builtin concatenate-storage-vector (sv1 sv2)
  `(selfcall
     (var (sv1 ,sv1))
     (var (r (call (get sv1 "concat") ,sv2)))
     (= (get r "type") (get sv1 "type"))
     (= (get r "stringp") (get sv1 "stringp"))
     (return r)))

(define-builtin get-internal-real-time ()
  `(call (get (new (call |Date|)) "getTime")))

(define-builtin values-array (array)
  (if *multiple-value-p*
      `(call (get |values| "apply") this ,array)
      `(call (get |pv| "apply") this ,array)))

(define-raw-builtin values (&rest args)
  (if *multiple-value-p*
      `(call |values| ,@(mapcar #'ls-compile args))
      `(call |pv| ,@(mapcar #'ls-compile args))))

;;; Javascript FFI

(define-builtin new ()
  '(object))

(define-raw-builtin oget* (object key &rest keys)
  `(selfcall
    (progn
      (var (tmp (property ,(ls-compile object) (call |xstring| ,(ls-compile key)))))
      ,@(mapcar (lambda (key)
                  `(progn
                     (if (=== tmp undefined) (return ,(ls-compile nil)))
                     (= tmp (property tmp (call |xstring| ,(ls-compile key))))))
                keys))
    (return (if (=== tmp undefined) ,(ls-compile nil) tmp))))

(define-raw-builtin oset* (value object key &rest keys)
  (let ((keys (cons key keys)))
    `(selfcall
      (progn
        (var (obj ,(ls-compile object)))
        ,@(mapcar (lambda (key)
                    `(progn
                       (= obj (property obj (call |xstring| ,(ls-compile key))))
                       (if (=== object undefined)
                           (throw "Impossible to set object property."))))
                  (butlast keys))
        (var (tmp
              (= (property obj (call |xstring| ,(ls-compile (car (last keys)))))
                 ,(ls-compile value))))
        (return (if (=== tmp undefined)
                    ,(ls-compile nil)
                    tmp))))))

(define-raw-builtin oget (object key &rest keys)
  `(call |js_to_lisp| ,(ls-compile `(oget* ,object ,key ,@keys))))

(define-raw-builtin oset (value object key &rest keys)
  (ls-compile `(oset* (lisp-to-js ,value) ,object ,key ,@keys)))

(define-builtin objectp (x)
  `(bool (=== (typeof ,x) "object")))

(define-builtin lisp-to-js (x) `(call |lisp_to_js| ,x))
(define-builtin js-to-lisp (x) `(call |js_to_lisp| ,x))


(define-builtin in (key object)
  `(bool (in (call |xstring| ,key) ,object)))

(define-builtin map-for-in (function object)
  `(selfcall
    (var (f ,function)
         (g (if (=== (typeof f) "function") f (get f "fvalue")))
         (o ,object))
    (for-in (key o)
            (call g ,(if *multiple-value-p* '|values| '|pv|) 1 (get o "key")))
    (return ,(ls-compile nil))))

(define-compilation %js-vref (var)
  `(call |js_to_lisp| ,(make-symbol var)))

(define-compilation %js-vset (var val)
  `(= ,(make-symbol var) (call |lisp_to_js| ,(ls-compile val))))

(define-setf-expander %js-vref (var)
  (let ((new-value (gensym)))
    (unless (stringp var)
      (error "`~S' is not a string." var))
    (values nil
            (list var)
            (list new-value)
            `(%js-vset ,var ,new-value)
            `(%js-vref ,var))))


#-jscl
(defvar *macroexpander-cache*
  (make-hash-table :test #'eq))

(defun !macro-function (symbol)
  (unless (symbolp symbol)
    (error "`~S' is not a symbol." symbol))
  (let ((b (lookup-in-lexenv symbol *environment* 'function)))
    (if (and b (eq (binding-type b) 'macro))
        (let ((expander (binding-value b)))
          (cond
            #-jscl
            ((gethash b *macroexpander-cache*)
             (setq expander (gethash b *macroexpander-cache*)))
            ((listp expander)
             (let ((compiled (eval expander)))
               ;; The list representation are useful while
               ;; bootstrapping, as we can dump the definition of the
               ;; macros easily, but they are slow because we have to
               ;; evaluate them and compile them now and again. So, let
               ;; us replace the list representation version of the
               ;; function with the compiled one.
               ;;
               #+jscl (setf (binding-value b) compiled)
               #-jscl (setf (gethash b *macroexpander-cache*) compiled)
               (setq expander compiled))))
          expander)
        nil)))

(defun !macroexpand-1 (form)
  (cond
    ((symbolp form)
     (let ((b (lookup-in-lexenv form *environment* 'variable)))
       (if (and b (eq (binding-type b) 'macro))
           (values (binding-value b) t)
           (values form nil))))
    ((and (consp form) (symbolp (car form)))
     (let ((macrofun (!macro-function (car form))))
       (if macrofun
           (values (funcall macrofun (cdr form)) t)
           (values form nil))))
    (t
     (values form nil))))

(defun compile-funcall (function args)
  (let* ((arglist (list* (if *multiple-value-p* '|values| '|pv|)
                         (length args)
                         (mapcar #'ls-compile args))))
    (unless (or (symbolp function)
                (and (consp function)
                     (member (car function) '(lambda oget))))
      (error "Bad function designator `~S'" function))
    (cond
      ((translate-function function)
       `(call ,(make-symbol (translate-function function)) ,@arglist))
      ((and (symbolp function)
            #+jscl (eq (symbol-package function) (find-package "COMMON-LISP"))
            #-jscl t)
       `(call (get ,(ls-compile `',function) "fvalue") ,@arglist))
      #+jscl((symbolp function)
             `(call ,(ls-compile `#',function) ,@arglist))
      ((and (consp function) (eq (car function) 'lambda))
       `(call ,(ls-compile `#',function) ,@arglist))
      ((and (consp function) (eq (car function) 'oget))
       `(call ,(ls-compile function) ,@arglist))
      (t
       (error "Bad function descriptor")))))

(defun ls-compile-block (sexps &optional return-last-p decls-allowed-p)
  (multiple-value-bind (sexps decls)
      (parse-body sexps :declarations decls-allowed-p)
    (declare (ignore decls))
    (if return-last-p
        `(progn
           ,@(mapcar #'ls-compile (butlast sexps))
           (return ,(ls-compile (car (last sexps)) *multiple-value-p*)))
        `(progn ,@(mapcar #'ls-compile sexps)))))

(defun ls-compile* (sexp &optional multiple-value-p)
  (multiple-value-bind (sexp expandedp) (!macroexpand-1 sexp)
    (when expandedp
      (return-from ls-compile* (ls-compile sexp multiple-value-p)))
    ;; The expression has been macroexpanded. Now compile it!
    (let ((*multiple-value-p* multiple-value-p))
      (cond
        ((symbolp sexp)
         (let ((b (lookup-in-lexenv sexp *environment* 'variable)))
           (cond
             ((and b (not (member 'special (binding-declarations b))))
              (make-symbol (binding-value b)))
             ((or (keywordp sexp)
                  (and b (member 'constant (binding-declarations b))))
              `(get ,(ls-compile `',sexp) "value"))
             (t
              (ls-compile `(symbol-value ',sexp))))))
        ((or (integerp sexp) (floatp sexp) (characterp sexp) (stringp sexp) (arrayp sexp))
         (literal sexp))
        ((listp sexp)
         (let ((name (car sexp))
               (args (cdr sexp)))
           (cond
             ;; Special forms
             ((assoc name *compilations*)
              (let ((comp (second (assoc name *compilations*))))
                (apply comp args)))
             ;; Built-in functions
             ((and (assoc name *builtins*)
                   (not (claimp name 'function 'notinline)))
              (let ((comp (second (assoc name *builtins*))))
                (apply comp args)))
             (t
              (compile-funcall name args)))))
        (t
         (error "How should I compile `~S'?" sexp))))))

(defun ls-compile (sexp &optional multiple-value-p)
  (ls-compile* sexp multiple-value-p))


(defvar *compile-print-toplevels* nil)

(defun truncate-string (string &optional (width 60))
  (let ((n (or (position #\newline string)
               (min width (length string)))))
    (subseq string 0 n)))

(defun convert-toplevel (sexp &optional multiple-value-p)
  (let ((*toplevel-compilations* nil))
    (cond
      ;; Non-empty toplevel progn
      ((and (consp sexp)
            (eq (car sexp) 'progn)
            (cdr sexp))
       `(progn
          ,@(mapcar (lambda (s) (convert-toplevel s t))
                    (cdr sexp))))
      (t
       (when *compile-print-toplevels*
         (let ((form-string (prin1-to-string sexp)))
           (format t "Compiling ~a..." (truncate-string form-string))))
       (let ((code (ls-compile sexp multiple-value-p)))
         `(progn
            ,@(get-toplevel-compilations)
            (code ,code ";
")))))))

(defun ls-compile-toplevel (sexp &optional multiple-value-p)
  (with-output-to-string (*standard-output*)
    (js (convert-toplevel sexp multiple-value-p))))
