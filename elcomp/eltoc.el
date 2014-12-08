;;; eltoc.el --- compile to C. -*- lexical-binding:t -*-

;;; Commentary:

;; A backend to generate Emacs-flavored C.

;; TO DO:
;; emit constants properly
;; handle phi nodes
;; GCPRO (if that is still needed?)
;; emit lambdas without using DEFUN; call them directly

;;; Code:

;; We should also allow a declaration that allows a direct C
;; call, not allowing symbol redefinition.
;; (declare (direct FUNC))

(require 'elcomp)
(require 'elcomp/linearize)
(require 'elcomp/props)

;; FIXME - emacs must supply this value
(defconst elcomp--c-max-args 8)

(cl-defstruct elcomp--c
  decls
  decl-marker
  ;; Map symbols to their C names.
  interned-symbols
  (eh-count 0))

(defconst elcomp--c-types
  "Map Lisp types to unchecked C accessor macros."
  '((integer "XINT")
    (float "XFLOAT_DATA")
    (symbol "XSYMBOL")))

(defconst elcomp--simple-math
  '(< <= > >= /= + - * / 1+))

(defun elcomp--c-quote-string (str)
  "Quote a Lisp string according to C rules."
  (concat "\"" (mapconcat (lambda (c)
			    (if (memq c '(?\\ ?\" ?\n))
				(string ?\\ c)
			      (string c)))
			  str "")
	  "\""))

(defun elcomp--c-name (symbol)
  "Compute the C name for a symbol."
  (mapconcat
   (lambda (char)
     (char-to-string
      (cond
       ((eq char ?-) ?_)
       ;; FIXME reject bad stuff
       ;; FIXME check for dups!
       (t char))))
   (symbol-name symbol) ""))

(defun elcomp--c-intern-symbol (eltoc symbol)
  "Mark a symbol for init-time interning and return its name.
This is used for references to global symbols."
  (or (gethash symbol (elcomp--c-interned-symbols eltoc))
      (puthash symbol (concat "Q" (elcomp--c-name symbol))
	       (elcomp--c-interned-symbols eltoc))))

(defun elcomp--c-declare (eltoc sym)
  (unless (gethash sym (elcomp--c-decls eltoc))
    (save-excursion
      (goto-char (elcomp--c-decl-marker eltoc))
      (insert "  Lisp_Object " (elcomp--c-name sym) ";\n")
      (puthash sym t (elcomp--c-decls eltoc)))))

(defun elcomp--c-declare-handler (eltoc)
  (let ((name (format "h%d" (cl-incf (elcomp--c-eh-count eltoc)))))
    (save-excursion
      (goto-char (elcomp--c-decl-marker eltoc))
      (insert "  struct handler *" name ";\n")
      name)))

(defun elcomp--c-symbol (eltoc sym &optional no-declare)
  (unless no-declare
    (elcomp--c-declare eltoc sym))
  (insert (elcomp--c-name sym)))

(defun elcomp--c-emit-symref (eltoc insn)
  (cond
   ((symbolp insn)
    (insert (elcomp--c-intern-symbol eltoc insn)))
   ((elcomp--set-child-p insn)
    (elcomp--c-symbol eltoc (oref insn :name)))
   ((elcomp--call-child-p insn)
    (elcomp--c-symbol eltoc (oref insn :sym)))
   ((elcomp--phi-child-p insn)
    ;; FIXME??
    (elcomp--c-symbol eltoc (oref insn :original-name)))
   ((elcomp--argument-child-p insn)
    (elcomp--c-symbol eltoc (oref insn :original-name) t))
   ((elcomp--constant-p insn)
    (let ((value (oref insn :value)))
      (cond
       ((symbolp value)
	(insert (elcomp--c-intern-symbol eltoc value)))
       ((integerp value)
	(insert "make_number (" (number-to-string value) ")"))
       ((stringp value)
	;; Could use make_string, but there's little point since GCC
	;; will optimize the strlen anyhow.
	(insert "build_string (" (elcomp--c-quote-string value) ")"))
       (t
	(error "unhandled constant of type %S" (type-of value))))))
   (t
    (error "unhandled case: %S" insn))))

(defun elcomp--c-emit-label (block)
  (insert (format "BB_%d" (elcomp--basic-block-number block))))

(defgeneric elcomp--c-emit (insn eltoc)
  "FIXME")

(defmethod elcomp--c-emit (insn _eltoc)
  (error "unhandled case: %S" insn))

(defmethod elcomp--c-emit ((insn elcomp--set) eltoc)
  (elcomp--c-emit-symref eltoc insn)
  (insert " = ")
  (elcomp--c-emit-symref eltoc (oref insn :value)))

(defun elcomp--unbind-emitter (insn)
  "Emit a call to :elcomp-unbind.
This must be handled specially for now to avoid boxing the
argument."
  (let* ((args (oref insn :args))
	 (first-arg (car args)))
  (cl-assert (eq (length args) 1))
  (cl-assert (elcomp--constant-p first-arg))
  (let ((value (oref first-arg :value)))
    (cl-assert (integerp value))
    (insert "unbind_to (SPECPDL_INDEX - "
	    (number-to-string value)
	    ", Qnil)"))))

(defconst elcomp--c-direct-renames
  '((:elcomp-specbind . "specbind")
    (:elcomp-fetch-condition . "fetch_condition")
    (:save-excursion-save . "save_excursion")
    (:save-excursion-restore . "restore_excursion")
    (:save-restriction-save . "save_restriction")
    (:save-restriction-restore . "restore_restrction")
    (:unwind-protect-continue . "unwind_protect_continue")))

(defmethod elcomp--c-emit ((insn elcomp--call) eltoc)
  (when (oref insn :sym)
    (elcomp--c-emit-symref eltoc insn)
    (insert " = "))
  (if (eq (oref insn :func) :elcomp-unbind)
      (elcomp--unbind-emitter insn)
    (let ((arg-list (oref insn :args))
	  (is-direct (elcomp--func-direct-p (oref insn :func))))
      (cond
       ((keywordp (oref insn :func))
	(insert (cdr (assq (oref insn :func) elcomp--c-direct-renames))
		" ("))
       (is-direct
	(insert "F" (elcomp--c-name (oref insn :func)) " ("))
       (t
	(push (oref insn :func) arg-list)
	;; FIXME - what if not a symbol, etc.
	(insert (format "Ffuncall (%d, ((Lisp_Object[]) { "
			(length arg-list)))))
      (let ((first t))
	(dolist (arg arg-list)
	  (if first
	      (setf first nil)
	    (insert ", "))
	  (elcomp--c-emit-symref eltoc arg)))
      (if (or is-direct (keywordp (oref insn :func)))
	  (insert ")")
	(insert " }))")))))

(defmethod elcomp--c-emit ((insn elcomp--goto) _eltoc)
  (insert "goto ")
  (elcomp--c-emit-label (oref insn :block)))

(defmethod elcomp--c-emit ((insn elcomp--if) eltoc)
  (insert "if (!NILP (")
  (elcomp--c-emit-symref eltoc (oref insn :sym))
  (insert ")) goto ")
  (elcomp--c-emit-label (oref insn :block-true))
  (insert "; else goto ")
  (elcomp--c-emit-label (oref insn :block-false)))

(defmethod elcomp--c-emit ((insn elcomp--return) eltoc)
  (insert "return ")
  (elcomp--c-emit-symref eltoc (oref insn :sym)))

(defmethod elcomp--c-emit ((insn elcomp--argument) _eltoc)
  (insert "goto ")
  (elcomp--c-emit-label (oref insn :goto)))

(defmethod elcomp--c-emit ((insn elcomp--catch) eltoc)
  (let ((name (elcomp--c-declare-handler eltoc)))
    (insert "  PUSH_HANDLER (" name ", ")
    (elcomp--c-emit-symref eltoc (oref insn :tag))
    (insert ", CATCHER);\n")
    (insert "  if (sys_setjmp (" name "->jmp))\n")
    (insert "    {\n")
    (insert "      handlerlist = handlerlist->next;\n")
    (insert "      goto ")
    (elcomp--c-emit-label (oref insn :handler))
    (insert ";\n")
    (insert "    }\n")))

(defmethod elcomp--c-emit ((_insn elcomp--condition-case) _eltoc)
  ;; This one is handled specially for efficiency.
  (error "should not be called"))

(defmethod elcomp--c-emit ((insn elcomp--unwind-protect) eltoc)
  (let ((name (elcomp--c-declare-handler eltoc)))
    ;; Emacs doesn't actually have anything for this yet.
    (insert "  PUSH_HANDLER (" name ", Qnil, UNWIND_PROTECT);\n")
    (insert "  if (sys_setjmp (" name "->jmp))\n")
    (insert "    {\n")
    (insert "      handlerlist = handlerlist->next;\n")
    (insert "      goto ")
    (elcomp--c-emit-label (oref insn :handler))
    (insert ";\n")
    (insert "    }\n")))

(defmethod elcomp--c-emit ((_insn elcomp--fake-unwind-protect) _eltoc)
  ;; Nothing.
  )

(defun elcomp--c-emit-condition-case (eltoc eh-from eh-to)
  (let ((name (elcomp--c-declare-handler eltoc)))
    ;; FIXME - not really correct for Emacs, we'll have to fix that.
    (insert "  PUSH_HANDLER (" name ", Qnil, CONDITION_CASE);\n")
    (insert "  if (sys_setjmp (" name "->jmp))\n")
    (insert "    {\n")
    (insert "      handlerlist = handlerlist->next;\n")
    (while (and (not (eq eh-from eh-to))
		(elcomp--condition-case-p (car eh-from)))
      (insert "      if (handler_matches (FIXME, ")
      (elcomp--c-emit-symref eltoc (oref (car eh-from) :condition-name))
      (insert "))\n")
      (insert "        goto ")
      (elcomp--c-emit-label (oref (car eh-from) :handler))
      (insert ";\n")
      (setf eh-from (cdr eh-from)))
    (insert "    }\n"))
  eh-from)

(defun elcomp--c-first-parent (block)
  (elcomp--any-hash-key (elcomp--basic-block-parents block)))

(defun elcomp--c-emit-exceptions (eltoc block)
  (let* ((first-parent (elcomp--c-first-parent block))
	 (parent-eh (if first-parent
			(elcomp--basic-block-exceptions first-parent)
		      ;; No parent means it is the first block.
		      nil)))
    (let ((bb-eh (elcomp--basic-block-exceptions block)))
      (if (or (memq (car bb-eh) parent-eh)
	      (and parent-eh (not bb-eh)))
	  ;; If our first exception appears in the parent list, then
	  ;; we may need to pop some items.
	  (while (not (eq bb-eh parent-eh))
	    ;; Ignore fake unwind-protects.
	    (unless (elcomp--fake-unwind-protect-child-p (car parent-eh))
	      (insert "  handlerlist = handlerlist->next;\n"))
	    (setf parent-eh (cdr parent-eh)))
	(when bb-eh
	  ;; If our first exception does not appear in the parent
	  ;; list, then we have to push at least one.
	  (while (not (eq bb-eh parent-eh))
	    (if (elcomp--condition-case-p (car bb-eh))
		(setf bb-eh (elcomp--c-emit-condition-case eltoc bb-eh
							   parent-eh))
	      (elcomp--c-emit (car bb-eh) eltoc)
	      (setf bb-eh (cdr bb-eh)))))))))

(defun elcomp--c-emit-block (eltoc bb)
  (elcomp--c-emit-label bb)
  (insert ":\n")
  (elcomp--c-emit-exceptions eltoc bb)
  (dolist (insn (elcomp--basic-block-code bb))
    (insert "  ")
    (elcomp--c-emit insn eltoc)
    (insert ";\n")))

(defun elcomp--c-parse-args (arg-list)
  (let ((min-args 0))
    (while (and arg-list (not (memq (car arg-list) '(&optional &rest))))
      (pop arg-list)
      (cl-incf min-args))
    (let ((max-args min-args))
      (while (eq (car arg-list) '&optional)
	(pop arg-list)
	(pop arg-list)
	(cl-incf max-args))
      (if (or (eq (car arg-list) '&rest)
	      (> max-args elcomp--c-max-args))
	  (cons min-args "MANY")
	(cons min-args max-args)))))

(defun elcomp--c-generate-defun (compiler)
  (let* ((info (elcomp--defun compiler))
	 (sym (car info))
	 (c-name (elcomp--c-name sym))
	 (arg-info (elcomp--c-parse-args (cadr info))))
    (insert
     (format "DEFUN (%s, F%s, S%s, %s, %s,\n    %s,\n    doc: /* %s */)\n"
	     (elcomp--c-quote-string (symbol-name sym))
	     c-name c-name
	     (car arg-info) (cdr arg-info)
	     ;; Interactive.
	     ;; FIXME: quoting for the interactive spec
	     ;; Note that we can have a whole lisp form here.
	     (or (nth 3 info) "0")
	     ;; Doc string.  FIXME - comment quoting
	     (or (nth 2 info) "nothing??"))) ;FIXME anything?
    (if (equal (cdr arg-info) "MANY")
	(let ((nargs (elcomp--c-name (cl-gensym "nargs")))
	      (args (elcomp--c-name (cl-gensym "args"))))
	  (insert "  (ptrdiff_t " nargs ", Lisp_Object *" args ")\n{\n")
	  ;; We need special parsing for &rest arguments or when the
	  ;; number of format arguments is greater than the maximum.
	  ;; First emit the declarations.
	  (dolist (arg (cadr info))
	    (unless (memq arg '(&optional &rest))
	      (insert "  Lisp_Object " (symbol-name arg) " = Qnil;\n")))
	  ;; Now initialize each one.
	  (let ((is-rest nil))
	    (dolist (arg (cadr info))
	      (cond
	       ((eq arg '&rest)
		(setf is-rest t))
	       ((eq arg '&optional)
		;; Nothing.
		)
	       (t
		(if is-rest
		    (insert "  " (symbol-name arg) " = Flist ("
			    nargs ", " args ");\n")
		  (insert "  if (" nargs " > 0)\n"
			  "    {\n"
			  "      " (symbol-name arg) " = *" args "++;\n"
			  "      --" nargs ";\n"
			  "    }\n")))))))
      (insert "  (")
      (let ((first t))
	(dolist (arg (cadr info))
	  (unless (eq arg '&optional)
	    (unless first
	      (insert ", "))
	    (setf first nil)
	    (insert "Lisp_Object " (symbol-name arg)))))
      (insert ")\n{\n"))))

(defun elcomp--c-translate-one (compiler symbol-hash)
  (elcomp--require-back-edges compiler)
  (let ((eltoc (make-elcomp--c :decls (make-hash-table)
			       :decl-marker (make-marker)
			       :interned-symbols symbol-hash)))
    (elcomp--c-generate-defun compiler)
    (set-marker (elcomp--c-decl-marker eltoc) (point))
    (insert "\n")
    (set-marker-insertion-type (elcomp--c-decl-marker eltoc) t)
    (elcomp--iterate-over-bbs compiler
			      (lambda (bb)
				(elcomp--c-emit-block eltoc bb)))
    (insert "}\n\n")
    (set-marker (elcomp--c-decl-marker eltoc) nil)))

(defun elcomp--c-translate (unit)
  (let ((symbol-hash (make-hash-table)))
    (maphash
     (lambda (_ignore compiler)
       (elcomp--c-translate-one compiler symbol-hash))
     (elcomp--compilation-unit-defuns unit))
    ;; Define the symbol variables.
    (save-excursion
      (goto-char (point-min))
      (insert "#include <config.h>\n"
	      "#include <lisp.h>\n\n"
	      "int plugin_is_GPL_compatible;\n\n")
      (maphash (lambda (_symbol c-name)
		 (insert "static Lisp_Object " c-name ";\n"))
	       symbol-hash)
      (insert "\n"))
    (insert "\n"
	    "void\ninit (void)\n{\n")
    ;; Intern all the symbols we refer to.
    (maphash (lambda (symbol c-name)
	       (insert "  " c-name " = intern ("
		       (elcomp--c-quote-string (symbol-name symbol))
		       ");\n"))
	     symbol-hash)
    (insert "\n")
    ;; Register our exported functions with Lisp.
    (maphash
     (lambda (_ignore compiler)
       (let ((name (car (elcomp--defun compiler))))
	 (when name
	   (insert "  defsubr (&S" (elcomp--c-name name) ");\n"))))
     (elcomp--compilation-unit-defuns unit))
    (insert "}\n")))

(provide 'elcomp/eltoc)

;;; eltoc.el ends here
