(in-package :sys.int)

(defun fetch-thread-function-arguments (thread)
  (when (not (mezzano.supervisor:thread-full-save-p thread))
    (format t "Thread not full save?~%")
    (return-from fetch-thread-function-arguments '(:thread-in-strange-state)))
  (let ((count (mezzano.supervisor:thread-state-rcx-value thread))
        (reg-vals (list (mezzano.supervisor:thread-state-r8-value thread)
                        (mezzano.supervisor:thread-state-r9-value thread)
                        (mezzano.supervisor:thread-state-r10-value thread)
                        (mezzano.supervisor:thread-state-r11-value thread)
                        (mezzano.supervisor:thread-state-r12-value thread)))
        (sp (mezzano.supervisor:thread-state-rsp thread))
        (stack-vals '()))
    (when (not (fixnump count))
      (format t "Count #x~S not a fixnum?~%" (mezzano.supervisor:thread-state-rcx thread))
      (return-from fetch-thread-function-arguments '(:thread-in-strange-state)))
    (dotimes (i (max 0 (- count 5)))
      (push (memref-t sp (1+ i)) stack-vals))
    (subseq (append reg-vals (reverse stack-vals))
            0 count)))

(defun fetch-thread-return-values (thread)
  (when (not (mezzano.supervisor:thread-full-save-p thread))
    (format t "Thread not full save?~%")
    (return-from fetch-thread-return-values '(:thread-in-strange-state)))
  (let ((count (mezzano.supervisor:thread-state-rcx-value thread))
        (vals (list (mezzano.supervisor:thread-state-r12-value thread)
                    (mezzano.supervisor:thread-state-r11-value thread)
                    (mezzano.supervisor:thread-state-r10-value thread)
                    (mezzano.supervisor:thread-state-r9-value thread)
                    (mezzano.supervisor:thread-state-r8-value thread))))
    (when (not (fixnump count))
      (format t "Count #x~S not a fixnum?~%" (mezzano.supervisor:thread-state-rcx thread))
      (return-from fetch-thread-return-values '(:thread-in-strange-state)))
    (dotimes (i (max 0 (- count 5)))
      (push (%object-ref-t thread (+ mezzano.supervisor::+thread-mv-slots-start+ i)) vals))
    (subseq (reverse vals) 0 count)))

(defparameter *step-special-functions*
  '(mezzano.runtime::slow-cons
    mezzano.runtime::%slow-allocate-from-general-area
    mezzano.runtime::%allocate-from-pinned-area
    mezzano.runtime::%allocate-from-wired-area
    mezzano.supervisor::%call-on-wired-stack-without-interrupts
    mezzano.supervisor::call-with-mutex))

(defun single-step-wrapper (&rest args &closure call-me)
  (declare (dynamic-extent args))
  (unwind-protect
       (apply call-me args)
    (mezzano.supervisor::stop-current-thread)))

(defun safe-single-step-thread (thread)
  (check-type thread mezzano.supervisor:thread)
  (assert (eql (mezzano.supervisor:thread-state thread) :stopped))
  ;; If the thread is not in the full-save state, then convert it.
  (mezzano.supervisor::convert-thread-to-full-save thread)
  (let* ((rip (mezzano.supervisor:thread-state-rip thread))
         (fn (return-address-to-function rip)))
    (cond ((member fn *step-special-functions* :key #'fdefinition)
           (when (not (eql rip (%object-ref-unsigned-byte-64 fn +function-entry-point+)))
             (cerror "Step anyway"
                     "Cannot single-step function in the middle of special function ~S."
                     fn)
             (mezzano.supervisor::single-step-thread thread)
             (return-from safe-single-step-thread))
           (format t "Stepping over special function ~S.~%" fn)
           ;; Point RIP at single-step-wrapper and RBX (&CLOSURE) at the function to wrap.
           (setf (mezzano.supervisor:thread-state-rbx-value thread) fn
                 (mezzano.supervisor:thread-state-rip thread) (%object-ref-unsigned-byte-64 #'single-step-wrapper +function-entry-point+))
           (mezzano.supervisor::resume-thread thread)
           ;; Wait for the thread to stop or die.
           (loop
              (when (member (mezzano.supervisor::thread-state thread) '(:stopped :dead))
                (return))
              (mezzano.supervisor::thread-yield)))
          (t
           (mezzano.supervisor::single-step-thread thread)))))

(defun step-until-next-call-or-return (thread &optional (limit 1000))
  (let ((prev-fn (return-address-to-function
                  (mezzano.supervisor:thread-state-rip thread)))
        (iters 0))
    (loop
       (dump-thread-state thread)
       (safe-single-step-thread thread)
       (let* ((rip (mezzano.supervisor:thread-state-rip thread))
              (fn (return-address-to-function rip)))
         (when (eql rip (%object-ref-unsigned-byte-64 fn +function-entry-point+))
           (format t "Entered function ~S with arguments ~:S.~%" fn (fetch-thread-function-arguments thread))
           (return))
         (when (not (eql fn prev-fn))
           (format t "Returning from function ~S to ~S with results ~:S.~%"
                   prev-fn fn (fetch-thread-return-values thread))
           (return))
         (format t "Current fn ~S  prev fn ~S.~%" fn prev-fn)
         (setf prev-fn fn))
       (when (> (incf iters) limit)
         (format t "Reached step limit of ~D instructions.~%" limit)
         (return)))))

(defun dump-thread-state (thread)
  (cond ((mezzano.supervisor:thread-full-save-p thread)
         (format t "Full-save state:~%")
         (format t " r15: ~8,'0X~%" (mezzano.supervisor:thread-state-r15 thread))
         (format t " r14: ~8,'0X~%" (mezzano.supervisor:thread-state-r14 thread))
         (format t " r13: ~8,'0X~%" (mezzano.supervisor:thread-state-r13 thread))
         (format t " r12: ~8,'0X~%" (mezzano.supervisor:thread-state-r12 thread))
         (format t " r11: ~8,'0X~%" (mezzano.supervisor:thread-state-r11 thread))
         (format t " r10: ~8,'0X~%" (mezzano.supervisor:thread-state-r10 thread))
         (format t "  r9: ~8,'0X~%" (mezzano.supervisor:thread-state-r9 thread))
         (format t "  r8: ~8,'0X~%" (mezzano.supervisor:thread-state-r8 thread))
         (format t " rdi: ~8,'0X~%" (mezzano.supervisor:thread-state-rdi thread))
         (format t " rsi: ~8,'0X~%" (mezzano.supervisor:thread-state-rsi thread))
         (format t " rbx: ~8,'0X~%" (mezzano.supervisor:thread-state-rbx thread))
         (format t " rdx: ~8,'0X~%" (mezzano.supervisor:thread-state-rdx thread))
         (format t " rcx: ~8,'0X~%" (mezzano.supervisor:thread-state-rcx thread))
         (format t " rax: ~8,'0X~%" (mezzano.supervisor:thread-state-rax thread))
         (format t " rbp: ~8,'0X~%" (mezzano.supervisor:thread-state-rbp thread))
         (format t " rip: ~8,'0X~%" (mezzano.supervisor:thread-state-rip thread))
         (format t "  cs: ~8,'0X~%" (mezzano.supervisor:thread-state-cs thread))
         (format t " rflags: ~8,'0X~%" (mezzano.supervisor:thread-state-rflags thread))
         (format t " rsp: ~8,'0X~%" (mezzano.supervisor:thread-state-rsp thread))
         (format t "  ss: ~8,'0X~%" (mezzano.supervisor:thread-state-ss thread)))
        (t
         (format t "Partial-save state:~%")
         (format t " rsp: ~8,'0X~%" (mezzano.supervisor:thread-state-rsp thread))
         (format t " rbp: ~8,'0X~%" (mezzano.supervisor:thread-state-rbp thread))
         (format t " rip: ~8,'0X~%" (sys.int::memref-unsigned-byte-64 (mezzano.supervisor:thread-state-rsp thread) 0))))
  (values))

(defun trace-execution (function &key full-dump run-forever (print-instructions t) trace-call-mode (trim-stepper-noise t))
  (check-type function function)
  (let* ((next-stop-boundary 10000)
         (stopped nil)
         (terminal-io *terminal-io*)
         (standard-input *standard-input*)
         (standard-output *standard-output*)
         (error-output *error-output*)
         (trace-output *trace-output*)
         (debug-io *debug-io*)
         (query-io *query-io*)
         (thread (mezzano.supervisor:make-thread
                  (lambda ()
                    (let ((*terminal-io* terminal-io)
                          (*standard-input* standard-input)
                          (*standard-output* standard-output)
                          (*error-output* error-output)
                          (*trace-output* trace-output)
                          (*debug-io* debug-io)
                          (*query-io* query-io)
                          (*the-debugger* (lambda (condition)
                                            (declare (ignore condition))
                                            (throw 'mezzano.supervisor:terminate-thread nil))))
                      (loop
                         (when stopped
                           (return))
                         (mezzano.supervisor:thread-yield))
                      (funcall function)))
                  :name "Trace thread"))
         (instructions-stepped 0)
         (prev-fn nil)
         (disassembler-context (mezzano.disassemble:make-disassembler-context function))
         (in-single-step-wrapper nil)
         (single-step-wrapper-sp nil)
         (prestart trim-stepper-noise)
         (entry-sp nil)
         (fundamental-function (mezzano.disassemble::peel-function function)))
    (mezzano.supervisor::stop-thread thread)
    (setf stopped t)
    (unwind-protect
         (loop
            (when (and (not run-forever)
                       (not (zerop instructions-stepped))
                       (zerop (mod instructions-stepped next-stop-boundary)))
              (when (y-or-n-p "Thread has run for ~D instructions. Stop?" instructions-stepped)
                (mezzano.supervisor:terminate-thread thread)
                (mezzano.supervisor::resume-thread thread)
                (return))
              (setf next-stop-boundary (* next-stop-boundary 2)))
            (when (eql (mezzano.supervisor:thread-state thread) :dead)
              (format t "Thread has died. ~:D instructions executed~%" instructions-stepped)
              (return))
            (when full-dump
              (dump-thread-state thread))
            (safe-single-step-thread thread)
            (let ((rip (mezzano.supervisor:thread-state-rip thread)))
              (multiple-value-bind (fn offset)
                  (return-address-to-function rip)
                (when (and (not entry-sp)
                           prestart
                           (eql fn fundamental-function))
                  (setf entry-sp (mezzano.supervisor:thread-state-rsp thread))
                  (setf prestart nil))
                (cond (prestart)
                      ((and trim-stepper-noise
                            (not in-single-step-wrapper)
                            (eql fn #'single-step-wrapper))
                       (setf single-step-wrapper-sp (mezzano.supervisor:thread-state-rsp thread))
                       (setf in-single-step-wrapper t))
                      (in-single-step-wrapper
                       (when (and (eql fn #'single-step-wrapper)
                                  (< single-step-wrapper-sp (mezzano.supervisor:thread-state-rsp thread))
                                  (logtest #x8 (mezzano.supervisor:thread-state-rsp thread)))
                         (setf in-single-step-wrapper nil)))
                      (t
                       (when (and prev-fn
                                  (not (eql fn prev-fn)))
                         (cond ((eql rip (%object-ref-unsigned-byte-64 fn +function-entry-point+))
                                (cond (trace-call-mode
                                       (write-char #\>)
                                       (write-char #\Space)
                                       (write instructions-stepped)
                                       (write-char #\Space)
                                       (write (mezzano.supervisor:thread-state-rsp thread) :base 16)
                                       (write-char #\Space)
                                       (write (function-name fn))
                                       (terpri))
                                      (t
                                       (format t "Entered function ~S with arguments ~:A.~%"
                                               (or (function-name fn) fn)
                                               (mapcar #'print-safely-to-string
                                                       (fetch-thread-function-arguments thread))))))
                               (t
                                (cond (trace-call-mode
                                       (write-char #\<)
                                       (write-char #\Space)
                                       (write instructions-stepped)
                                       (write-char #\Space)
                                       (write (mezzano.supervisor:thread-state-rsp thread) :base 16)
                                       (write-char #\Space)
                                       (write (function-name prev-fn))
                                       (terpri))
                                      (t
                                       (format t "Returning from function ~S to ~S with results ~:A.~%"
                                               (or (function-name prev-fn) prev-fn)
                                               (or (function-name fn) fn)
                                               (mapcar #'print-safely-to-string
                                                       (fetch-thread-return-values thread))))))))
                       (when print-instructions
                         (when (not (eql fn (mezzano.disassemble:disassembler-context-function disassembler-context)))
                           (setf disassembler-context (mezzano.disassemble:make-disassembler-context fn)))
                         (let ((inst (mezzano.disassemble:instruction-at disassembler-context offset)))
                           (format t "~8,'0X: ~S + ~D " rip (or (function-name fn) fn) offset)
                           (when inst
                             (mezzano.disassemble:print-instruction disassembler-context inst :print-annotations nil :print-labels nil))
                           (terpri)))
                       (incf instructions-stepped)
                       (setf prev-fn fn)))
                (when (and (eql entry-sp (mezzano.supervisor:thread-state-rsp thread))
                           (not (eql offset 16)))
                  (setf prestart t)))))
      (mezzano.supervisor:terminate-thread thread)
      (ignore-errors
        (mezzano.supervisor::resume-thread thread)))))

(defun print-safely-to-string (obj)
  (handler-case
      (format nil "~S" obj)
    (error ()
      (with-output-to-string (s)
        (print-unreadable-object (obj s :identity t)
          (format s "unprintable object"))))))
