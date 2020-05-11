(require 'thunk)

(defun jupyter-return (value)
  (declare (indent 0))
  (lambda (_io) value))

;; Adapted from `thunk-delay'
(defmacro jupyter-return-thunk (&rest body)
  (declare (indent 0))
  `(let (forced val)
     (lambda (_io)
       (unless forced
         (setf val (progn ,@body))
         (setf forced t))
       val)))

(defconst jupyter-io-nil (jupyter-return nil))

(defvar jupyter-current-io
  (lambda (&rest args)
	(error "Unhandled IO: %s" args)))

;; TODO: Keep track of the function bound to a io-value such that the
;; function is accessible
(defun jupyter-bind (io-value fn)
  "Bind MVALUE to MFN."
  (declare (indent 1))
  (pcase (funcall io-value jupyter-current-io)
	((and req (cl-struct jupyter-request client)
		  (let jupyter-current-client client))
	 (funcall fn req))
	(`(timeout ,(and req (cl-struct jupyter-request)))
	 (error "Timed out: %s" (cl-prin1-to-string req)))
	(`,value (funcall fn value))))

(defmacro jupyter-mlet* (varlist &rest body)
  (declare (indent 1))
  (letrec ((result (make-symbol "result"))
           (binder
            (lambda (vars)
              (if (zerop (length vars))
                  `(jupyter-return-thunk ,@body)
                `(jupyter-bind ,(cadar vars)
                   (lambda (val)
                     (setq ,(caar vars) val)
                     ,(funcall binder (cdr vars))))))))
    `(let ,(cons result (mapcar #'car varlist))
       ;; nil is bound here to kick off the chain of binds.
       ;; TODO Is it safe to assume nil?
       (jupyter-bind jupyter-io-nil
         ,(funcall binder varlist))
       ,result)))

(defun jupyter--do (&rest mfns)
  (cl-reduce
   (lambda (io-value mfn)
	 (jupyter-bind io-value mfn))
   mfns :initial-value jupyter-io-nil))

(defmacro jupyter-do (io &rest forms)
  (declare (indent 1))
  `(let ((jupyter-current-io ,io))
	 (jupyter--do ,@forms)))

(defun jupyter-after (io-value io-fn)
  "Return an I/O action that binds IO-VALUE to IO-FN.
That is, IO-FN is evaluated after binding IO-VALUE within the I/O
context."
  (declare (indent 1))
  (lambda (_)
	(jupyter-bind io-value io-fn)))

;;; Kernel
;;
;; I/O actions that manage a kernel's lifetime.

;; TODO: Change to `jupyter-kernel', move the old one's definition to
;; `jupyter-make-kernel'.
(defun jupyter--kernel (&rest args)
  (lambda (_io)
    (apply #'jupyter-kernel args)))

;; TODO: Swap definitions with `jupyter-launch', same for the others.
;; (jupyter-launch :kernel "python")
;; (jupyter-launch :spec "python")
(defun jupyter-kernel-launch (&rest args)
  (lambda (_)
    (let ((kernel (apply #'jupyter-kernel args)))
      (jupyter-launch kernel)
      kernel)))

(defun jupyter-kernel-interrupt (io-kernel)
  (jupyter-after io-kernel
    (lambda (kernel)
      (jupyter-interrupt kernel)
      (jupyter-return kernel))))

(defun jupyter-kernel-shutdown (kernel)
  (jupyter-after (jupyter-return kernel)
    (lambda (kernel)
      (jupyter-shutdown kernel)
      (jupyter-return kernel))))

(defmacro jupyter-io-sink (spec &rest cases)
  (declare (indent 1))
  `(lambda (&rest args)
     (setq ,(car spec) (cdr args))
     (pcase (car args)
       ,@cases
       (_
        (error "Unhandled I/O: %s" args)))))

;; A monadic function that, given session endpoints, returns a monadic
;; value that, when evaluated, returns an I/O stream sink that can
;; subscribe to some other source of messages.  
;;
;; (funcall channel-io 'message 'start)
;;
;; The current I/O context when the value is evaluated should be one
;; in which the socket endpoints of SESSION can be controlled by
;; 'start-channel, 'stop-channel, and 'alive-p messages.
(defun jupyter-channel-io (session)
  (let* ((channels '(:shell :iopub :stdin))
         (ch-group
          (cl-loop
           with endpoints = (jupyter-session-endpoints session)
           for ch in channels
           collect ch
           collect (list 'endpoint (plist-get endpoints ch)
                         'alive-p nil))))
    (lambda (io)
      (cl-macrolet ((continue-after
                     (cond on-timeout)
                     `(jupyter-with-timeout
                          (nil jupyter-default-timeout ,on-timeout)
                        ,cond)))
        (cl-labels ((ch-put
                     (ch prop value)
                     (plist-put (plist-get ch-group ch) prop value))
                    (ch-get
                     (ch prop)
                     (plist-get (plist-get ch-group ch) prop))
                    (ch-alive-p
                     (ch)
                     (and (funcall io 'alive-p)
                          (ch-get ch 'alive-p)))
                    (ch-start
                     (ch)
                     (unless (ch-alive-p ch)
                       (funcall io 'message 'start-channel ch
                                (ch-get ch 'endpoint))
                       (continue-after
                        (ch-alive-p ch)
                        (error "Channel not started: %s" ch))))
                    (ch-stop
                     (ch)
                     (when (ch-alive-p ch)
                       (funcall io 'message 'stop-channel ch)
                       (continue-after
                        (not (ch-alive-p ch))
                        (error "Channel not stopped: %s" ch)))))
          (let ((sink
                 (jupyter-io-sink (action)
                   ('message
                    (pcase action
                      ('start
                       (cl-loop
                        for ch in channels
                        do (ch-start ch)))
                      ('stop
                       (cl-loop
                        for ch in channels
                        do (ch-stop ch))
                       (and hb (jupyter-hb-pause hb))
                       (setq hb nil))
                      ('alive-p
                       (and (or (null hb) (jupyter-alive-p hb))
                            (cl-loop
                             for ch in channels
                             do (ch-alive-p ch))))
                      ('hb
                       (unless hb
                         (setq hb
                               (make-instance
                                'jupyter-hb-channel
                                :session session
                                :endpoint (plist-get endpoints :hb))))
                       hb))))))
            (funcall io 'handler
                     (lambda ()

                       ))
            sink))))))

(defun jupyter-idle (io-req)
  (jupyter-after io-req
	(lambda (req)
	  (jupyter-return
	   (if (jupyter-wait-until-idle req) req
		 (list 'timeout req))))))

;; MsgType -> MsgList -> (IO -> Req)
;; (IO -> Req) represents an IO monadic value. IO Req
(defun jupyter-request (type &rest content)
  "Return an IO action that sends a `jupyter-request'.
TYPE is the message type of the message that CONTENT, a property
list, represents.

See `jupyter-io' for more information on IO actions."
  (declare (indent 1))
  (setq type (intern (format ":%s-request"
                             (replace-regexp-in-string "_" "-" type))))
  (lambda (io)
    (let* ((req (make-jupyter-request
                 :client jupyter-current-client
                 :type type
                 :content content))
           (ch (if (memq type '(:input-reply :input-request))
                   :stdin
                 :shell))
           (id (jupyter-request-id req)))
      (letrec ((handler
                (lambda (event)
                  (pcase (car event)
                    ((and 'message (let `(,channel . ,msg) (cdr event))
                          (guard (string= id (jupyter-message-parent-id msg))))
                     (cl-callf nconc (jupyter-request-messages req)
                       (list msg))
                     (when (jupyter--message-completes-request-p msg)
                       (setf (jupyter-request-idle-p req) t)
                       (jupyter-send io 'remove-handler handler)))))))
        (jupyter-send io 'message ch type content id)
        (jupyter-send io 'add-handler handler)
        req))))
