# M5 — Animation and glTF

M5 is complete against the deliverables and live-character exit criterion in §60 of the architecture document. It adds animation to the existing scene and editor. Clips and tracks hold Lisp objects as targets; playback changes those objects, and the renderers derive deformed meshes from the current pose. The source geometry remains editable.

The [animation guide](animation.md) covers the public API and editor controls. The milestone follows §60 of the [architecture document](modern-s-geometry-design.md).

| Deliverable | Implementation and verification |
| --- | --- |
| Property animation | Cached property paths, transform components, step/linear/cubic interpolation, quaternion interpolation, easing, event tracks, and live operation redefinition. |
| Timeline | Clip and track selection, playback, scrubbing, key recording/deletion/time edits, looping, and speed controls. Key edits use the existing transaction and undo history. |
| Skeletons and skinning | Scene-node joints, inverse bind matrices, weighted CPU skinning, inverse-transpose normals, morph targets, per-instance deformation caches, IK, and root motion. Both graphics backends use the derived meshes. |
| Blending | Weighted base layers, additive layers, path masks, paused layers, reverse playback, and reference poses. Failed pose updates restore values and clocks. |
| glTF interoperability | JSON glTF and GLB import/export, shared meshes and skins, material and image data, morph targets, and animation channels. Invalid assets are rejected before being attached to the receiving world. |
| Live character demonstration | Playback, Lisp redefinition, source vertex edits, failed-edit recovery, native timeline interaction, scene saving, and reopening in a fresh SBCL process. |

## Running it

The normal launcher continues to open the editor. It can also import an asset:

```bash
sbcl --script tools/run.lisp
sbcl --script tools/run.lisp --import character.glb
sbcl --script tools/animation-editor.lisp
```

The last command opens the bundled [Cesium Rigged Figure](../examples/assets/rigged-figure/ATTRIBUTION.md) with playback running. Select Workspace → Timeline to inspect its tracks. The asset is included with its attribution and requires no download at startup.

`sgeo/animation` and `sgeo/gltf` work without a display. The glTF system adds YASON as a dependency. Version 2 of the local `.sgeo` format stores clips, players, reference poses, skeletons, influences, morph targets, and the editable source meshes. Version 1 scenes remain readable.

## Checks

```bash
sbcl --dynamic-space-size 4096 --script tools/test.lisp
sbcl --dynamic-space-size 4096 --script tools/m5-acceptance.lisp
sbcl --dynamic-space-size 4096 --script tools/m5-vulkan-check.lisp
sbcl --dynamic-space-size 4096 --script tools/editor-ui-smoke.lisp
```

The CPU suite passes **1,898 checks with no skips or failures**, without loading GLFW or OpenGL. It covers property paths, interpolation, layered playback, events across loop boundaries, pose rollback, skeletons, morph-only meshes, normals, IK, root motion, timeline history, and animated scene persistence. The glTF fixture combines interleaved and normalized accessors, sparse positions, shared skins, five morph targets, cubic channels, Unicode names, and JSON boolean/null values. It is saved locally, undone and redone, exported, and imported again. Separate cases merge two texture libraries and reject 21 malformed assets while preserving the receiving world's objects, animation state, and source metadata.

The OpenGL acceptance script renders 12 frames and verifies changes in the character's pixels after playback, function redefinition, and source geometry edits. It uses native mouse callbacks to scrub the timeline and move a key, recovers from a failed transaction, exercises undo/redo, and exports both glTF and GLB. Its child SBCL process reopens the saved scene, compares geometry, pose, clips and player state, renders three frames, and resumes playback.

The Vulkan check renders six frames, verifies pixel and GPU-cache changes from animation and source edits, and requires zero validation messages through renderer destruction. It needs the Khronos validation layer installed. The existing editor UI check completes 50 frames plus a second popup window, including scene-clock and speed controls.

Export validation uses the official [Khronos glTF validator](https://github.com/KhronosGroup/glTF-Validator):

```bash
npm install --prefix .cache/gltf-validator --no-audit --no-fund gltf-validator
node tools/validate-gltf.cjs artifacts/m5-export.gltf artifacts/m5-export.glb artifacts/m5-reopened-export.glb
```

All three character exports have zero validator errors. Each retains a warning about the imported skinned mesh being below a parent: glTF skinning uses the joints' global transforms rather than the mesh parent's transform. The fixture export also warns about an embedded image data URI. These warnings do not imply complete support for every glTF feature.

## Interchange limits

Texture images, sampler settings, texture coordinates, material maps, and tangent data are retained for interchange and local scene saving. The current viewers use material factors; they do not sample glTF material textures. This renderer limitation is also recorded in the [M4 notes](m4-implementation.md).

The importer handles triangle lists, strips, and fans. It rejects unsupported required extensions and transforms that cannot be represented by the scene's translation/rotation/scale model, and does not fetch network resources. Export supports whole translation, rotation, scale, and morph-weight channels. Event tracks, component paths, and Lisp easing need conversion into sampled glTF channels before export. Local persistence requires named event handlers and serializable property paths; arbitrary functions and custom scene subclasses need application serializers.
