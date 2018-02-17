;;;; Copyright (c) 2017-2018 Bruno Cichon <ebrasca@librepanther.com>
;;;; This code is licensed under the MIT license.
;;;; For now support reading fat32 FS and some write operations.

(defpackage :mezzano.fat32-file-system
  (:use :cl :mezzano.file-system)
  (:export)
  (:import-from :sys.int
                #:explode))

(in-package :mezzano.fat32-file-system)

(defstruct fat32
  (boot-jmp nil)
  (oem-name nil :type string)
  (bytes-per-sector nil :type (unsigned-byte 16))
  (sectors-per-cluster nil :type (unsigned-byte 8))
  (reserved-sector-count nil :type (unsigned-byte 16))
  (table-count nil :type (unsigned-byte 8))
  (root-entry-count nil :type (unsigned-byte 16))
  (total-sectors16 nil :type (unsigned-byte 16))
  (media-type nil :type (unsigned-byte 8))
  (table-size-16 nil :type (unsigned-byte 16))
  (sectors-per-track nil :type (unsigned-byte 16))
  (head-side-count nil :type (unsigned-byte 16))
  (hidden-sector-count nil :type (unsigned-byte 32))
  (total-sectors32 nil :type (unsigned-byte 32))
  ;;fat32
  (table-size-32 nil :type (unsigned-byte 32))
  (extended-flags nil)
  (fat-version nil)
  (root-cluster nil :type (unsigned-byte 32))
  (fat-info nil :type (unsigned-byte 16))
  (backup-BS-sector nil :type (unsigned-byte 16))
  (reserved-0 nil)
  (drive-number nil :type (unsigned-byte 8))
  (reserved-1 nil)
  (boot-signature nil :type (unsigned-byte 8))
  (volume-id nil :type (unsigned-byte 32))
  (volume-label nil :type string)
  (fat-type-label nil :type string)
  (bc nil) ; 90 420
  (bps nil :type (unsigned-byte 32)))

(defconstant +bootable-partition-signature+ #xAA55)

(defun check-boot-jmp (boot-jmp)
  (let ((n0 (aref boot-jmp 0))
        (n2 (aref boot-jmp 2)))
    (if (or (and (= n0 #xEB)
                 (= n2 #x90))
            (= n0 #xE9))
        boot-jmp
        (error "Bad boot-jmp : ~a .
Valid forms are : #(#xEB x #x90) and #(#xE9 x x).
X is for some 1 byte number." boot-jmp))))

(defun check-bytes-per-sector (bytes-per-sector)
  "Ensure that bytes-per-sector is valid."
  (loop :for n :in '(512 1024 2048 4096)
        :do (when (= n bytes-per-sector)
              (return bytes-per-sector))
        :finally (error "Bad bytes-per-sector : ~a .
Valid bytes-per-sector are 512, 1024, 2048 and 4096" bytes-per-sector)))

(defun check-sectors-per-cluster (sectors-per-cluster bytes-per-sector)
  (loop :for n :in '(1 2 4 8 16 32 64 128)
        :do (when (= n sectors-per-cluster)
              (return sectors-per-cluster))
        :finally (error "Bad sectors-per-cluster : ~a .
Valid bytes-per-sector are 1,2,4,8,16,32,64,128" sectors-per-cluster))
  (when (> (* sectors-per-cluster bytes-per-sector)
           32768)
    (error "Error sectors-per-cluster * bytes-per-sector > 32KiB .
sectors-per-cluster= ~a bytes-per-sector= ~a" sectors-per-cluster bytes-per-sector))
  sectors-per-cluster)

(defun check-media-type (media-type)
  (loop :for n :in '(#xF0 #xF8 #xF9 #xFA #xFB #xFC #xFD #xFE #xFF)
        :do (when (= n media-type)
              (return media-type))
        :finally (error "Bad media-type : ~a .
Valid media-type ara #xF0 #xF8 #xF9 #xFA #xFB #xFC #xFD #xFE #xFF" media-type)))

(defun check-fat-type-label32 (fat-type-label)
  (if (string= "FAT32   " fat-type-label)
      fat-type-label
      (error "Bad fat-type-label : ~a .
Valid media-type ara 'FAT32   ' " fat-type-label)))

(defun check-bps (bps)
  (unless (= bps +bootable-partition-signature+)
    (error "Bad bps : ~a .
Valid bps are ~a" bps +bootable-partition-signature+))
  bps)

(defun read-fat32-structure (sector)
  (let ((boot-jmp (subseq sector 0 3))
        (bytes-per-sector (sys.int::ub16ref/le sector 11))
        (sectors-per-cluster (aref sector 13))
        (table-count (aref sector 16))
        (root-entry-count (sys.int::ub16ref/le sector 17))
        (total-sectors16 (sys.int::ub16ref/le sector 19))
        (media-type (aref sector 21))
        (table-size-16 (sys.int::ub16ref/le sector 22))
        (total-sectors32 (sys.int::ub32ref/le sector 32))
        (fat-type-label (map 'string #'code-char (subseq sector 82 90)))
        (bps (sys.int::ub16ref/le sector 510)))
    (check-boot-jmp boot-jmp)
    (check-bytes-per-sector bytes-per-sector)
    (check-sectors-per-cluster sectors-per-cluster bytes-per-sector)
    (assert (>= table-count 1))
    (assert (= 0 root-entry-count))
    (assert (= 0 total-sectors16))
    (check-media-type media-type)
    (assert (= table-size-16 0))
    (assert (not (zerop total-sectors32)))
    (check-fat-type-label32 fat-type-label)
    (check-bps bps)
    (values
     (make-fat32
      :boot-jmp boot-jmp
      :oem-name (map 'string #'code-char (subseq sector 3 11))
      :bytes-per-sector bytes-per-sector
      :sectors-per-cluster sectors-per-cluster
      :reserved-sector-count (sys.int::ub16ref/le sector 14)
      :table-count table-count
      :root-entry-count root-entry-count
      :total-sectors16 total-sectors16
      :media-type media-type
      :table-size-16 table-size-16
      :sectors-per-track (sys.int::ub16ref/le sector 24)
      :head-side-count (sys.int::ub16ref/le sector 26)
      :hidden-sector-count (sys.int::ub32ref/le sector 28)
      :total-sectors32 total-sectors32
      :table-size-32 (sys.int::ub32ref/le sector 36)
      :extended-flags (sys.int::ub16ref/le sector 40)
      ;; high byte is major revision number and low byte is minor revision number
      :fat-version (sys.int::ub16ref/le sector 42)
      :root-cluster (sys.int::ub32ref/le sector 44)
      :fat-info (sys.int::ub16ref/le sector 48)
      :backup-BS-sector (sys.int::ub16ref/le sector 50)
      :reserved-0 (logior (ash (sys.int::ub32ref/le sector 60) 64)
                          (sys.int::ub64ref/le sector 52))
      :drive-number (aref sector 64) ; Operating system specific
      :reserved-1 (aref sector 65)
      :boot-signature (aref sector 66)
      :volume-id (sys.int::ub32ref/le sector 67)
      :volume-label (map 'string #'code-char (subseq sector 71 82))
      :fat-type-label fat-type-label
      :bc nil
      :bps bps))))

(defstruct fs-info
  (lead-signature nil :type (unsigned-byte 32))
  (reserved-0 nil) ; 4 480
  (structure-signature nil :type (unsigned-byte 32))
  (last-free-cluster nil :type (unsigned-byte 32))
  (next-free-cluster nil :type (unsigned-byte 32))
  (reserved-1 nil) ; 496 12
  (trail-signature nil :type (unsigned-byte 32)))

(defconstant +lead-signature+ #x41615252)
(defconstant +structure-signature+ #x61417272)
(defconstant +trail-signature+ #xAA550000)

(defun check-lead-signature (lead-signature)
  (if (= lead-signature +lead-signature+)
      lead-signature
      (error "Bad lead-signature : ~a .
Valid lead-signature is ~a" lead-signature +lead-signature+)))

(defun check-structure-signature (structure-signature)
  (if (= structure-signature +structure-signature+)
      structure-signature
      (error "Bad structure-signature : ~a .
Valid structure-signature is ~a" structure-signature +structure-signature+)))

(defun check-trail-signature (trail-signature)
  (if (= trail-signature +trail-signature+)
      trail-signature
      (error "Bad trail-signature : ~a .
Valid trail-signature is ~a" trail-signature +trail-signature+)))

(defun read-fat32-info-structure (sector)
  (let ((lead-signature (sys.int::ub32ref/le sector 0))
        (structure-signature (sys.int::ub32ref/le sector 484))
        (trail-signature (sys.int::ub32ref/le sector 508)))
    (check-lead-signature lead-signature)
    (check-structure-signature structure-signature)
    (check-trail-signature trail-signature)
    (make-fs-info
     :lead-signature lead-signature
     :reserved-0 nil
     :structure-signature structure-signature
     :last-free-cluster (sys.int::ub32ref/le sector 488)
     :next-free-cluster (sys.int::ub32ref/le sector 492)
     :reserved-1 nil
     :trail-signature trail-signature)))

(defun root-dir-sectors ()
  0)

(defun data-sectors (fat32)
  (- (fat32-total-sectors32 fat32)
     (+ (fat32-reserved-sector-count fat32)
        (* (fat32-table-count fat32)
           (fat32-table-size-32 fat32))
        (root-dir-sectors))))

(defun total-clusters (fat32)
  (floor
   (/ (data-sectors fat32)
      (fat32-sectors-per-cluster fat32))))

(defun first-data-sector (fat32)
  (+ (fat32-reserved-sector-count fat32)
     (* (fat32-table-count fat32)
        (fat32-table-size-32 fat32))
     (root-dir-sectors)))

(defun first-root-dir-sector (fat32)
  (- (first-data-sector fat32)
     (root-dir-sectors)))

(defun first-sector-of-cluster (fat32 cluster)
  (+ (* (- cluster 2)
        (fat32-sectors-per-cluster fat32))
     (first-data-sector fat32)))

(defun bytes-per-cluster (fat32)
  (* (fat32-sectors-per-cluster fat32)
     (fat32-bytes-per-sector fat32)))

(defun read-sector (disk sector n)
  "Read sectors from disk"
  (let* ((array (make-array (* n (mezzano.supervisor:disk-sector-size disk))
                            :area :wired :element-type '(unsigned-byte 8))))
    (multiple-value-bind (successp error-reason) (mezzano.supervisor:disk-read disk sector n array)
      (when (not successp)
        (error "Disk read error: ~S" error-reason)))
    array))

(defun write-sector (disk sector array n)
  "Write sectors to disk"
  (multiple-value-bind (successp error-reason) (mezzano.supervisor:disk-write disk sector n array)
    (when (not successp)
      (error "Disk write error: ~S" error-reason))))

(defun read-cluster (fat32 disk cluster-sector)
  "Read cluster from cluster"
  (let* ((spc (fat32-sectors-per-cluster fat32))
         (cluster (make-array (* spc (mezzano.supervisor:disk-sector-size disk))
                              :area :wired :element-type '(unsigned-byte 8))))
    (multiple-value-bind (successp error-reason) (mezzano.supervisor:disk-read disk cluster-sector spc cluster)
      (when (not successp)
        (error "Disk read error: ~S" error-reason)))
    cluster))

(defun write-cluster (disk cluster-sector fat32 array)
  "Write cluster to disk"
  (multiple-value-bind (successp error-reason)
      (mezzano.supervisor:disk-write disk cluster-sector (fat32-sectors-per-cluster fat32) array)
    (when (not successp)
      (error "Disk write error: ~S" error-reason))))

;;; bit offsets
(defconstant +attribute-read-only+ 0)
(defconstant +attribute-hidden+ 1)
(defconstant +attribute-system+ 2)
(defconstant +attribute-volume-id+ 3)
(defconstant +attribute-directory+ 4)
(defconstant +attribute-archive+ 5)

(defun file-p (cluster offset)
  (/= (ldb (byte 1 +attribute-directory+)
           (aref cluster (+ 11 offset)))
      1))

(defun read-file (fat32 disk cluster-n fat)
  (let ((file-buffer #()))
    (do ((sector (read-sector disk (fat32-reserved-sector-count fat32) 1))
         (i cluster-n
            (sys.int::ub32ref/le fat (* i 4))))
        ((>= i #x0FFFFFF8) file-buffer)
      (setf file-buffer
            (concatenate 'vector
                         file-buffer
                         (read-cluster fat32 disk
                                       (first-sector-of-cluster fat32 i)))))))

(defun read-first-cluster (cluster offset)
  (logior (ash (sys.int::ub16ref/le cluster (+ 20 offset)) 16)
          (ash (sys.int::ub16ref/le cluster (+ 26 offset)) 0)))

(defun read-size (cluster offset)
  (sys.int::ub32ref/le cluster (+ 28 offset)))

(defun checksum (cluster offset)
  "Return checksum of sort name"
  (loop :with sum := 0
        :for i :from offset :to (+ 10 offset)
        :for octet := (aref cluster i)
        :do (setf sum
                  (ldb (byte 8 0)
                       (+ (ash sum -1)
                          (ash (logand sum 1) 7) ; rotate
                          octet))) ; add next name byte
        :finally (return sum)))

(defun next-file (cluster offset)
  (do ((i offset (+ 32 i)))
      ((<= (length cluster) i) nil)
    (let ((first-byte (aref cluster i)))
      (unless (or (zerop first-byte)
                  (= #xE5 first-byte))
        (unless (= #x0F (aref cluster (+ 11 i)))
          (return i))))))

(defmacro do-files ((var) cluster &body body)
  `(do ((,var (next-file ,cluster 0) (next-file ,cluster (+ 32 ,var))))
       ((null ,var)
        t)
     ,@body))

(defun read-name (cluster offset)
  (with-output-to-string (s)
    (loop :for i :from offset :to (+ 10 offset)
          :for octet := (aref cluster i)
          :do (write-char (code-char octet) s))))

(defmacro with-file ((var start) cluster finally &body body)
  (alexandria:with-gensyms (checksum)
    `(do ((,checksum (checksum ,cluster ,start))
          (,var ,start (- ,var 32)))
         ((zerop ,var)
          ,finally)
       (when (= ,checksum
                (aref ,cluster (+ 13 ,var)))
         ,@body))))

(defun read-long-name (cluster start)
  (let ((name ""))
    (with-file (i start) cluster
      '()
      (progn (setf name
                   (concatenate 'string name
                                (with-output-to-string (sub-name)
                                  (flet ((add (start end)
                                           (loop :for offset :from (+ start i) :to (+ end i)
                                                 :for octet := (aref cluster offset)
                                                 :when (and (/= octet 0)
                                                            (/= octet 255))
                                                 :do (write-char (code-char octet) sub-name))))
                                    (add 1 10)
                                    (add 14 25)
                                    (add 28 31)))))
             (when (= #x41 (aref cluster i))
               (return name))))))

(defun remove-file (cluster start disk sector fat32)
  (with-file (i start) cluster
    (write-cluster disk
                   sector
                   fat32
                   cluster)
    (setf (aref cluster i)
          #xE5)))

;;; Host integration

(defclass fat32-host ()
  ((%name :initarg :name
          :reader host-name)
   (%lock :initarg :lock
          :reader fat32-host-lock)
   (partition :initarg :partition
              :reader partition)
   (fat32-structure :initarg :fat32-structure
                    :reader fat32-structure)
   (fat32-info :initarg :fat32-info
               :reader fat32-info)
   (fat :initarg :fat
        :reader fat))
  (:default-initargs :lock (mezzano.supervisor:make-mutex "Local File Host lock")))

(defmethod host-default-device ((host fat32-host))
  nil)

(defun parse-simple-file-path (host namestring)
  (let ((start 0)
        (end (length namestring))
        (directory '())
        (name nil)
        (type nil))
    (when (eql start end)
      (return-from parse-simple-file-path (make-pathname :host host)))
    (cond ((eql (char namestring start) #\>)
           (push :absolute directory)
           (incf start))
          (t (push :relative directory)))
    ;; Last element is the name.
    (do* ((x (explode #\> namestring start end) (cdr x)))
         ((null (cdr x))
          (let* ((name-element (car x))
                 (end (length name-element)))
            (unless (zerop (length name-element))
              ;; Find the last dot.
              (let ((dot-position (position #\. name-element :from-end t)))
                (cond ((and dot-position (not (zerop dot-position)))
                       (setf type (subseq name-element (1+ dot-position) end))
                       (setf name (subseq name-element 0 dot-position)))
                      (t (setf name (subseq name-element 0 end))))))))
      (let ((dir (car x)))
        (cond ((or (string= "" dir)
                   (string= "." dir)))
              ((string= ".." dir)
               (push :up directory))
              ((string= "*" dir)
               (push :wild directory))
              ((string= "**" dir)
               (push :wild-inferiors directory))
              (t (push dir directory)))))
    (when (string= name "*") (setf name :wild))
    (when (string= type "*") (setf type :wild))
    (make-pathname :host host
                   :directory (nreverse directory)
                   :name name
                   :type type
                   :version :newest)))

(defmethod parse-namestring-using-host ((host fat32-host) namestring junk-allowed)
  (assert (not junk-allowed) (junk-allowed) "Junk-allowed not implemented yet")
  (parse-simple-file-path host namestring))

(defmethod unparse-pathname (pathname (host fat32-host))
  (when (pathname-device pathname)
    (error 'no-namestring-error
           :pathname pathname
           :format-control "Pathname has a device component"))
  (let ((dir (pathname-directory pathname))
        (name (pathname-name pathname))
        (type (pathname-type pathname)))
    (with-output-to-string (s)
      (when (eql (first dir) :absolute)
        (write-char #\> s))
      (dolist (sub-dir (rest dir))
        (cond
          ((stringp sub-dir) (write-string sub-dir s))
          ((eql sub-dir :up) (write-string ".." s))
          ((eql sub-dir :wild) (write-char #\* s))
          ((eql sub-dir :wild-inferiors) (write-string "**" s))
          (t
           (error 'no-namestring-error
                  :pathname pathname
                  :format-control "Invalid directory component ~S."
                  :format-arguments (list sub-dir))))
        (write-char #\> s))
      (if (eql name :wild)
          (write-char #\* s)
          (write-string name s))
      (when type
        (write-char #\. s)
        (if (eql type :wild)
            (write-char #\* s)
            (write-string type s)))
      s)))

(defclass fat32-file-stream (sys.gray:fundamental-binary-input-stream
                             sys.gray:fundamental-binary-output-stream
                             file-stream)
  ((path :initarg :path :reader path) ;<
   (pathname :initarg :pathname :reader file-stream-pathname)
   (host :initarg :host :reader host)
   (direction :initarg :direction :reader direction)
   ;; Read buffer.
   (read-buffer :initarg :read-buffer
                :accessor read-buffer)
   ;; File position where the buffer data starts.
   (read-buffer-position :initarg :read-buffer-position
                         :initform 0
                         :accessor read-buffer-position)
   ;; Current offset into the buffer.
   (buffer-offset :initarg :buffer-offset
                  :accessor buffer-offset)
   ;; File size
   (read-buffer-size :initarg :read-buffer-size
                     :initform 0
                     :accessor read-buffer-size)
   ;; Write buffer.
   (write-buffer :initarg :write-buffer
                 :initform nil
                 :accessor write-buffer) ;<
   (write-buffer-position :initarg :write-buffer-position
                          :initform 0
                          :accessor write-buffer-position) ;<
   (abort-action :initarg :abort-action :accessor abort-action)))

(defclass fat32-file-character-stream (sys.gray:fundamental-character-input-stream
                                       sys.gray:fundamental-character-output-stream
                                       fat32-file-stream
                                       sys.gray:unread-char-mixin)
  ())

(defmacro with-fat32-host-locked ((host) &body body)
  `(mezzano.supervisor:with-mutex ((fat32-host-lock ,host))
     ,@body))

(defun file-name (path)
  "Return file name"
  (unless (or (eql :wild (pathname-name path))
              (eql :wild (pathname-type path)))
    (if (pathname-type path)
        (concatenate 'string (pathname-name path) "." (pathname-type path))
        (pathname-name path))))

(defun find-file (host pathname)
  (loop :with fat32 := (fat32-structure host)
        :with disk := (partition host)
        :with file-name := (file-name pathname)
        :with cluster-sector := (first-root-dir-sector fat32)
        :with cluster := (read-file fat32
                                    disk
                                    (fat32-root-cluster fat32)
                                    (fat host))
        :for file :in (rest (pathname-directory pathname))
        :do (do-files (start) cluster
              (when (string= file (read-long-name cluster start))
                (let ((directory (read-file fat32
                                            disk
                                            (read-first-cluster cluster start)
                                            (fat host))))
                  (setf cluster directory
                        cluster-sector (first-sector-of-cluster fat32
                                                                directory)))))
        :finally (do-files (start) cluster
                   (when (string= file-name (read-long-name cluster start))
                     (return-from find-file (values cluster cluster-sector start))))))

(defmethod delete-file-using-host ((host fat32-host) path &key)
  (let* ((disk (partition host))
         (fat32 (fat32-structure host)))
    (multiple-value-bind (cluster cluster-sector start) (find-file host path)
      (remove-file cluster
                   start
                   disk
                   cluster-sector
                   fat32))))

(defun write-file-size (stream)
  (let* ((host (host stream))
         (path (file-stream-pathname stream))
         (file-length (read-buffer-size stream))
         (disk (partition host))
         (fat32 (fat32-structure host)))
    (multiple-value-bind (cluster cluster-sector offset) (find-file host path)
      (when offset
        (setf (aref cluster (+ 28 offset)) (ldb (byte 8 0) file-length)
              (aref cluster (+ 29 offset)) (ldb (byte 8 8) file-length)
              (aref cluster (+ 30 offset)) (ldb (byte 8 16) file-length)
              (aref cluster (+ 31 offset)) (ldb (byte 8 24) file-length))

        (write-cluster disk
                       cluster-sector
                       fat32
                       cluster)))))

;; WIP
(defmethod open-using-host ((host fat32-host) pathname
                            &key direction element-type if-exists if-does-not-exist external-format)
  (with-fat32-host-locked (host)
    (let ((buffer nil)
          (read-buffer-position 0)
          (buffer-offset 0)
          (read-buffer-size 0)
          (created-file nil)
          (abort-action nil))

      (multiple-value-bind (cluster cluster-sector start) (find-file host pathname)
        (if start
            (progn (setf buffer (read-file (fat32-structure host)
                                           (partition host)
                                           (read-first-cluster cluster start)
                                           (fat host))
                         read-buffer-position (first-sector-of-cluster (fat32-structure host)
                                                                       (read-first-cluster cluster start))
                         read-buffer-size (read-size cluster start)))
            (ecase if-does-not-exist
              (:error (error 'simple-file-error
                             :pathname pathname
                             :format-control "File ~A does not exist. ~S"
                             :format-arguments (list pathname (pathname-name pathname))))
              (:create (setf created-file t
                             abort-action :delete)
               (error "Feature :create not implemented for :if-does-not-exist")))))

      (when (and (not created-file) (member direction '(:output :io)))
        (ecase if-exists
          (:error (error 'simple-file-error
                         :pathname pathname
                         :format-control "File ~A exists."
                         :format-arguments (list pathname)))
          ((:new-version
            :rename
            :rename-and-delete)
           (when t
             (error 'simple-file-error
                    :pathname pathname
                    :format-control "Could not rename ~S."
                    :format-arguments (list pathname)))
           (when t
             (error 'simple-file-error
                    :pathname pathname
                    :format-control "Could not supersede ~S."
                    :format-arguments (list pathname)))
           (when created-file
             (error "Cannot create ~A. ~S" pathname)))
          (:supersede
           (setf abort-action :delete)
           (when nil
             (error 'simple-file-error
                    :pathname pathname
                    :format-control "Could not supersede ~S."
                    :format-arguments (list pathname)))
           (unless created-file
             (error "Cannot create ~A. ~S" pathname)))
          ((:overwrite) t)
          ((:append)
           (setf buffer-offset read-buffer-size))
          ((nil) (return-from open-using-host nil))))
      (let ((stream (cond ((or (eql element-type :default)
                               (subtypep element-type 'character))
                           (assert (member external-format '(:default :utf-8))
                                   (external-format))
                           (make-instance 'fat32-file-character-stream
                                          :pathname pathname
                                          :host host
                                          :direction direction
                                          :read-buffer buffer
                                          :read-buffer-position read-buffer-position
                                          :buffer-offset buffer-offset
                                          :read-buffer-size read-buffer-size))
                          ((and (subtypep element-type '(unsigned-byte 8))
                                (subtypep '(unsigned-byte 8) element-type))
                           (assert (eql external-format :default) (external-format))
                           (make-instance 'fat32-file-stream
                                          :pathname pathname
                                          :host host
                                          :direction direction
                                          :read-buffer buffer
                                          :read-buffer-position read-buffer-position
                                          :buffer-offset buffer-offset
                                          :read-buffer-size read-buffer-size))
                          (t (error "Unsupported element-type ~S." element-type)))))
        stream))))

(defmethod directory-using-host ((host fat32-host) pathname &key)
  (let ((cluster (find-file host pathname)))
    (let (stack '())
      (do-files
          (file) cluster
        (push
         (parse-simple-file-path host
                                 (format nil
                                         (if (file-p cluster file)
                                             "~a~a"
                                             "~a~a>")
                                         (unparse-pathname-directory pathname host)
                                         (read-long-name cluster file)))
         stack))
      (return-from directory-using-host stack))))

;; WIP
(defmethod ensure-directories-exist-using-host ((host fat32-host) pathname &key verbose)
  (error "Feature not implemented: ~a" 'ensure-directories-exist-using-host))

;; WIP
(defmethod rename-file-using-host ((host fat32-host) source dest)
  (error "Feature not implemented: ~a" 'rename-file-using-host))

;; WIP
(defmethod file-write-date-using-host ((host fat32-host) path)
  (error "Feature not implemented: ~a" 'file-write-date-using-host))

(defmethod delete-file-using-host ((host fat32-host) path &key)
  (let* ((disk (partition host))
         (fat32 (fat32-structure host)))
    (multiple-value-bind (cluster cluster-sector start) (find-file host path)
      (remove-file cluster
                   start
                   disk
                   cluster-sector
                   fat32))))

(defmethod expunge-directory-using-host ((host fat32-host) path &key)
  (declare (ignore host path))
  t)

;; Sort name eql truename?
(defmethod stream-truename ((stream fat32-file-stream))
  (file-stream-pathname stream))

(defmethod sys.gray:stream-element-type ((stream fat32-file-stream))
  '(unsigned-byte 8))

(defmethod sys.gray:stream-element-type ((stream fat32-file-character-stream))
  'character)

;; WIP
;; TODO resize to files bigger than 1 cluster
(defmethod sys.gray:stream-write-byte ((stream fat32-file-stream) byte)
  (assert (member (direction stream) '(:output :io)))
  (when (> (buffer-offset stream)
           (read-buffer-size stream))
    (setf (read-buffer-size stream)
          (buffer-offset stream)))
  (setf (aref (read-buffer stream)
              (buffer-offset stream))
        byte)
  (incf (buffer-offset stream)))

(defmethod sys.gray:stream-read-byte ((stream fat32-file-stream))
  (assert (member (direction stream) '(:input :io)))
  (let ((char (aref (read-buffer stream)
                    (buffer-offset stream))))
    (incf (buffer-offset stream))
    (if (<= (read-buffer-size stream)
            (buffer-offset stream))
        :eof
        char)))

(defmethod sys.gray:stream-read-sequence ((stream fat32-file-stream) sequence &optional (start 0) end)
  (assert (member (direction stream) '(:input :io)))
  (unless end (setf end (length sequence)))
  (let ((end2 (min end (read-buffer-size stream))))
    (replace sequence (read-buffer stream) :start1 start :end1 end :start2 0 :end2 end2)
    end2))

;; WIP
;; TODO resize to files bigger than 1 cluster
(defmethod sys.gray:stream-write-char ((stream fat32-file-character-stream) char)
  (assert (member (direction stream) '(:output :io)))
  (when (> (buffer-offset stream)
           (read-buffer-size stream))
    (setf (read-buffer-size stream)
          (buffer-offset stream)))
  (setf (aref (read-buffer stream)
              (buffer-offset stream))
        (char-code char))
  (incf (buffer-offset stream)))

(defmethod sys.gray:stream-read-char ((stream fat32-file-character-stream))
  (assert (member (direction stream) '(:input :io)))
  (let ((char (aref (read-buffer stream)
                    (buffer-offset stream))))
    (incf (buffer-offset stream))
    (if (<= (read-buffer-size stream)
            (buffer-offset stream))
        :eof
        (code-char char))))

(defmethod sys.gray:stream-read-sequence ((stream fat32-file-character-stream) sequence &optional (start 0) end)
  (assert (member (direction stream) '(:input :io)))
  (unless end (setf end (length sequence)))
  (let ((end2 (min end (read-buffer-size stream))))
    (loop :for n1 :from start :to (1- end)
          :for n2 :to (1- end2)
          :do (setf (aref sequence n1)
                    (code-char (aref (read-buffer stream) n2))))
    end2))

(defmethod sys.gray:stream-file-position ((stream fat32-file-stream) &optional (position-spec nil position-specp))
  (error "Feature not implemented: ~a" 'sys.gray:stream-file-position))

(defmethod sys.gray:stream-file-length ((stream fat32-file-stream))
  (read-buffer-size stream))

;; WIP
;; TODO Change access-date , write-time and write-date.
;; FIXME Don't make smaler file size
;; Write don't work with multi clusters
(defmethod close ((stream fat32-file-stream) &key abort)
  ;; (cond ((not abort)
  ;;        (write-cluster (partition (host stream))
  ;;                       (read-buffer-position stream)
  ;;                       (fat32-structure (host stream))
  ;;                       (read-buffer stream))
  ;;        (write-file-size stream))
  ;;       (t (error "Aborted close not suported")))
  t)

;;; testing

;; Mount partition
;; (let* ((disk-name "FAT32")
;;        (disk (nth 3 (mezzano.supervisor:all-disks)))
;;        (fat32 (read-fat32-structure (read-sector disk 0 1)))
;;        (fat32-info (read-fat32-info-structure (read-sector disk (fat32-fat-info fat32) 1)))
;;        (fat (read-sector disk
;;                          (fat32-reserved-sector-count fat32)
;;                          (/ (fat32-table-size-32 fat32)
;;                             (fat32-table-count fat32))))
;;        (instance (make-instance 'fat32-host
;;                                 :name disk-name
;;                                 :partition disk
;;                                 :fat32-structure fat32
;;                                 :fat32-info fat32-info
;;                                 :fat fat)))
;;   (setf (mezzano.file-system:find-host disk-name)
;;         instance))

;; (let ((path #P"FAT32:>file5"))
;;   ;; Write to some file
;;   (time
;;    (with-open-file (file path :direction :output :if-exists :overwrite)
;;      (loop for i to (read-buffer-size file)
;;            do (write-byte (ldb (byte 8 0) i) file))))
;;   ;; Read some file
;;   (time
;;    (with-open-file (file path)
;;      (loop for char = (read-char file nil nil)
;;            while char do (write-char char)))))
