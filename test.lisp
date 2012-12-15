(lambda (x y)
  x)

(debug "hola")
(debug '(1 2 3 4))
(debug (if 2 (+ 2 1) 0))
(debug (= (+ 2 1) (- 4 1)))

;;; Variables
(debug "---VARIABLES---")
(eval-when-compile
  (%compile-defvar 'name))
(setq name 10)
(debug name)

;;; Functions
(debug "---FUNCTIONS---")
(eval-when-compile
  (%compile-defun 'f))
(fsetq f (lambda (x) (+ x 10)))
(debug (f 20))
