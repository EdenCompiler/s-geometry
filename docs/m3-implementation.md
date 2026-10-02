# M3 editor implementation and verification

M3 adds a native modeling workspace over the live Common Lisp scene and half-edge kernel. The command layer used by menus and editor actions is also callable from Lisp, the integrated listener, and command replay. Scene files use a versioned readable schema; renderer caches are rebuilt and are not serialized.

The editor's historical context is summarized in [original S-Geometry reference](original-s-geometry-summary.md). That reference explains the interaction inspiration, not a requirement to reproduce every legacy feature in M3.

**Verification status:** The headless suite passes 1,144 checks. The first-release acceptance script completed 28 native OpenGL frames, exercised its editing/listener/history flow, saved a versioned scene, and confirmed normalized scene equivalence in a fresh SBCL process. CPU checks for gizmo manipulation and workspace controls pass. The native UI smoke completed 50 frames plus popup recreation/capture checks, and the dedicated selection test passed in seven native frames, including listener-side topology editing and retired-selection cleanup.

## M3a: first usable editor

| Requirement | Implementation | Evidence |
| --- | --- | --- |
| Native editor launcher and live geometry frame | `tools/run.lisp` opens the native editor with an editable half-edge box or a saved scene. Menus, monospace panels, viewport, status, and contextual help are drawn by the in-engine OpenGL UI. | `sbcl --script tools/run.lisp --help` passes and lists the launcher options. The 28-frame native acceptance run completed its render loop. |
| Perspective and orthographic views, hierarchy, inspector, numeric edits | `src/editor/opengl-ui.lisp` and `src/editor/selection.lisp` provide perspective/front/top/side views, scene navigation, picking, numeric inspector controls, and reference navigation. | The 1,144 headless checks cover projection, picking, inspector navigation/edits, and editing rollback. Native UI smoke passed view/mode buttons, numeric position editing, mesh-reference navigation/Back, and hierarchy display. The seven-frame selection test picked the object and visible vertex/edge/face, edited the selected vertex through the inspector, and exercised face-region toggling. |
| Modeling commands, selection modes, history, and replay | `src/editor/commands.lisp` routes menu and Lisp operations through shared commands and transactions. The kernel supports object, vertex, edge, face, and connected-region selection. | The native acceptance run edited the same mesh through vertex movement, split/collapse, face/region extrusion, undo/redo, failure recovery, inspection, and command replay. The separate seven-frame native test verifies actual viewport clicks for vertex/edge/face selection, Edit > Split, one-face region selection, and Shift-click add/remove of an adjacent visible face. |
| Integrated and external Lisp access | `src/editor/listener.lisp` evaluates listener forms on a worker, binds `sgeo:*world*` and `sgeo:*selection*` to the live editor scene, and marshals public mutations to the owning thread. The optional terminal and Swank/Slynk entry points are in the same module. | Headless listener tests cover multiline input, redefinition, error recovery, dispatch ownership, and terminal behavior. Native acceptance redefined an operation in the listener and applied it to the same mesh. Native UI smoke checked multiline listener evaluation; selection testing submitted public `split-edge` from the listener worker, verified owner-thread dispatch, then confirmed stale selection cleanup and inspector fallback on the next frame. |
| Failed-edit recovery and undo/redo | `src/editor/transactions.lisp` snapshots live objects and mesh CPU state, rolls back failed edits, and advances mesh-handle generations on restoration. | The 1,144-check suite exercises rollback, undo/redo, and stale handles. Native acceptance checked failed-edit recovery and history in its frame loop. |
| Versioned scene persistence | `src/serialization/serialization.lisp` validates the schema and references before constructing a new scene, then writes through an atomic replacement. Runtime GPU resources are excluded. | Native acceptance saved the edited scene and a fresh SBCL process verified normalized equivalence; IDs are normalized because reopening creates new runtime identities. Headless serialization tests cover validation and atomic replacement. |

The inspector handles known scene/material/mesh objects, topology references, arrays, sequences, hash tables, and standard CLOS instances. Numeric edits are exposed for selected known fields. The broader reflection protocol in architecture §22 describes a future extension beyond the M3 editor deliverables; M3 does not promise generic structure or GPU-resource inspection, portable metadata for every slot, or arbitrary custom-object editors.

## M3b: workspace expansion

| Requirement | Current implementation | Verification and scope |
| --- | --- | --- |
| Transform gizmos | Axis handles support move, rotate, and scale previews, commit one command on release, cancel, and apply to scene objects including groups and triangle-mesh objects. The UI drops retired mesh-element selections and restores the object in the inspector after topology edits. | `sbcl --script tools/editor-gizmo-check.lisp` passes nine CPU interaction cases covering all three tools, cancellation, zero-distance drags, transformed parents, groups, triangle meshes, and retired-selection recovery. The native UI smoke also completed a gizmo drag. |
| Inspection and debugging views | The workspace debug panel shows the live world, camera, selection, transform, and selected half-edge topology counts. The inspector is navigable and shows known geometry/topology views. | Headless inspector tests and the workspace CPU check pass. The M3 debugging view is live scene diagnostics; the architecture document's broader debugger and reflection ideas are future extensions, not additional M3 exit requirements. |
| Configurable workspace | The Workspace menu selects debug, profile, timeline, layout, or hierarchy tools. The layout panel toggles hierarchy/inspector/history/listener and adjusts left/right/bottom panel dimensions, with a reset action. | `sbcl --script tools/editor-workspace-check.lisp` verifies visibility, minimum tool width, size limits, toggles, and reset without a graphics context. Panel preferences are configurable during the editor session; cross-session preference storage is outside M3. |
| Timeline and profiling | The timeline panel controls the live scene clock, single-frame stepping, and time scale. The profile panel plots up to 120 wall-clock frame-duration samples and reports renderer counters plus SBCL allocation and GC time when available. | Workspace CPU checks exercise clock controls and rolling profile samples. This M3 timeline controls the scene clock; animation tracks and keyframes are part of the later animation milestone. |
| UI interaction acceptance | Native menus, selection, inspector edits, listener, and gizmo interactions are covered by dedicated callback-driven checks. | `tools/editor-ui-smoke.lisp` passed 50 native frames plus popup recreation/capture checks. It covered creation menus, boxed and right-click menus, orthographic views, vertex mode, development workspace, numeric position editing, mesh-reference navigation/Back, multiline listener evaluation, Play/Pause, native gizmo drag, Profile/Debug/Layout tools, resize, panel sizing/visibility/reset, Timeline step/speed, and hierarchy. `tools/editor-selection-native.lisp` then passed seven native frames for actual object/vertex/edge/face picking, selected-vertex inspector editing, edge split from the menu, region add/remove gestures, worker-to-owner listener mutation, retired-edge cleanup, and inspector fallback. |

M3a and M3b's scoped editor deliverables have passed the headless, CPU, native command-driven, native UI, and native selection checks. Animation tracks and the broader inspector reflection ideas in architecture §§21–22 remain outside M3 scope.

## Reproduce the checks

Run the headless suite and CPU-only workspace/gizmo checks:

```bash
sbcl --script tools/test.lisp
sbcl --script tools/editor-gizmo-check.lisp
sbcl --script tools/editor-workspace-check.lisp
```

Run the native acceptance demonstration on a machine with a usable display and an OpenGL 3.3 context. The window may be hidden, but it still creates a real graphics context.

```bash
sbcl --script tools/editor-acceptance.lisp
```

The acceptance script uses the native frame loop while its hook issues reproducible editor commands. It checks a listener redefinition, live mesh edits, failure recovery, undo/redo, inspection/replay, versioned save, and fresh-process reopen. The UI smoke and direct selection test exercise callbacks in separate native runs:

```bash
sbcl --script tools/editor-ui-smoke.lisp
sbcl --script tools/editor-selection-native.lisp
```

The UI smoke captured `artifacts/editor-ui.ppm`, `artifacts/editor-profile.ppm`, and `artifacts/editor-popup.ppm` during its native run. The selection test completed seven native frames and printed `EDITOR_SELECTION_NATIVE_OK`.

Generated acceptance scenes, comparison data, and captures are written under `artifacts/` and are ignored by Git. The reopen comparison normalizes object, geometry, and material IDs because the fresh process constructs new runtime instances.

## Public entry points

The lightweight editor API lives in `sgeo.editor` and does not itself initialize graphics. `make-editor`, `execute-editor-command`, transactions, inspection, and listener functions are available after loading `:sgeo/editor`. To open the native frontend, load `:sgeo/editor/opengl` and call `sgeo.editor:open-editor` or `sgeo.editor.opengl:run-editor`; `tools/run.lisp` is the canonical user-facing launcher (`tools/editor.lisp` remains an alias). GUI actions and scripts share the same command layer and scene state.
