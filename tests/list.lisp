;; Tests for list functions

;; TODO: EQUAL doesn't compare lists correctly at the moment.
;; Once it does the lists can be compared directly in many of these tests

; COPY-TREE
(test (let* ((foo (list '(1 2) '(3 4)))
             (bar (copy-tree foo)))
        ;; (SETF (CAR (CAR FOO)) 0) doesn't work in the test for some reason,
        ;; despite working fine in the REPL
        (rplaca (car foo) 0)
        (not (= (car (car foo))
                (car (car bar))))))

; TREE-EQUAL
(test (tree-equal '(1 2 3) '(1 2 3)))
(test (tree-equal '(1 (2 (3 4) 5) 6) '(1 (2 (3 4) 5) 6)))
(test (tree-equal (cons 1 2) (cons 2 3)
                  :test (lambda (a b) (not (= a b)))))

; SUBST
; Can't really test this until EQUAL works properly on lists

; POP
(test (let* ((foo '(1 2 3))
             (bar (pop foo)))
        (and (= bar 1)
             (= (car foo) 2))))
