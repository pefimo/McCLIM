;;; -*- Mode: Lisp; -*-

;;;  (c) 2006 David Lichteblau (david@lichteblau.com)

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

(in-package :clim-gtkairo)

;;; Locking rule for this file: The entire event loop grabs the GTK
;;; lock, individual callees don't.

(defvar *keysyms* (make-hash-table))

(defmacro define-keysym (name id)
  `(setf (gethash ,id *keysyms*) ',name))

(defun connect-signal (widget name sym)
  (g-signal-connect widget name (cffi:get-callback sym)))

(defun connect-signals (widget)
  (gtk_widget_add_events widget
			 (logior GDK_POINTER_MOTION_MASK
				 GDK_BUTTON_PRESS_MASK
				 GDK_BUTTON_RELEASE_MASK
				 GDK_KEY_PRESS_MASK
				 GDK_KEY_RELEASE_MASK
				 GDK_ENTER_NOTIFY_MASK
				 GDK_LEAVE_NOTIFY_MASK
				 #+nil GDK_STRUCTURE_MASK))
  (setf (gtkwidget-flags widget)
        (logior (gtkwidget-flags widget) GTK_CAN_FOCUS))
  (connect-signal widget "expose-event" 'expose-handler)
  (connect-signal widget "motion-notify-event" 'motion-notify-handler)
  (connect-signal widget "button-press-event" 'button-handler)
  (connect-signal widget "button-release-event" 'button-handler)
  (connect-signal widget "key-press-event" 'key-handler)
  (connect-signal widget "key-release-event" 'key-handler)
  (connect-signal widget "enter-notify-event" 'enter-handler)
  (connect-signal widget "leave-notify-event" 'leave-handler)
  (connect-signal widget "configure-event" 'configure-handler)
  ;; override gtkwidget's focus handlers, which trigger an expose event,
  ;; causing unnecessary redraws for mouse movement
  (connect-signal widget "focus-in-event" 'noop-handler)
  (connect-signal widget "focus-out-event" 'noop-handler))

(defun connect-window-signals (widget)
  (gtk_widget_add_events widget (logior GDK_STRUCTURE_MASK
					GDK_SUBSTRUCTURE_MASK))
  (connect-signal widget "configure-event" 'configure-handler)
  (connect-signal widget "delete-event" 'delete-handler)
  (connect-signal widget "destroy-event" 'destroy-handler))

(defvar *port*)

(defun enqueue (event &optional (port *port*))
;;;  (tr event)
;;;  (tr (event-sheet event))
  (push event (cdr (events-tail port)))
  (pop (events-tail port))
  event)

(defun tr (&rest x)
  (when x
    (format *trace-output* "~&~A~&" x)
    (finish-output *trace-output*))
  x)

(defun dequeue (port)
  (with-gtk ()				;let's simply use the gtk lock here
    (let ((c (cdr (events-head port))))
      (when c
	(pop (events-head port))
	(car c)))))

;; thread-safe entry function
(defun gtk-main-iteration (port &optional block)
  (with-gtk ()
    (let ((*port* port))
      (if block
	  (gtk_main_iteration_do 1)
	  (while (plusp (gtk_events_pending))
	    (gtk_main_iteration_do 0))))))

(defmethod get-next-event
    ((port gtkairo-port) &key wait-function (timeout nil))
  (declare (ignore wait-function))
  (gtk-main-iteration port)
  (cond
    ((dequeue port))
    (t
      #+(and sbcl (not win32))
      (sb-sys:wait-until-fd-usable (gdk-xlib-fd) :input timeout)
      (gtk-main-iteration port #-(and sbcl (not win32)) t)
      (dequeue port))))

(defmacro define-signal (name+options (widget event &rest args) &body body)
  (destructuring-bind (name &key (return-type :void))
      (if (listp name+options)
	  name+options
	  (list name+options))
    (let ((impl (intern (concatenate 'string (symbol-name name) "-IMPL")))
	  (args (if (symbolp event)
		    `((,event :pointer) ,@args)
		    (cons event args))))
      ;; jump through a trampoline so that C-M-x works without having to
      ;; restart:
      `(progn
	 (defun ,impl (,widget ,@(mapcar #'car args))
	   ,@body)
	 (cffi:defcallback ,name ,return-type
	   ((widget :pointer) ,@args (data :pointer))
	   data
	   (,impl widget ,@(mapcar #'car args)))))))

(define-signal noop-handler (widget event))

(define-signal expose-handler (widget event)
  (enqueue
   (cffi:with-foreign-slots ((x y width height) event gdkeventexpose)
     (make-instance 'window-repaint-event
       :timestamp (get-internal-real-time)
       :sheet (widget->sheet widget *port*)
       :region (make-rectangle* x y (+ x width) (+ y height))))))

(defun gdkmodifiertype->modifier-state (state)
  (logior
   (if (logtest GDK_SHIFT_MASK state) +shift-key+ 0)
   (if (logtest GDK_CONTROL_MASK state) +control-key+ 0)
   (if (logtest GDK_MOD1_MASK state) +meta-key+ 0)
   (if (logtest GDK_MOD2_MASK state) +super-key+ 0)
   (if (logtest GDK_MOD3_MASK state) +hyper-key+ 0)
;;;   (if (logtest GDK_MOD4_MASK state) ??? 0)
;;;   (if (logtest GDK_MOD5_MASK state) ??? 0)
;;;   (if (logtest GDK_LOCK_MASK state) ??? 0)
   ))

(defun gdkmodifiertype->one-button (state)
  (cond
    ((logtest GDK_BUTTON1_MASK state) +pointer-left-button+)
    ((logtest GDK_BUTTON2_MASK state) +pointer-middle-button+)
    ((logtest GDK_BUTTON3_MASK state) +pointer-right-button+)
    ((logtest GDK_BUTTON4_MASK state) +pointer-wheel-up+)
    ((logtest GDK_BUTTON5_MASK state) +pointer-wheel-down+)
    (t nil)))

(defun gdkmodifiertype->all-buttons (state)
  (logior
   (if (logtest GDK_BUTTON1_MASK state) +pointer-left-button+ 0)
   (if (logtest GDK_BUTTON2_MASK state) +pointer-middle-button+ 0)
   (if (logtest GDK_BUTTON3_MASK state) +pointer-right-button+ 0)
   (if (logtest GDK_BUTTON4_MASK state) +pointer-wheel-up+ 0)
   (if (logtest GDK_BUTTON5_MASK state) +pointer-wheel-down+ 0)))

(define-signal motion-notify-handler (widget event)
  (gtk_widget_grab_focus widget)
  (enqueue
   (cffi:with-foreign-slots
       ((state x y x_root y_root time) event gdkeventmotion)
     (make-instance 'pointer-motion-event
       :timestamp time
       :pointer 0
       :button (gdkmodifiertype->one-button state)
       :x (truncate x)
       :y (truncate y)
       :graft-x (truncate x_root)
       :graft-y (truncate y_root)
       :sheet (widget->sheet widget *port*)
       :modifier-state (gdkmodifiertype->modifier-state state)))))

(define-signal key-handler (widget event)
  (let ((sheet (widget->sheet widget *port*)))
    (multiple-value-bind (root-x root-y state)
	(%gdk-display-get-pointer)
      (multiple-value-bind (x y)
	  (mirror-pointer-position (sheet-direct-mirror sheet))
	(cffi:with-foreign-slots
	    ((type time state keyval string length) event gdkeventkey)
	  (let ((char (when (plusp length)
			;; fixme: what about the other characters in `string'?
			(char string 0)))
		(sym (gethash keyval *keysyms*)))
	    ;; McCLIM will #\a statt ^A sehen:
	    (when (and char
		       (< 0 (char-code char) 32)
		       ;; ...aber fuer return dann auf einmal doch
		       (not (eql char #\return)))
	      (setf char (code-char (+ (char-code char) 96))))
	    (when (eq sym :backspace)
	      (setf char #\backspace))
	    ;; irgendwas sagt mir, dass hier noch weitere Korrekturen
	    ;; werden folgen muessen.
	    (enqueue
	     (make-instance (if (eql type GDK_KEY_PRESS)
				'key-press-event
				'key-release-event)
	       :key-name sym
	       ;; fixme: was ist mit dem rest des strings?
	       ;; fixme: laut dokumentation hier nicht utf-8
	       :key-character char
	       :x x
	       :y y
	       :graft-x root-x
	       :graft-y root-y
	       :sheet sheet
	       :modifier-state (gdkmodifiertype->modifier-state state)
	       :timestamp time))))))))

(define-signal button-handler (widget event)
  (cffi:with-foreign-slots
      ((type time button state x y x_root y_root) event gdkeventbutton)
    (enqueue
     (make-instance (if (eql type GDK_BUTTON_PRESS)
			'pointer-button-press-event
			'pointer-button-release-event)
       :pointer 0
       :button (ecase button
		 (1 +pointer-left-button+)
		 (2 +pointer-middle-button+)
		 (3 +pointer-right-button+)
		 (4 +pointer-wheel-up+)
		 (5 +pointer-wheel-down+))
       :x (truncate x)
       :y (truncate y)
       :graft-x (truncate x_root)
       :graft-y (truncate y_root)
       :sheet (widget->sheet widget *port*)
       :modifier-state (gdkmodifiertype->modifier-state state)
       :timestamp time))))

(define-signal enter-handler (widget event)
  (cffi:with-foreign-slots
      ((time state x y x_root y_root) event gdkeventcrossing)
    (enqueue
     (make-instance 'pointer-enter-event
       :pointer 0
       :button (gdkmodifiertype->all-buttons state)
       :x x
       :y y
       :graft-x x_root
       :graft-y y_root
       :sheet (widget->sheet widget *port*)
       :modifier-state (gdkmodifiertype->modifier-state state)
       :timestamp time))))

(define-signal leave-handler (widget event)
  (cffi:with-foreign-slots
      ((time state x y x_root y_root gdkcrossingmode) event gdkeventcrossing)
    (enqueue
     (make-instance (if (eql gdkcrossingmode GDK_CROSSING_UNGRAB)
			'climi::pointer-ungrab-event
			'pointer-exit-event)
       :pointer 0
       :button (gdkmodifiertype->all-buttons state)
       :x x
       :y y
       :graft-x x_root
       :graft-y y_root
       :sheet (widget->sheet widget *port*)
       :modifier-state (gdkmodifiertype->modifier-state state)
       :timestamp time))))

(define-signal configure-handler (widget event)
  (cffi:with-foreign-slots ((x y width height) event gdkeventconfigure)
    (let ((sheet (widget->sheet widget *port*)))
      (when sheet			;FIXME
	(enqueue
	 (if (eq (sheet-parent sheet) (graft sheet))
	     (cffi:with-foreign-object (&x :int)
	       (cffi:with-foreign-object (&y :int)
		 ;; FIXME: Does this actually change anything about decoration
		 ;; handling?
		 (gdk_window_get_root_origin (gtkwidget-gdkwindow widget) &x &y)
		 (make-instance 'window-configuration-event
		   :sheet sheet
		   :x (cffi:mem-aref &x :int)
		   :y (cffi:mem-aref &y :int)
		   :width width
		   :height height)))
	     (make-instance 'window-configuration-event
	       :sheet sheet
	       :x x
	       :y y
	       :width width
	       :height height)))))))

(define-signal delete-handler (widget event)
  (enqueue
   (make-instance 'clim:window-manager-delete-event
     :sheet (widget->sheet widget *port*))))

(define-signal destroy-handler (widget event)
  (enqueue  
   (make-instance 'climi::window-destroy-event
     :sheet (widget->sheet widget *port*))))

;; native widget handlers:

(define-signal magic-clicked-handler (widget event)
  (declare (ignore event))
  (when (boundp '*port*)		;hack alert
    (enqueue
     (make-instance 'magic-gadget-event
       :sheet (widget->sheet widget *port*)))))

#-sbcl
(define-signal (scrollbar-change-value-handler :return-type :int)
    (widget (scroll gtkscrolltype) (value :double))
  (enqueue (make-instance 'scrollbar-change-value-event
	     :scroll-type scroll
	     :value value
	     :sheet (widget->sheet widget *port*)))
  1)

#+sbcl
;; :double in callbacks doesn't work:
(define-signal (scrollbar-change-value-handler :return-type :int)
    (widget (scroll gtkscrolltype) (lo :unsigned-int) (hi :int))
  (enqueue (make-instance 'scrollbar-change-value-event
	     :scroll-type scroll
	     :value (sb-kernel:make-double-float hi lo)
	     :sheet (widget->sheet widget *port*)))
  1)