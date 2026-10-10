# Animation in S-Geometry/CL

Animation lives in `sgeo.animation`. Clips, tracks, players, and skeletons are ordinary Lisp objects. A track changes a property on its existing target; the timeline displays those same objects. Source geometry stays editable while the renderer uses a derived deformation cache for each animated instance.

Load `:sgeo/animation` to use the runtime without a display. Load `:sgeo/gltf` for interchange, or `:sgeo/editor` for timeline commands and scene persistence. The public `sg` package reexports the animation API.

```lisp
(defparameter *world* (sg:make-world))
(defparameter *door* (sg:make-scene-object :name "Door"))
(sg:add-to-world *world* *door*)

(defparameter *opening*
  (sg:animate *door* '(rotation y)
              :from 0d0 :to 1.5708d0 :duration 1.25d0))
(defparameter *player* (sg:play-animation *world* *opening* :looping-p nil))
(sg:update-world *world* 0.25d0)
(sg:seek-animation *player* 0.75d0)
```

Tracks cache property access functions when they are constructed. Transform paths accept `position`, `rotation`, and `scale`; a following `x`, `y`, or `z` selects a component. Rotation components are Euler angles in radians. A whole rotation value is an XYZW quaternion. Ordinary slot paths can animate other Lisp properties, and applications can specialize `animation-property-accessors` for their own target classes.

`make-property-track` takes a target, a path, and a list of keys. Each key is `(time value)` or `(time value in-tangent out-tangent)` for cubic interpolation. Times are seconds and must increase strictly. The interpolation modes are `:step`, `:linear`, and `:cubic-spline`. Quaternion linear interpolation follows the shortest spherical path; cubic quaternion results are normalized after Hermite interpolation. Samples outside the key range clamp to the first or last value.

```lisp
(sg:defanimation door-open
  (:duration 1.25d0)
  (track *door* '(rotation y)
    (0d0 0d0 :ease :in-out)
    (1.25d0 1.5708d0 :ease :in-out)))
```

`set-track-keys` changes the existing track. Redefining a clip's tracks or an operation used to compute a pose takes effect on the running scene. A failed pose publication restores property values and the playback clock.

Players can blend several clips with `:weight`. Base layers leave the remaining weight to their reference pose, and total weights above one are normalized. `:additive-p t` adds the difference from the clip's first key. `:mask` restricts which paths contribute. Set `player-playing-p` to pause a layer while retaining its pose; `stop-animation` disables its contribution. Negative player speed runs a clip backwards. Event tracks report crossed keys, including loop boundaries; seeking is silent by default.

For root motion, pass `:root-motion-joint` and `:root-motion-target` to `play-animation`. The translation channel moves the target across loop boundaries instead of also translating the joint. `solve-ik` adjusts an ordered joint chain toward a world-space target and accepts a pole for bend direction.

Skeleton joints are scene nodes. Inverse bind matrices and vertex influences belong to the Lisp skin object. Morph targets store position and optional normal deltas; `set-morph-weights` changes their contribution. Morph-only objects need no skeleton. CPU skinning derives render positions and normals from the current joints and source mesh. The derived cache refreshes when joints, source vertices, or morph weights change, so two objects sharing geometry can still use different poses. Both render backends receive the same derived data.

The editor exposes animation through Workspace → Timeline. The ruler scrubs continuously. Track rows select a property; key markers select a key. Key+ records the property's current value, Del removes the selected key, and the time buttons move it. The < and > buttons reach tracks outside the visible rows. Clip cycles through the world's clip library, and Loop changes the selected player's looping setting. Key edits support undo, redo, and failed-edit recovery.

```lisp
(sgeo.editor:create-editor-animation sgeo.editor:*editor*
  :object sg:*selection* :path '(position) :duration 2d0)
(sgeo.editor:scrub-animation sgeo.editor:*editor* 1d0)
(sg:set-position sg:*selection* #(1d0 2d0 0d0))
(sgeo.editor:add-animation-key sgeo.editor:*editor*)
```

glTF import accepts JSON `.gltf` and binary `.glb` files, with scene hierarchy, meshes, PBR material data, skins, morph targets, and animation channels. `import-gltf` returns an asset whose nodes, meshes, skeletons, and clips remain accessible through the asset accessors. Import validates the asset before attaching it to a supplied world. Clips are imported without starting playback.

```lisp
(defparameter *asset* (sgeo.gltf:import-gltf "character.glb" :world sg:*world*))
(sg:play-animation sg:*world* (aref (sgeo.gltf:gltf-clips *asset*) 0))
(sgeo.gltf:export-gltf sg:*world* "character-edited.glb" :binary t)
```

Texture and image data are retained for interchange. Texture sampling is a separate renderer feature; the current viewers display material factors. Unsupported required extensions are rejected. The importer does not fetch network resources.

glTF export accepts whole translation, rotation, scale, and morph-weight channels. Event tracks, component paths, and Lisp easing curves cannot be written directly as glTF channels; export rejects them explicitly. Sample them into whole-property keys when preparing an interchange asset.

Animated scenes use version 2 of the local `.sgeo` format. It stores source meshes, shared skeleton references, influences, morphs, clips, layers, and reference poses. Existing version 1 scenes remain readable. A saved event handler must be a named function already defined in the receiving Lisp image. Paths that contain arbitrary functions and custom scene subclasses need an application serializer; saving them fails explicitly.

The bundled [Rigged Figure](../examples/assets/rigged-figure/ATTRIBUTION.md) is an unchanged Cesium asset from the Khronos sample collection. Run `sbcl --script tools/animation-editor.lisp` to edit it with animation playing, or use `tools/run.lisp --import` to open another asset in the normal editor.

The interchange implementation follows the [glTF 2.0 specification](https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html). Exported assets can be checked with the [official Khronos validator](https://github.com/KhronosGroup/glTF-Validator):

```bash
npm install --prefix .cache/gltf-validator --no-audit --no-fund gltf-validator
node tools/validate-gltf.cjs character-edited.glb
```
