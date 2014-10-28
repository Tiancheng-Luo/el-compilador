;;; Type inference code. -*- lexical-binding:t -*-

;;; Commentary:

;; The type inference pass attempts to assign types to SSA names.

;; A type is just a symbol.  The symbols used are largely just those
;; returned by `type-of', but there are a few differences.

;; First, (type-of nil) and (type-of t) yield 'symbol, but we
;; represent them as 'null and t.  It's nice to treat these specially
;; as it enables some optimizations.

;; We also recognize some "merged" types that won't ever be returned
;; by `type-of'.  For instance, we have a 'boolean type, which
;; corresponds to the booleanp predicate; a 'list type, which
;; indicates either a cons or nil; and a 'number type.

;; Types can be inferred in a few ways:

;; 1. A constant's type is immediately known.
;; 2. Some functions are annotated as returning a known type.
;; 3. Some functions are annotated as being 'simple-numeric' functions,
;;    and have special treatment.  See props.el.
;; 4. Type predicates such as integerp are used to annotate
;;    variables.  For example in:
;;        (if (integerp x) (1+ x))
;;    the type of 'x' in the '1+' expression is known to be 'integer.

;; This one isn't implemented:
;; 5. Type declarations can be used to annotate variables, e.g.:
;;        (let ((x 0)) (declare (type integer i)) ...)
;;    Note that these are not checked, so for argument checking it
;;    is better to use cl-check-type, as its expansion falls under
;;    case 4 above.

;;; Code:

(cl-defstruct elcomp--typeinf
  "A structure that holds the data for a type-inference pass."
  worklist)

(defun elcomp--nullable-type-p (type)
  "Return t if value of type TYPE can nil."
  (memq type '(atom list symbol boolean :bottom)))

(defun elcomp--sequence-type-p (type)
  (memq type '(list cons null bool-vector char-table string
		    vector sequence)))

(defun elcomp--numeric-type-p (type)
  (memq type '(float integer marker number)))

(defun elcomp--boolean-type-p (type)
  (memq type '(null t)))

(defun elcomp--list-type-p (type)
  (memq type '(null cons list)))

(defun elcomp--merge-types (&rest types)
  ;; Start with Top type.
  (let ((result :top))
    (while types
      (let ((type (pop types)))
	(cond
	 ((eq result :top)
	  ;; Top + TYPE = TYPE.
	  (setf result type))

	 ((eq type :top)
	  ;; TYPE + Top = TYPE.
	  )

	 ((eq result :bottom)
	  ;; Nothing - already at bottom.
	  )

	 ((eq type :bottom)
	  (setf result :bottom))

	 ((eq result type)
	  ;; Already the same.
	  )

	 ((and (elcomp--sequence-type-p result)
	       (elcomp--sequence-type-p type))
	  (setf result 'sequence))

	 ((and (elcomp--numeric-type-p result)
	       (elcomp--numeric-type-p type))
	  (setf result 'number))

	 ((and (elcomp--boolean-type-p result)
	       (elcomp--boolean-type-p type))
	  ;; does this even matter?
	  (setf result 'boolean))

	 ((and (elcomp--list-type-p result)
	       (elcomp--list-type-p type))
	  (setf result 'list))

	 (t
	  ;; Merging any two random types results in bottom.
	  (setf result :bottom)))))
    result))

(defgeneric elcomp--compute-type (obj map)
  "Compute the type of OBJ in a basic block, given a type map.

The type is generally the result of `type-of'.
However `:top' is used to represent the 'top' type,
`:bottom' is used to represent the 'bottom' type,
and `nil' is used to mean a typeless instruction.")

(defmethod elcomp--compute-type (obj map)
  nil)

(defmethod elcomp--compute-type ((obj elcomp--constant) map)
  (let ((value (oref obj :value)))
    (cl-case value
      ;; nil has a type of its own.
      ((nil) 'null)
      ;; As does t.
      ((t) t)
      (t (type-of value)))))

(defmethod elcomp--compute-type ((obj elcomp--set) map)
  (elcomp--find-type (oref obj :value) map))

(defun elcomp--merge-math-types (arguments map)
  ;; With no arguments we return integer:
  ;; (type-of (+)) => integer.
  (let ((result 'integer))
    (dolist (arg arguments)
      (let ((next-type (elcomp--find-type arg map)))
	(cond
	 ((eq next-type :top)
	  ;; Nothing.
	  )

	 ((eq result 'float)
	  ;; If we know we've seen a float, the result will be float.
	  )

	 ;; Note here that this is true for even one argument.
	 ;; (type-of (+ (point))) => integer
	 ((and (memq result '(integer marker))
	       (memq next-type '(integer marker)))
	  (setf result 'integer))

	 ((eq result next-type)
	  ;; Nothing.
	  )

	 ((eq next-type 'float)
	  (setf result 'float))

	 (t
	  ;; We know nothing.  We could be even smarter and arrange
	  ;; for type errors to be detected, and turn the current
	  ;; instruction into a `diediedie'.
	  (setf result 'number)))))))

(defmethod elcomp--compute-type ((obj elcomp--call) map)
  (if (not (oref obj :sym))
      ;; No symbol means no type.
      nil
    (let ((func (oref obj :func)))
      (cond
       ;; If the function has a defined type, use it.
       ((elcomp--func-type func)
	(elcomp--func-type func))

       ;; Handle simple numerics.
       ((elcomp--func-simple-numeric-p func)
	(elcomp--merge-math-types (oref obj :args) map))

       (t
	;; Nothing special.
	:bottom)))))

(defmethod elcomp--compute-type ((obj elcomp--phi) map)
  (let ((arg-list nil))
    (maphash (lambda (var _ignore)
	       (push (elcomp--find-type var map) arg-list))
	     (oref obj :args))
    (apply #'elcomp--merge-types arg-list)))

(defmethod elcomp--compute-type ((obj elcomp--argument) map)
  ;; FIXME.
  :bottom)

(defun elcomp--find-type (obj map)
  (let ((value (gethash obj map)))
    (unless value
      (setf value (elcomp--compute-type obj map))
      (when value
	(puthash obj value map)))
    value))

(defun elcomp--type-map-merge (bb from)
  "Merge type-map FROM into the type-map for basic block BB.

Return non-nil if any changes were made."
  (if (elcomp--basic-block-type-map bb)
      ;; Merge.
      (let ((to-map (elcomp--basic-block-type-map bb))
	    (changed nil))
	(maphash
	 (lambda (name type)
	   (let* ((to-type (gethash name to-map :top))
		  (merge-type (elcomp--merge-types to-type type)))
	     (unless (eq to-type merge-type)
	       (puthash name merge-type to-map)
	       (setf changed t))))
	 from)
	changed)
    ;; Else.
    (setf (elcomp--basic-block-type-map bb) (copy-hash-table from))
    t))

(defun elcomp--type-map-propagate-one (infobj bb type-map)
  (when (elcomp--type-map-merge bb type-map)
    (push bb (elcomp--typeinf-worklist infobj))))

(defgeneric elcomp--type-map-propagate (insn infobj type-map)
  "FIXME")

(defmethod elcomp--type-map-propagate (insn infobj type-map)
  nil)

(defmethod elcomp--type-map-propagate ((insn elcomp--goto) infobj type-map)
  (elcomp--type-map-propagate-one infobj (oref insn :block) type-map))

(defmethod elcomp--type-map-propagate ((insn elcomp--if) infobj type-map)
  ;; FIXME this is where we should handle inferencing from type
  ;; predicates.  We can also take the opportunity here to ignore a
  ;; branch based on that -- if we never visit the branch then we can
  ;; delete it and re-run some opts.
  (elcomp--type-map-propagate-one infobj (oref insn :block-true) type-map)
  (elcomp--type-map-propagate-one infobj (oref insn :block-false) type-map))

(defun elcomp--type-map-propagate-exception (bb type-map)
  (catch 'done
    (dolist (exception (elcomp--basic-block-exceptions bb))
      (cond
       ((elcomp--fake-unwind-protect-p exception)
	;; Keep going.
	)

       (t
	(elcomp--type-map-propagate-one infobj (oref exception :handler)
					type-map)
	(throw 'done))))))

(defun elcomp--infer-types-for-bb (bb infobj)
  ;; Work on a local copy.  We're consing too much but it's for
  ;; another day.
  (let ((local-types (copy-hash-table (elcomp--basic-block-type-map bb))))
    ;; Always reset the final map for the BB.
    (setf (elcomp--basic-block-final-type-map bb) local-types)

    ;; Compute the types for each phi node.
    (maphash
     (lambda (_ignore phi)
       (elcomp--find-type phi local-types))
     (elcomp--basic-block-phis bb))

    ;; Compute the type for each statement.
    (dolist (insn (elcomp--basic-block-code bb))
      (elcomp--find-type insn local-types))

    ;; Propagate the results and possibly add to the work list.
    (elcomp--type-map-propagate (elcomp--last-instruction bb) infobj
				local-types)
    (elcomp--type-map-propagate-exception bb local-types)))

(defun elcomp--look-up-type (bb var)
  (when (elcomp--basic-block-final-type-map bb)
    (gethash var (elcomp--basic-block-final-type-map bb))))

(defun elcomp--infer-types-pass (compiler)
  ;; FIXME this is where we would infer argument types.
  ;; At least &rest args should be 'list.
  (let ((infobj (make-elcomp--typeinf)))
    ;; Make sure the entry block has an initial type map.  FIXME
    ;; probably it should hold all the arguments.
    (let ((entry-block (elcomp--entry-block compiler)))
      (cl-assert (not (elcomp--basic-block-type-map entry-block)))
      (setf (elcomp--basic-block-type-map entry-block) (make-hash-table))
      (push entry-block (elcomp--typeinf-worklist infobj)))
    ;; Now keep inferring types until we're out of blocks.
    ;; FIXME where do we store the final maps?
    (while (elcomp--typeinf-worklist infobj)
      (let ((bb (pop (elcomp--typeinf-worklist infobj))))
	(elcomp--infer-types-for-bb bb infobj)))))

;; this was in elcomp--linearize
       ;; ((eq fn 'declare)
       ;; 	(dolist (spec (cdr form))
       ;; 	  ;; FIXME this should also examine direct-calls
       ;; 	  (pcase spec
       ;; 	      (`(type ,type-name . ,variables)
       ;; 	       (dolist (var variables)
       ;; 		 (setf var (elcomp--rewrite-one-ref compiler var))
       ;; 		 (elcomp--set-type var type-name))))))
