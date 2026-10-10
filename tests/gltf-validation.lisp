(in-package #:sgeo.tests)
(in-suite sgeo-suite)

(defun %gltf-validation-document ()
  (let ((document
          (with-open-file (stream (%gltf-fixture "animated.gltf"))
            (yason:parse stream :json-arrays-as-vectors t
                                :json-booleans-as-symbols t
                                :json-nulls-as-keyword t))))
    ;; Incorpora o fixture para que cada mutação seja autocontida e não dependa
    ;; do local escolhido pelo executor para os arquivos temporários.
    (setf (gethash "uri" (aref (gethash "buffers" document) 0))
          (format nil "data:application/octet-stream;base64,~a"
                  (sgeo.gltf::%base64-encode
                   (sgeo.gltf::%read-bytes (%gltf-fixture "animated.bin")))))
    document))

(defun %gltf-validation-json-value (value)
  ;; O YASON antigo lê null como :NULL, mas só escreve null com yason:null.
  (cond ((eq value :null) 'yason:null)
        ((hash-table-p value)
         (maphash (lambda (key item)
                    (setf (gethash key value) (%gltf-validation-json-value item)))
                  value)
         value)
        ((and (vectorp value) (not (stringp value)))
         (map 'vector #'%gltf-validation-json-value value))
        (t value)))

(defun %gltf-validation-unique-path ()
  (merge-pathnames
   (format nil "sgeo-gltf-validation-~36r-~36r.gltf"
           (get-universal-time) (random most-positive-fixnum))
   (uiop:temporary-directory)))

(defun %gltf-validation-world-objects (world)
  (let ((objects nil))
    (labels ((visit (object)
               (push object objects)
               (dolist (child (sgeo.scene:scene-object-children object))
                 (visit child))))
      (visit (sgeo.scene:world-root world)))
    (nreverse objects)))

(defun %gltf-validation-assert-same-objects (before after)
  (is (= (length before) (length after)))
  (loop for left in before for right in after do (is (eq left right))))

(defun %gltf-validation-reject-atomically (case-name mutate)
  (let* ((world (sgeo.scene:make-world))
         (good (sgeo.gltf:import-gltf (%gltf-fixture "animated.gltf") :world world))
         (player (sgeo.animation:play-animation world (aref (sgeo.gltf:gltf-clips good) 0)))
         (path (%gltf-validation-unique-path))
         (document (%gltf-validation-document)))
    (sgeo.animation:seek-animation player 0.4d0)
    (funcall mutate document)
    (let* ((before-objects (%gltf-validation-world-objects world))
           (before-children (copy-list (sgeo.scene:scene-object-children
                                        (sgeo.scene:world-root world))))
           (before-state (sgeo.scene:world-animation-state world))
           (before-state-clips (copy-list (sgeo.animation:animation-state-clips
                                           (sgeo.scene:world-animation-state world))))
           (before-player-time (sgeo.animation:player-time player))
           (before-sources (copy-tree (gethash :gltf-sources
                                               (sgeo.core:object-metadata
                                                (sgeo.scene:world-root world))))))
      (unwind-protect
           (progn
             (with-open-file (stream path :direction :output :if-exists :supersede)
               (yason:encode (%gltf-validation-json-value document) stream))
             (signals error (sgeo.gltf:import-gltf path :world world))
             (%gltf-validation-assert-same-objects before-objects
                                                   (%gltf-validation-world-objects world))
             (is (equal before-children
                        (sgeo.scene:scene-object-children (sgeo.scene:world-root world))))
             (is (eq before-state (sgeo.scene:world-animation-state world)))
             (is (equal before-state-clips
                        (sgeo.animation:animation-state-clips before-state)))
             (is (= before-player-time (sgeo.animation:player-time player)))
             (is (equalp before-sources
                         (gethash :gltf-sources
                                  (sgeo.core:object-metadata (sgeo.scene:world-root world)))))
             (is (= 2 (length (sgeo.animation:animation-state-clips before-state))))
             (format t "Rejected malformed glTF atomically: ~a~%" case-name))
        (when (probe-file path) (delete-file path))))))

(test gltf-buffer-view-and-accessor-boundaries-reject-without-world-mutation
  (dolist (case
           (list
            (cons "bufferView outside declared buffer"
                  (lambda (doc)
                    (setf (gethash "byteLength" (aref (gethash "bufferViews" doc) 0)) 900)))
            (cons "accessor count overruns its view"
                  (lambda (doc)
                    (setf (gethash "count" (aref (gethash "accessors" doc) 0)) 80)))
            (cons "accessor stride violates element alignment"
                  (lambda (doc)
                    (setf (gethash "byteStride" (aref (gethash "bufferViews" doc) 0)) 14)))
            (cons "accessor byte offset exceeds its view"
                  (lambda (doc)
                    (setf (gethash "byteOffset" (aref (gethash "accessors" doc) 0)) 48)))
            (cons "sparse index offset exceeds sparse view"
                  (lambda (doc)
                    (setf (gethash "byteOffset"
                                   (gethash "indices"
                                            (gethash "sparse" (aref (gethash "accessors" doc) 17)))) 1)))
            (cons "sparse replacement values exceed sparse view"
                  (lambda (doc)
                    (setf (gethash "count" (gethash "sparse"
                                                    (aref (gethash "accessors" doc) 17))) 4)))
            (cons "sparse index is outside accessor element range"
                  (lambda (doc)
                    ;; O índice sparse de um byte do fixture é o vértice 2;
                    ;; trocá-lo por 3 excede a contagem válida de três vértices.
                    (let ((bytes (sgeo.gltf::%read-bytes (%gltf-fixture "animated.bin"))))
                      (setf (aref bytes 640) 3
                            (gethash "uri" (aref (gethash "buffers" doc) 0))
                            (format nil "data:application/octet-stream;base64,~a"
                                    (sgeo.gltf::%base64-encode bytes))))))))
    (%gltf-validation-reject-atomically (car case) (cdr case))))

(test gltf-hierarchy-scene-and-skin-reference-errors-are-atomic
  (dolist (case
           (list
            (cons "node cycle"
                  (lambda (doc)
                    (setf (gethash "children" (aref (gethash "nodes" doc) 1)) #(0))))
            (cons "node with multiple parents"
                  (lambda (doc)
                    (setf (gethash "children" (aref (gethash "nodes" doc) 2)) #(1))))
            (cons "repeated scene root"
                  (lambda (doc)
                    (setf (gethash "nodes" (aref (gethash "scenes" doc) 0)) #(0 0))))
            (cons "scene root has a parent"
                  (lambda (doc)
                    (setf (gethash "nodes" (aref (gethash "scenes" doc) 0)) #(1))))
            (cons "skin joint index is invalid"
                  (lambda (doc)
                    (setf (gethash "joints" (aref (gethash "skins" doc) 0)) #(77))))
            (cons "skin skeleton is not an ancestor of its joints"
                  (lambda (doc)
                    (setf (gethash "skeleton" (aref (gethash "skins" doc) 0)) 2)))
            (cons "inverse bind matrix count differs from joints"
                  (lambda (doc)
                    ;; Os dados seguintes no fixture permitem ampliar a view
                    ;; MAT4 sem sair do buffer; assim, a rejeição verifica a
                    ;; quantidade de joints, e não apenas um acesso fora da faixa.
                    (setf (gethash "count" (aref (gethash "accessors" doc) 6)) 2
                          (gethash "byteLength" (aref (gethash "bufferViews" doc) 6)) 128)))))
    (%gltf-validation-reject-atomically (car case) (cdr case))))

(test gltf-animation-shape-and-reference-errors-are-atomic
  (dolist (case
           (list
            (cons "channel target references missing node"
                  (lambda (doc)
                    (setf (gethash "node" (gethash "target"
                            (aref (gethash "channels" (aref (gethash "animations" doc) 0)) 0))) 90)))
            (cons "channel references missing sampler"
                  (lambda (doc)
                    (setf (gethash "sampler"
                                   (aref (gethash "channels" (aref (gethash "animations" doc) 0)) 0)) 9)))
            (cons "translation output has incompatible width"
                  (lambda (doc)
                    (setf (gethash "type" (aref (gethash "accessors" doc) 8)) "VEC4")))
            (cons "cubic output has the wrong key count"
                  (lambda (doc)
                    (setf (gethash "count" (aref (gethash "accessors" doc) 10)) 5)))
            (cons "animation timestamps are not strictly increasing"
                  (lambda (doc)
                    ;; Reutiliza o accessor de entrada com duas chaves.
                    (let ((bytes (sgeo.gltf::%read-bytes (%gltf-fixture "animated.bin"))))
                      ;; A view 7 começa no byte 204; o segundo FLOAT está no 208.
                      ;; Zerá-lo repete o timestamp da primeira chave.
                      (fill bytes 0 :start 208 :end 212)
                      (setf (gethash "uri" (aref (gethash "buffers" doc) 0))
                            (format nil "data:application/octet-stream;base64,~a"
                                    (sgeo.gltf::%base64-encode bytes))))))
            (cons "unsupported channel path"
                  (lambda (doc)
                    (setf (gethash "path" (gethash "target"
                            (aref (gethash "channels" (aref (gethash "animations" doc) 0)) 0))) "visibility")))
            (cons "duplicate channel targets the same property"
                  (lambda (doc)
                    (let* ((channels (gethash "channels" (aref (gethash "animations" doc) 0)))
                           (duplicate (make-hash-table :test #'equal)))
                      (maphash (lambda (key value) (setf (gethash key duplicate) value)) (aref channels 0))
                      (setf (gethash "channels" (aref (gethash "animations" doc) 0))
                            (concatenate 'vector channels (vector duplicate))))))))
    (%gltf-validation-reject-atomically (car case) (cdr case))))
