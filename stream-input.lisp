;;; -*- Mode: Lisp; Package: CLIM-INTERNALS -*-

;;;  (c) copyright 1998,1999,2000 by Michael McDonald (mikemac@mikemac.com)
;;;  (c) copyright 2000 by 
;;;           Robert Strandh (strandh@labri.u-bordeaux.fr)
;;;  (c) copyright 2001,2002 by Tim Moore (moore@bricoworks.com)

;;; This library is free software; you can redistribute it and/or
;;; modify it under the terms of the GNU Library General Public
;;; License as published by the Free Software Foundation; either
;;; version 2 of the License, or (at your option) any later version.
;;;
;;; This library is distributed in the hope that it will be useful,
;;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;;; Library General Public License for more details.
;;;
;;; You should have received a copy of the GNU Library General Public
;;; License along with this library; if not, write to the 
;;; Free Software Foundation, Inc., 59 Temple Place - Suite 330, 
;;; Boston, MA  02111-1307  USA.

(in-package :clim-internals)

;;; X returns #\Return and #\Backspace where we want to see #\Newline
;;; and #\Delete at the stream-read-char level.  Dunno if this is the
;;; right place to do the transformation...

;;  Why exactly do we want to see #\Delete instead of #\Backspace?
;;  There is a seperate Delete key, unless your keyboard is strange. --Hefner

(defconstant +read-char-map+ '((#\Return . #\Newline) #+nil (#\Backspace . #\Delete)))

(defvar *abort-gestures* '(:abort))

(defvar *accelerator-gestures* nil)

(define-condition abort-gesture (condition)
  ((event :reader %abort-gesture-event :initarg :event)))

(defgeneric abort-gesture-event (condition))

(defmethod abort-gesture-event ((condition abort-gesture))
  (%abort-gesture-event condition))

(define-condition accelerator-gesture (condition)
  ((event :reader %accelerator-gesture-event :initarg :event)
   (numeric-argument :reader %accelerator-gesture-numeric-argument
		     :initarg :numeric-argument
		     :initform 1)))

(defgeneric accelerator-gesture-event (condition))

(defmethod accelerator-gesture-event ((condition accelerator-gesture))
  (%accelerator-gesture-event condition))

(defmethod accelerator-gesture-numeric-argument
    ((condition accelerator-gesture))
  (%accelerator-gesture-numeric-argument condition))

(defun char-for-read (char)
  (let ((new-char (cdr (assoc char +read-char-map+))))
    (or new-char char)))

(defun unmap-char-for-read (char)
  (let ((new-char (car (rassoc char +read-char-map+))))
    (or new-char char)))

;;; Streams are subclasses of standard-sheet-input-mixin regardless of
;;; whether or not we are multiprocessing.  In single-process mode the
;;; blocking calls to stream-read-char, stream-read-gesture are what
;;; cause process-next-event to be called.  It's most convenient to
;;; let process-next-event queue up events for the stream and then see
;;; what we've got after it returns.

(defclass standard-input-stream (fundamental-character-input-stream
				 standard-sheet-input-mixin)
  ((unread-chars :initform nil
		 :accessor stream-unread-chars)))

(defmethod stream-read-char ((pane standard-input-stream))
  (if (stream-unread-chars pane)
      (pop (stream-unread-chars pane))
      ;XXX
      (flet ((do-one-event (event)
	       (if (and (typep event 'key-press-event)
			(keyboard-event-character event))
		   (let ((char (char-for-read (keyboard-event-character
					       event))))
		     (stream-write-char pane char)
		     (return-from stream-read-char char))
		   (handle-event (event-sheet event) event))))
	(let* ((port (port pane))
	       (queue (stream-input-buffer pane)))
	  (loop
	   (let ((event (event-queue-read-no-hang queue)))
	     (cond (event
		    (do-one-event event))
		   (*multiprocessing-p*
		    (event-queue-listen-or-wait queue))
		   (t (process-next-event port)))))))))

(defmethod stream-unread-char ((pane standard-input-stream) char)
  (push char (stream-unread-chars pane)))

(defmethod stream-read-char-no-hang ((pane standard-input-stream))
  (if (stream-unread-chars pane)
      (pop (stream-unread-chars pane))
    (loop for event = (event-read-no-hang pane)
	if (null event)
	   return nil
	if (and (typep event 'key-press-event)
		(keyboard-event-character event))
	  return (char-for-read (keyboard-event-character event))
	else
	  do (handle-event (event-sheet event) event))))

(define-protocol-class extended-input-stream (fundamental-character-input-stream ;Gray stream
					      standard-sheet-input-mixin)
  ())

(defclass standard-extended-input-stream (extended-input-stream)
  ((pointer)
   (cursor :initarg :text-cursor)))

(defvar *input-wait-test* nil)
(defvar *input-wait-handler* nil)
(defvar *pointer-button-press-handler* nil)

(defgeneric stream-set-input-focus (stream))

(defmacro with-input-focus ((stream) &body body)
  (when (eq stream t)
    (setq stream '*standard-input*))
  (let ((old-stream (gensym "OLD-STREAM")))
    `(let ((,old-stream (stream-set-input-focus ,stream)))
       (unwind-protect (locally
			 ,@body)
	 (if ,old-stream
	     (stream-set-input-focus ,old-stream)
	     (setf (port-keyboard-input-focus (port ,stream)) nil))))))


(defun read-gesture (&key
		     (stream *standard-input*)
		     timeout
		     peek-p
		     (input-wait-test *input-wait-test*)
		     (input-wait-handler *input-wait-handler*)
		     (pointer-button-press-handler
		      *pointer-button-press-handler*))
  (stream-read-gesture stream
		       :timeout timeout
		       :peek-p peek-p
		       :input-wait-test input-wait-test
		       :input-wait-handler input-wait-handler
		       :pointer-button-press-handler
		       pointer-button-press-handler))

(defgeneric stream-read-gesture (stream
				 &key timeout peek-p
				 input-wait-test
				 input-wait-handler
				 pointer-button-press-handler))

;;; Do streams care about any other events?
(defun handle-non-stream-event (buffer)
  (let* ((event (event-queue-peek buffer))
	 (sheet (event-sheet event)))
    (if (and event
	     (or (gadgetp sheet)
		 (not (and (typep sheet 'clim-stream-pane)
			   (or (typep event 'key-press-event)
			       (typep event 'pointer-button-press-event))))))
	(progn
	  (event-queue-read buffer)	;eat it
	  (handle-event (event-sheet event) event)
	  t)
	nil)))

(defun pop-gesture (buffer peek-p)
  (if peek-p
      (event-queue-peek buffer)
      (event-queue-read-no-hang buffer)))


(defun repush-gesture (gesture buffer)
  (event-queue-prepend buffer gesture))

(defmethod convert-to-gesture ((ev event))
  nil)

(defmethod convert-to-gesture ((ev character))
  ev)

(defmethod convert-to-gesture ((ev symbol))
  ev)

(defmethod convert-to-gesture ((ev key-press-event))
  (let ((modifiers (event-modifier-state ev))
	(event ev)
	(char nil))
    (when (or (zerop modifiers)
	      (eql modifiers +shift-key+))
      (setq char (keyboard-event-character ev)))
    (if char
	(char-for-read char)
	event)))

(defmethod convert-to-gesture ((ev pointer-button-press-event))
  ev)

(defmethod stream-read-gesture ((stream standard-extended-input-stream)
				&key timeout peek-p
				(input-wait-test *input-wait-test*)
				(input-wait-handler *input-wait-handler*)
				(pointer-button-press-handler
				 *pointer-button-press-handler*))
  (with-encapsulating-stream (estream stream)
    (let ((*input-wait-test* input-wait-test)
	  (*input-wait-handler* input-wait-handler)
	  (*pointer-button-press-handler* pointer-button-press-handler)
	  (buffer (stream-input-buffer stream)))
      (tagbody
	 ;; Wait for input... or not
	 ;; XXX decay timeout.
       wait-for-char
       (multiple-value-bind (available reason)
	   (stream-input-wait estream
			      :timeout timeout
			      :input-wait-test input-wait-test)
	 (unless available
	   (case reason
	     (:timeout
	      (return-from stream-read-gesture (values nil
						       :timeout)))
	     (:input-wait-test
	      ;; input-wait-handler might leave the event for us.  This is
	      ;; actually quite messy; I'd like to confine handle-event to
	      ;; stream-input-wait, but we can't loop back to it because the
	      ;; input handler will continue to decline to read the event :(
	      (let ((event (event-queue-peek buffer)))
		(when input-wait-handler
		  (funcall input-wait-handler stream))
		(let ((current-event (event-queue-peek buffer)))
		  (when (or (not current-event)
			    (not (eq event current-event)))
		    ;; If there's a new event input-wait-test needs to take a
		    ;; look at it. 
		    (go wait-for-char)))))
	     (t (go wait-for-char)))))
	 ;; An event should  be in the stream buffer now.
	 (when (handle-non-stream-event buffer)
	   (go wait-for-char))
	 (let ((gesture (convert-to-gesture (pop-gesture buffer peek-p))))
	   ;; Sometimes key press events get generated with a key code for
	   ;; which there is no keysym.  This seems to happen on my machine
	   ;; when keys are hit rapidly in succession.  I'm not sure if this is
	   ;; a hardware problem with my keyboard, and this case is probably
	   ;; better handled in the backend, but for now the case below handles
	   ;; the problem. -- moore
	   (cond ((null gesture)
		  (go wait-for-char))
		 ((and pointer-button-press-handler
		       (typep gesture 'pointer-button-press-event))
		  (funcall pointer-button-press-handler stream gesture))
		 ((loop for gesture-name in *abort-gestures*
			thereis (event-matches-gesture-name-p gesture
							      gesture-name))
		  (signal 'abort-gesture :event gesture))
		 ((loop for gesture-name in *accelerator-gestures*
			thereis (event-matches-gesture-name-p gesture
							      gesture-name))
		  (signal 'accelerator-gesture :event gesture))
		 (t (return-from stream-read-gesture gesture))))
	 (go wait-for-char)))))


(defgeneric stream-input-wait (stream &key timeout input-wait-test))

(defmethod stream-input-wait ((stream standard-extended-input-stream)
			      &key timeout input-wait-test)
  (block exit
    (let* ((buffer (stream-input-buffer stream))
	   (port (port stream)))
      ;; Loop if not multiprocessing or if input-wait-test returns nil
      ;; XXX need to decay timeout on multiple trips through the loop
      (tagbody
       check-buffer
	 (let ((event (event-queue-peek buffer)))
	   (when event
	     (when (and input-wait-test (funcall input-wait-test stream))
	       (return-from exit (values nil :input-wait-test)))
	     (if (handle-non-stream-event buffer)
		 (go check-buffer)
		 (return-from exit t))))
	 ;; Event queue has been drained, time to block waiting for new events.
	 (if *multiprocessing-p*
	     (unless (event-queue-listen-or-wait buffer :timeout timeout)
	       (return-from exit (values nil :timeout)))
	     (multiple-value-bind (result reason)
		 (process-next-event port :timeout timeout)
	       (unless result
		 (return-from exit (values nil reason)))))
	 (go check-buffer)))))


(defun unread-gesture (gesture &key (stream *standard-input*))
  (stream-unread-gesture stream gesture))

(defgeneric stream-unread-gesture (stream gesture))

(defmethod stream-unread-gesture ((stream standard-extended-input-stream)
				  gesture)
  (with-encapsulating-stream (estream stream)
    (repush-gesture gesture (stream-input-buffer estream))))

;;; Standard stream methods on standard-extended-input-stream.  Ignore any
;;; pointer gestures in the input buffer.


(defun read-gesture-or-reason (stream &rest args)
  (multiple-value-bind (result reason)
      (apply #'stream-read-gesture stream args)
    (or result reason)))

(defun read-result-p (gesture)
  (or (characterp gesture)
      (member gesture '(:eof :timeout) :test #'eq)))

(defmethod stream-read-char ((stream standard-extended-input-stream))
  (with-encapsulating-stream (estream stream)
    (loop for char = (read-gesture-or-reason estream)
	  until (read-result-p char)
	  finally (return (char-for-read char)))))

(defmethod stream-read-char-no-hang ((stream standard-extended-input-stream))
  (with-encapsulating-stream (estream stream)
    (loop for char = (read-gesture-or-reason estream :timeout 0)
	  do (when (read-result-p char)
	       (loop-finish))
	  finally (return (cond ((eq char :eof)
				 :eof)
				((eq char :timeout)
				 nil)
				(t (char-for-read char)))))))

(defmethod stream-unread-char ((stream standard-extended-input-stream)
			       char)
  (with-encapsulating-stream (estream stream)
    (stream-unread-gesture estream (unmap-char-for-read char))))

(defmethod stream-peek-char ((stream standard-extended-input-stream))
  (with-encapsulating-stream (estream stream)
    (loop for char = (read-gesture-or-reason estream :peek-p t)
	  do (if (read-result-p char)
		 (loop-finish)
		 (stream-read-gesture estream)) ; consume pointer gesture
	  finally (return (char-for-read char)))))

(defmethod stream-listen ((stream standard-extended-input-stream))
  (with-encapsulating-stream (estream stream)
    (loop for char = (read-gesture-or-reason :timeout 0 :peek-p t)
	  do (if (read-result-p char)
		 (loop-finish)
		 (stream-read-gesture estream)) ; consume pointer gesture
	  finally (return (characterp char)))))


;;; stream-read-line returns a second value of t if terminated by eof.
(defmethod stream-read-line ((stream standard-extended-input-stream))
  (with-encapsulating-stream (estream stream)
    (let ((result (make-array 1
			      :element-type 'character
			      :adjustable t
			      :fill-pointer 0)))
      (loop for char = (stream-read-char estream)
	    while (and (characterp char) (not (char= char #\Newline)))
	    do (vector-push-extend char result)
	    finally (return (values (subseq result 0)
				    (not (characterp char))))))))

;;; stream-read-gesture on string strings.  Needed so
;;; accept-from-string "just works"

;;; XXX Evil hack because "string-stream" isn't the superclass of
;;; string streams in CMUCL/SBCL...

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defvar *string-input-stream-class* (with-input-from-string (s "foo")
					(class-name (class-of s)))))

(defmethod stream-read-gesture ((stream #.*string-input-stream-class*)
				&key peek-p
				&allow-other-keys)
  (let ((char (if peek-p
		  (peek-char nil stream nil nil)
		  (read-char stream nil nil))))
    (if char
	char
	(values nil :eof))))

(defmethod stream-unread-gesture ((stream #.*string-input-stream-class*)
				  gesture)
  (unread-char gesture stream))
;;; Gestures

(defparameter *gesture-names* (make-hash-table))

(defmacro define-gesture-name (name type gesture-spec &key (unique t))
  `(add-gesture-name ',name ',type ',gesture-spec ,@(and unique
							 `(:unique ',unique))))

;;; XXX perhaps this should be in the backend somewhere?
(defconstant +name-to-char+ '((:newline . #\newline)
			      (:linefeed . #\linefeed)
			      (:return . #\return)
			      (:tab . #\tab)
			      (:backspace . #\backspace)
			      (:page . #\page)
			      (:rubout . #\rubout)))

(defun add-gesture-name (name type gesture-spec &key unique)
  (destructuring-bind (device-name . modifiers)
      gesture-spec
    (let* ((modifier-state (apply #'make-modifier-state modifiers)))
      (cond ((and (eq type :keyboard)
		  (symbolp device-name))
	     (let ((real-device-name (cdr (assoc device-name +name-to-char+))))
	       (unless real-device-name
		 (error "~S is not a known key name" device-name))
	       (setq device-name real-device-name)))
	    ((and (member type '(:pointer-button
				 :pointer-button-press
				 :pointer-button-release)
			  :test #'eq))
	     (let ((real-device-name
		    (case device-name
		      (:left +pointer-left-button+)
		      (:middle +pointer-middle-button+)
		      (:right +pointer-right-button+)
		      (t (error "~S is not a known button" device-name)))))
	       (setq device-name real-device-name))))
      (let ((gesture-entry (list type device-name modifier-state)))
	(if unique
	    (setf (gethash name *gesture-names*) (list gesture-entry))
	    (push gesture-entry (gethash name *gesture-names*)))))))

(defgeneric character-gesture-name (name))

(defmethod character-gesture-name ((name character))
  name)

(defmethod character-gesture-name ((name symbol))
  (let ((entry (car (gethash name *gesture-names*))))
    (if entry
	(destructuring-bind (type device-name modifier-state)
	    entry
	  (if (and (eq type :keyboard)
		   (eql modifier-state 0))
	      device-name
	      nil))
	nil)))

(defgeneric %event-matches-gesture (event type device-name modifier-state))

(defmethod %event-matches-gesture (event type device-name modifier-state)
  (declare (ignore event type device-name modifier-state))
  nil)

(defmethod %event-matches-gesture ((event key-press-event)
				   (type (eql :keyboard))
				   device-name
				   modifier-state)
  (and (eql (keyboard-event-key-name event) device-name)
       (eql (event-modifier-state event) modifier-state)))

(defmethod %event-matches-gesture ((event pointer-button-press-event)
				   type
				   device-name
				   modifier-state)
  (and (or (eql type :pointer-button-press)
	   (eql type :pointer-button))
       (eql (pointer-event-button event) device-name)
       (eql (event-modifier-state event) modifier-state)))

(defmethod %event-matches-gesture ((event pointer-button-release-event)
				   type
				   device-name
				   modifier-state)
  (and (or (eql type :pointer-button-release)
	   (eql type :pointer-button))
       (eql (pointer-event-button event) device-name)
       (eql (event-modifier-state event) modifier-state)))

(defmethod %event-matches-gesture ((event pointer-button-event)
				   type
				   device-name
				   modifier-state)
  (and (or (eql type :pointer-button-press)
	   (eql type :pointer-button-release)
	   (eql type :pointer-button))
       (eql (pointer-event-button event) device-name)
       (eql (event-modifier-state event) modifier-state)))

;;; Because gesture objects are either characters or event objects, support
;;; characters here too.

(defmethod %event-matches-gesture ((event character)
				   (type (eql :keyboard))
				   device-name
				   modifier-state)
  (and (eql event device-name)
       (eql modifier-state 0)))

(defun event-matches-gesture-name-p (event gesture-name)
  (let ((gesture-entry (gethash gesture-name *gesture-names*)))
    (loop for (type device-name modifier-state) in gesture-entry
	  do (when (%event-matches-gesture event
					   type
					   device-name
					   modifier-state)
	       (return-from event-matches-gesture-name-p t))
	  finally (return nil))))

(defun modifier-state-matches-gesture-name-p (modifier-state gesture-name)
  (loop for (nil nil gesture-state) in (gethash gesture-name
							 *gesture-names*)
	do (when (eql gesture-state modifier-state)
	     (return-from modifier-state-matches-gesture-name-p t))
	finally (return nil)))


(defun make-modifier-state (&rest modifiers)
  (loop for result = 0 then (logior (case modifier
				      (:shift +shift-key+)
				      (:control +control-key+)
				      (:meta +meta-key+)
				      (:super +super-key+)
				      (:hyper +hyper-key+)
				      (t (error "~S is not a known modifier" modifier)))
				    result)
	for modifier in modifiers
	finally (return result)))

;;; Standard gesture names

(define-gesture-name :abort :keyboard (#\c :control))
(define-gesture-name :clear-input :keyboard (#\u :control))
(define-gesture-name :complete :keyboard (:tab))
(define-gesture-name :help :keyboard (#\/ :control))
(define-gesture-name :possibilities :keyboard (#\? :control))

(define-gesture-name :select :pointer-button-press (:left))
(define-gesture-name :describe :pointer-button-press (:middle))
(define-gesture-name :menu :pointer-button-press (:right))
(define-gesture-name :edit :pointer-button-press (:left :meta))
(define-gesture-name :delete :pointer-button-press (:middle :shift))

;;; Define so we have a gesture for #\newline that we can use in
;;; *standard-activation-gestures*

(define-gesture-name :newline :keyboard (#\newline))
(define-gesture-name :return :keyboard (#\return))

;;; The standard delimiter

(define-gesture-name command-delimiter :keyboard (#\space))

;;; Extension: support for handling abort gestures that appears to be
;;; in real CLIM

;;; From the hyperspec, more or less

(defun invoke-condition-restart (c)
  (let ((restarts (compute-restarts c)))
    (loop for i from 0
	  for restart in restarts
	  do (format t "~&~D: ~A~%" i restart))
    (loop with n = nil
	  and k = (length restarts)
	  until (and (integerp n) (>= n 0) (< n k))
	  do (progn
	       (format t "~&Option: ")
	       (setq n (read))
	       (fresh-line))
	  finally
	  #-cmu (invoke-restart (nth n restarts))
	  #+cmu (funcall (conditions::restart-function (nth n restarts))))))

(defmacro catch-abort-gestures (format-args &body body)
  `(restart-case
       (handler-bind ((abort-gesture #'invoke-condition-restart))
	 ,@body)
     (nil ()
       :report (lambda (s) (format s ,@format-args))
       :test (lambda (c) (typep c 'abort-gesture))
       nil)))

;;; 22.4 The Pointer Protocol
;;;
;;; Implemented by the back end.  Sort of.

(define-protocol-class pointer ()
  ((port :reader port :initarg :port)))

(defgeneric pointer-sheet (pointer))

(defmethod pointer-sheet ((pointer pointer))
  (port-pointer-sheet (port pointer)))

(defgeneric (setf pointer-sheet) (sheet pointer))

(defgeneric pointer-button-state (pointer))

(defgeneric pointer-modifier-state (pointer))

(defgeneric pointer-position (pointer))

(defgeneric* (setf pointer-position) (x y pointer))

(defgeneric pointer-cursor (pointer))

(defgeneric (setf pointer-cursor) (cursor pointer))

;;; Should this go in sheets.lisp?  That comes before events and ports...

(defmethod handle-event :before ((sheet mirrored-sheet-mixin)
				 (event pointer-enter-event))
  (setf (port-pointer-sheet (port sheet)) sheet))

(defmethod handle-event :before ((sheet mirrored-sheet-mixin)
				 (event pointer-exit-event))
  (with-accessors ((port-pointer-sheet port-pointer-sheet))
      (port sheet)
    (when (eq port-pointer-sheet sheet)
      (setq port-pointer-sheet nil))))

(defgeneric stream-pointer-position (stream &key pointer))

(defmethod stream-pointer-position ((stream standard-extended-input-stream)
				    &key (pointer
					  (port-pointer (port stream))))
  (multiple-value-bind (x y)
      (pointer-position pointer)
    (let ((pointer-sheet (port-pointer-sheet (port stream))))
      (if (eq stream pointer-sheet)
	  (values x y)
	  ;; Is this right?
	  (multiple-value-bind (native-x native-y)
	      (transform-position (sheet-native-transformation stream) x y)
	    (untransform-position (sheet-native-transformation pointer-sheet)
				  native-x
				  native-y))))))
