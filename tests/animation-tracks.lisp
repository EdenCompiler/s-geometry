(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(defclass animation-test-value ()
  ((value :initform 0d0 :accessor animation-test-value)))

(defclass animation-test-child ()
  ((value :initform 0d0 :accessor %animation-test-child-value)))
(defclass animation-test-parent ()
  ((child :initform (make-instance 'animation-test-child)
          :accessor %animation-test-parent-child)))
(defun animation-test-child (object) (%animation-test-parent-child object))
(defun animation-test-nested-value (object) (%animation-test-child-value object))
(defun (setf animation-test-nested-value) (value object)
  (setf (%animation-test-child-value object) value))

(defclass animation-test-morphs ()
  ((weights :initarg :weights :accessor %animation-test-morph-weights)))
(defun animation-test-morph-weights (object) (%animation-test-morph-weights object))
(defun (setf animation-test-morph-weights) (value object)
  (setf (%animation-test-morph-weights object) value))

(defun animation-test-read (object)
  (animation-test-value object))
(defun (setf animation-test-read) (value object)
  (setf (animation-test-value object) value)
  (when (> value 5d0) (error "setter rejected value"))
  value)

(defparameter *animation-dsl-object* (sgeo.scene:make-scene-object))
(sgeo.animation:defanimation animation-dsl-clip
  (:duration 1.25d0)
  (track *animation-dsl-object* '(rotation y)
    (0d0 0d0 :ease :in-out)
    (1.25d0 1d0 :ease :in-out)))

(test animation-track-linear-step-and-key-validation
  (let ((linear (sgeo.animation:make-property-track
                 (make-instance 'animation-test-value) '(value)
                 '((0 0) (2 4)))))
    (is (approximately= 2d0 (sgeo.animation:sample-track linear 1d0)))
    (sgeo.animation:set-track-keys linear '((0 9) (2 1)))
    (is (approximately= 5d0 (sgeo.animation:sample-track linear 1d0)))
    (signals error (sgeo.animation:set-track-keys linear '((0 0) (0 1))))
    (is (equal '(0d0 2d0) (mapcar #'first (sgeo.animation:track-keys linear)))))
  (let ((step (sgeo.animation:make-property-track
               (make-instance 'animation-test-value) '(value)
               '((0 0) (0.5 3) (1 7)) :interpolation :step)))
    (is (= 0d0 (sgeo.animation:sample-track step 0.499d0)))
    (is (= 3d0 (sgeo.animation:sample-track step 0.5d0)))
    (is (= 7d0 (sgeo.animation:sample-track step 1d0)))))

(test animation-property-tracks-reject-nonfinite-numeric-data
  (let ((target (make-instance 'animation-test-value)))
    (signals error
      (sgeo.animation:make-property-track target '(value) '((0 1) (1 #c(2 3)))
                                          :interpolation :step))
    (signals error
      (sgeo.animation:make-property-track target '(value) '((0 #(1 2)) (1 #(2 #c(3 1))))))))

(test animation-key-validation-rejects-nan-infinity-and-shape-mismatch
  #+sbcl
  (let* ((target (make-instance 'animation-test-value))
         (nan (sb-kernel:make-double-float #x7ff80000 0))
         (infinity (sb-kernel:make-double-float #x7ff00000 0)))
    (signals error
      (sgeo.animation:make-property-track target '(value) (list (list 0 nan))
                                          :interpolation :step))
    (signals error
      (sgeo.animation:make-property-track target '(value) (list (list 0 infinity))
                                          :interpolation :step))
    (signals error
      (sgeo.animation:make-property-track target '(value) '((0 #(1 2)) (1 #(2 3 4)))))
    (signals error
      (sgeo.animation:make-property-track target '(value) '((0 0 1 #(0 0)) (1 1 0 0))
                                          :interpolation :cubic-spline))
    (signals error
      (sgeo.animation:make-property-track target '(value) (list (list 0 0 nan 0))
                                          :interpolation :cubic-spline))))

(test animation-cached-nested-accessors-retain-live-setter-redefinition
  (let* ((target (make-instance 'animation-test-parent))
         (track (sgeo.animation:make-property-track
                 target '(animation-test-child animation-test-nested-value)
                 '((0 1) (1 2))))
         (setter-name '(setf animation-test-nested-value))
         (original (fdefinition setter-name))
         (compiler-name 'sgeo.animation::%compile-read-step)
         (original-compiler (fdefinition compiler-name))
         (calls 0))
    (unwind-protect
         (progn
           (setf (fdefinition compiler-name)
                 (lambda (&rest arguments)
                   (declare (ignore arguments))
                   (error "O compilador de caminho não deve rodar por quadro.")))
           (is (zerop (sgeo.animation:read-track-value track)))
           (setf (fdefinition setter-name)
                 (lambda (value object)
                   (incf calls)
                   (setf (%animation-test-child-value object) (* value 2))))
           (sgeo.animation:write-track-value track 3d0)
           (is (= 6d0 (%animation-test-child-value
                       (%animation-test-parent-child target))))
           (is (= 1 calls))
           (is (= 6d0 (sgeo.animation:read-track-value track))))
      (setf (fdefinition setter-name) original
            (fdefinition compiler-name) original-compiler))))

(test animation-morph-weight-vectors-interpolate-with-variable-width
  (let* ((target (make-instance 'animation-test-morphs
                                :weights #(0 1 2 3 4 5 6 7)))
         (track (sgeo.animation:make-property-track
                 target '(animation-test-morph-weights)
                 '((0 #(0 1 2 3 4 5 6 7)) (1 #(8 9 10 11 12 13 14 15))))))
    (is (equalp #(4d0 5d0 6d0 7d0 8d0 9d0 10d0 11d0)
                (sgeo.animation:sample-track track 0.5d0)))
    (sgeo.animation:write-track-value track (sgeo.animation:sample-track track 0.5d0))
    (is (equalp #(4d0 5d0 6d0 7d0 8d0 9d0 10d0 11d0)
                (%animation-test-morph-weights target)))))

(test animation-glTF-cubic-tangents-and-quaternion-antipodes
  (let ((cubic (sgeo.animation:make-property-track
                (make-instance 'animation-test-value) '(value)
                '((0 0 0 1) (1 1 0 0)) :interpolation :cubic-spline))
        (q-track (sgeo.animation:make-property-track
                  (make-instance 'animation-test-value) '(value)
                  (list (list 0d0 (sgeo.math:make-quaternion))
                        (list 1d0 (sgeo.math:make-quaternion 0d0 0d0 0d0 -1d0)))))
        (wide (sgeo.animation:make-property-track
               (make-instance 'animation-test-value) '(value)
               '((0 #(0 1 2 3 4)) (1 #(5 6 7 8 9)))))
        (cubic-quaternion
          (sgeo.animation:make-property-track
           (make-instance 'animation-test-value) '(value)
           (list (list 0d0 (sgeo.math:make-quaternion) #(0d0 0d0 0d0 0d0) #(0d0 0d0 0d0 0.5d0))
                 (list 1d0 (sgeo.math:make-quaternion 0d0 0d0 0.2d0 0.98d0)
                       #(0d0 0d0 0d0 0d0) #(0d0 0d0 0d0 0d0)))
           :interpolation :cubic-spline)))
    (is (approximately= 0.625d0 (sgeo.animation:sample-track cubic 0.5d0)))
    (let ((sample (sgeo.animation:sample-track q-track 0.5d0)))
      (is (approximately= 1d0 (aref (sgeo.math::quaternion-data sample) 3))))
    (is (equalp #(2.5d0 3.5d0 4.5d0 5.5d0 6.5d0)
                (sgeo.animation:sample-track wide 0.5d0)))
    (is (typep (sgeo.animation:sample-track cubic-quaternion 0.5d0)
               'sgeo.math:quaternion))
    (is (equalp #(0d0 0d0 0d0 0.5d0)
                (fourth (first (sgeo.animation:track-keys cubic-quaternion)))))))

(test animation-scene-property-components-are-cached-and-angular
  (let* ((object (sgeo.scene:make-scene-object))
         (position (sgeo.animation:make-property-track object '(position x)
                                                       '((0 0) (1 4))))
         (rotation (sgeo.animation:make-property-track object '(rotation y)
                                                       '((0 0) (1 1.2d0)))))
    (is (typep position 'sgeo.animation:transform-track))
    (is (approximately= 2d0 (sgeo.animation:sample-track position 0.5d0)))
    (sgeo.animation:write-track-value position 3d0)
    (is (approximately= 3d0 (aref (sgeo.math:transform-position
                                   (sgeo.scene:scene-object-local-transform object)) 0)))
    (is (approximately= 0d0 (sgeo.animation:read-track-value rotation)))
    (sgeo.animation:write-track-value rotation 0.75d0)
    (is (approximately= 0.75d0 (sgeo.animation:read-track-value rotation)))))

(test animation-defanimation-dsl-compiles-easing-and-inspectable-clip
  (let* ((clip animation-dsl-clip)
         (track (first (sgeo.animation:clip-tracks clip))))
    (is (equal "animation-dsl-clip" (slot-value clip 'sgeo.animation::name)))
    (is (approximately= 0.15625d0 (sgeo.animation:sample-track track 0.3125d0)))
    (is (equal '(:in-out :in-out) (sgeo.animation:track-easings track)))))

(test animation-weighted-additive-and-mask-layers
  (let* ((world (sgeo.scene:make-world))
         (object (sgeo.scene:make-scene-object))
         (position (sgeo.animation:make-property-track object '(position)
                                                       '((0 #(10 0 0)))))
         (clip (sgeo.animation:make-animation-clip :tracks (list position)))
         (first (sgeo.animation:play-animation world clip :weight 0.5d0))
         (second (sgeo.animation:play-animation world clip :weight 0.5d0)))
    (declare (ignore first second))
    (is (vector-approximately= #(10 0 0)
                               (sgeo.math:transform-position
                                (sgeo.scene:scene-object-local-transform object))))
    (let* ((add-track (sgeo.animation:make-property-track object '(position)
                                                         '((0 #(10 0 0)) (1 #(14 0 0)))))
           (add-clip (sgeo.animation:make-animation-clip :tracks (list add-track)))
           (add-player (sgeo.animation:play-animation world add-clip
                                                      :weight 0.5d0 :additive-p t)))
      (sgeo.animation:seek-animation add-player 1d0)
      (is (approximately= 12d0 (aref (sgeo.math:transform-position
                                      (sgeo.scene:scene-object-local-transform object)) 0))))
    (let* ((scale-track (sgeo.animation:make-property-track object '(scale x) '((0 9))))
           (scale-clip (sgeo.animation:make-animation-clip :tracks (list scale-track)))
           (masked (sgeo.animation:play-animation world scale-clip :mask '(:position))))
      (declare (ignore masked))
      (is (approximately= 1d0 (aref (sgeo.math:transform-scale
                                     (sgeo.scene:scene-object-local-transform object)) 0))))))

(test animation-base-layer-references-additive-quaternion-and-paused-layer
  (let* ((world (sgeo.scene:make-world))
         (target (make-instance 'animation-test-value))
         (base-a (sgeo.animation:make-animation-clip
                  :tracks (list (sgeo.animation:make-property-track target '(value) '((0 20))))))
         (base-b (sgeo.animation:make-animation-clip
                  :tracks (list (sgeo.animation:make-property-track target '(value) '((0 40)))))))
    (setf (animation-test-value target) 10d0)
    (sgeo.animation:play-animation world base-a :weight 0.25d0)
    (sgeo.animation:play-animation world base-b :weight 0.25d0)
    (is (approximately= 20d0 (animation-test-value target)))
    (let* ((paused-world (sgeo.scene:make-world))
           (paused-target (make-instance 'animation-test-value))
           (constant (sgeo.animation:make-animation-clip
                      :tracks (list (sgeo.animation:make-property-track
                                     paused-target '(value) '((0 10))))))
           (moving (sgeo.animation:make-animation-clip
                    :duration 1d0
                    :tracks (list (sgeo.animation:make-property-track
                                   paused-target '(value) '((0 0) (1 20))))))
           (paused (sgeo.animation:play-animation paused-world constant))
           (seeking (sgeo.animation:play-animation paused-world moving)))
      (setf (sgeo.animation:player-playing-p paused) nil)
      (sgeo.animation:seek-animation seeking 1d0)
      (is (approximately= 15d0 (animation-test-value paused-target))))
    (let* ((quat-world (sgeo.scene:make-world))
           (quat-target (make-instance 'animation-test-value))
           (identity (sgeo.math:make-quaternion))
           (quarter-turn (sgeo.math:make-quaternion 0d0 0d0
                                                    (sin (/ pi 4d0)) (cos (/ pi 4d0))))
           (base (sgeo.animation:make-animation-clip
                  :tracks (list (sgeo.animation:make-property-track
                                 quat-target '(value) (list (list 0d0 identity))))))
           (additive (sgeo.animation:make-animation-clip
                      :duration 1d0
                      :tracks (list (sgeo.animation:make-property-track
                                     quat-target '(value)
                                     (list (list 0d0 identity) (list 1d0 quarter-turn))))))
           (player (progn (setf (animation-test-value quat-target) identity)
                          (sgeo.animation:play-animation quat-world base)
                          (sgeo.animation:play-animation quat-world additive
                                                          :additive-p t :weight 0.5d0))))
      (sgeo.animation:seek-animation player 1d0)
      (let ((result (sgeo.math::quaternion-data (animation-test-value quat-target))))
        (is (approximately= (sin (/ pi 8d0)) (aref result 2)))
        (is (approximately= (cos (/ pi 8d0)) (aref result 3)))))))

(test animation-stop-restores-reference-and-keeps-other-layer
  (let* ((world (sgeo.scene:make-world))
         (target (make-instance 'animation-test-value))
         (first-clip (sgeo.animation:make-animation-clip
                      :tracks (list (sgeo.animation:make-property-track target '(value) '((0 20))))))
         (second-clip (sgeo.animation:make-animation-clip
                       :tracks (list (sgeo.animation:make-property-track target '(value) '((0 40))))))
         (first-player nil) (second-player nil))
    (setf (animation-test-value target) 10d0
          first-player (sgeo.animation:play-animation world first-clip :weight 0.25d0)
          second-player (sgeo.animation:play-animation world second-clip :weight 0.25d0))
    (is (approximately= 20d0 (animation-test-value target)))
    (sgeo.animation:stop-animation second-player)
    (is (approximately= 12.5d0 (animation-test-value target)))
    (sgeo.animation:stop-animation first-player)
    (is (approximately= 10d0 (animation-test-value target)))
    (is (zerop (hash-table-count
                (sgeo.animation::%state-references
                 (sgeo.animation:ensure-animation-state world)))))))

(test animation-orphaned-reference-does-not-overwrite-later-manual-edit
  (let* ((world (sgeo.scene:make-world))
         (target (make-instance 'animation-test-value))
         (track (sgeo.animation:make-property-track target '(value) '((0 20))))
         (clip (sgeo.animation:make-animation-clip :tracks (list track))))
    (sgeo.animation:play-animation world clip)
    (setf (sgeo.animation:clip-tracks clip) nil)
    (sgeo.animation:evaluate-animation-state (sgeo.animation:ensure-animation-state world))
    (is (zerop (animation-test-value target)))
    (setf (animation-test-value target) 7d0)
    (sgeo.animation:evaluate-animation-state (sgeo.animation:ensure-animation-state world))
    (is (approximately= 7d0 (animation-test-value target)))))

(test animation-player-direct-setters-validate-finite-domain
  (let* ((clip (sgeo.animation:make-animation-clip :duration 1d0))
         (world (sgeo.scene:make-world))
         (player (sgeo.animation:play-animation world clip)))
    (signals error (setf (sgeo.animation:clip-duration clip) -1d0))
    (signals error (setf (sgeo.animation:player-time player) -1d0))
    (signals error (setf (sgeo.animation:player-weight player) -1d0))
    (signals error (setf (sgeo.animation:player-speed player) #c(1 1)))
    #+sbcl
    (signals error
      (setf (sgeo.animation:player-speed player)
            sb-ext:double-float-positive-infinity))))

(test animation-events-loop-reverse-and-silent-seek
  (let* ((world (sgeo.scene:make-world))
         (seen nil)
         (events (sgeo.animation:make-event-track
                  '((0 :zero) (0.25 :quarter) (0.75 :three-quarter) (1 :end))
                  :handler (lambda (value player track time)
                             (declare (ignore player track time)) (push value seen))))
         (clip (sgeo.animation:make-animation-clip :duration 1d0 :tracks (list events)))
         (player (sgeo.animation:play-animation world clip)))
    (sgeo.animation:seek-animation player 0d0)
    (is (null seen))
    (sgeo.animation:seek-animation player 1d0)
    (is (= 1d0 (sgeo.animation:player-time player)))
    (sgeo.animation:seek-animation player 0d0)
    (sgeo.animation:advance-animation-state (sgeo.animation:ensure-animation-state world) 1.5d0)
    (is (equal '(:quarter :three-quarter :end :zero :quarter)
               (nreverse seen)))
    (setf seen nil)
    (setf (sgeo.animation:player-speed player) -1d0)
    (sgeo.animation:advance-animation-state (sgeo.animation:ensure-animation-state world) 1.5d0)
    (is (equal '(:quarter :zero :end :three-quarter :quarter :zero) (nreverse seen)))))

(test animation-looped-root-motion-and-clip-live-redefinition
  (let* ((world (sgeo.scene:make-world))
         (joint (sgeo.scene:make-scene-object))
         (target (sgeo.scene:make-scene-object))
         (root-track (sgeo.animation:make-property-track joint '(position)
                                                         '((0 #(0 0 0)) (1 #(1 0 0)))))
         (clip (sgeo.animation:make-animation-clip :duration 1d0 :tracks (list root-track)))
         (player (sgeo.animation:play-animation world clip :root-motion-joint joint
                                                :root-motion-target target)))
    (sgeo.animation:advance-animation-state (sgeo.animation:ensure-animation-state world) 1.25d0)
    (is (approximately= 1.25d0 (aref (sgeo.math:transform-position
                                      (sgeo.scene:scene-object-local-transform target)) 0)))
    (sgeo.animation:set-track-keys root-track '((0 #(0 0 0)) (1 #(2 0 0))))
    (is (equalp #(0d0 0d0 0d0) (sgeo.animation:sample-track root-track 0d0)))
    (is (typep player 'sgeo.animation:animation-player))))

(test animation-evaluation-rolls-back-a-failing-setter
  (let* ((world (sgeo.scene:make-world))
         (target (make-instance 'animation-test-value))
         (good-target (make-instance 'animation-test-value))
         (joint (sgeo.scene:make-scene-object))
         (root-target (sgeo.scene:make-scene-object))
         (events-seen nil)
         (event-track (sgeo.animation:make-event-track
                       '((0.5d0 :commit))
                       :handler (lambda (&rest arguments)
                                  (declare (ignore arguments)) (push :commit events-seen))))
         (track (sgeo.animation:make-property-track
                 target (list (list 'funcall #'animation-test-read
                                    #'(setf animation-test-read)))
                 '((0 0) (1 10))))
         (root-track (sgeo.animation:make-property-track
                      joint '(position) '((0 #(0 0 0)) (1 #(1 0 0)))))
         (good-track (sgeo.animation:make-property-track
                      good-target '(value) '((0 7) (1 8))))
         (clip (sgeo.animation:make-animation-clip :duration 1d0
                                                   :tracks (list track root-track good-track
                                                                 event-track)))
         (player (sgeo.animation:play-animation world clip :looping-p nil
                                                :root-motion-joint joint
                                                :root-motion-target root-target)))
    (setf (animation-test-value target) 4d0)
    (setf (animation-test-value good-target) 9d0)
    (sgeo.scene:set-position root-target #(3d0 0d0 0d0))
    (signals error (sgeo.animation:advance-animation-state
                    (sgeo.animation:ensure-animation-state world) 1d0))
    (is (approximately= 4d0 (animation-test-value target)))
    (is (approximately= 9d0 (animation-test-value good-target)))
    (is (approximately= 3d0 (aref (sgeo.math:transform-position
                                   (sgeo.scene:scene-object-local-transform root-target)) 0)))
    (is (zerop (sgeo.animation:player-time player)))
    (is (sgeo.animation:player-playing-p player))
    (is (null events-seen))
    (is (zerop (sgeo.animation:animation-state-time
                (sgeo.animation:ensure-animation-state world))))
    (let* ((state (sgeo.animation:ensure-animation-state world))
           (references (sgeo.animation::%state-references state)))
      (is (zerop (gethash (list target (sgeo.animation:track-path track)) references)))
      (is (zerop (gethash (list good-target (sgeo.animation:track-path good-track)) references))))))
