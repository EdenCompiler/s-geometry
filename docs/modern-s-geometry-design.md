# Modern S-Geometry in Pure Common Lisp

## Architecture and Design Specification

**Working name:** `S-Geometry/CL`  
**Project type:** Live 3D geometry, scene, simulation, animation, and game-development environment  
**Primary language:** ANSI Common Lisp  
**Design philosophy:** Lisp-native, live, inspectable, extensible, image-oriented, GPU-capable  
**Status:** Design proposal  

---

## 1. Executive Summary

This document specifies a modern re-imagining of Symbolics S-Geometry as a **pure Common Lisp 3D system** for interactive modeling, simulation, visualization, animation, and game development.

The central idea is not to reproduce a 1980s polygon modeler feature-for-feature. The goal is to recover the more important architectural property of the original environment:

> The 3D world is made of real Lisp objects that remain alive, inspectable, programmable, redefinable, and editable while the application is running.

Historical S-Geometry supplied geometric capabilities to live Lisp objects. Craig Reynolds' original Boids implementation, for example, was written in Symbolics Common Lisp and layered its geometric behavior on S-Geometry; S-Dynamics supplied animation and playback. That style of integration is the conceptual starting point for this project.

A modern system should extend that idea to contemporary requirements:

- real-time 2D and 3D rendering;
- editable polygonal and procedural geometry;
- scene graphs and spatial databases;
- materials, cameras, lighting, animation, and skeletal rigs;
- GPU compute and rendering;
- collision and physics integration;
- large worlds and spatial streaming;
- game-oriented entities and behaviors;
- live code redefinition;
- image-oriented development;
- inspector/editor/REPL integration;
- serialization and deterministic asset builds;
- optional compilation to standalone applications;
- desktop and, where practical, mobile targets;
- a Lisp-native shader and GPU-kernel language.

The engine itself should be implemented in Common Lisp. Platform APIs, graphics drivers, audio APIs, and operating-system services are necessarily foreign interfaces on conventional hardware, so thin FFI bindings are permitted. They must remain **backends**, not hidden C or C++ engine layers.

The intended architecture is:

```text
                         COMMON LISP IMAGE
                                │
              ┌─────────────────┼─────────────────┐
              │                 │                 │
           REPL/IDE         Inspector          Editor
              │                 │                 │
              └─────────────────┼─────────────────┘
                                │
                         LIVE OBJECT WORLD
                                │
       ┌────────────────────────┼─────────────────────────┐
       │                        │                         │
    Geometry                 Scene                    Runtime
       │                        │                         │
 topology / mesh        transforms / space       simulation / game
 curves / CSG           cameras / lighting       animation / physics
 procedural forms       queries / streaming      events / behaviors
       │                        │                         │
       └────────────────────────┼─────────────────────────┘
                                │
                         Render Abstraction
                                │
                   Lisp GPU IR / Shader Lisp
                                │
          ┌─────────────────────┼─────────────────────┐
          │                     │                     │
       Vulkan                 Metal               OpenGL/WebGPU*
          │                     │                     │
          └──────────────────── GPU/OS ──────────────┘
```

`*` Backend availability is implementation- and platform-dependent.

---

## 2. Historical Inspiration

### 2.1 What should be preserved

The project should preserve the following ideas associated with S-Geometry and the Symbolics development style:

1. **Geometry is programmable data.**
   Vertices, edges, faces, objects, transforms, and cameras are manipulable from Lisp.

2. **Graphical objects are native Lisp objects.**
   There is no mandatory separation between an editor-side object and a runtime-side object.

3. **The development image remains live.**
   Methods and functions may be redefined while the scene continues to exist.

4. **The object inspector is a serious development interface.**
   An entity can be inspected, changed, diagnosed, and resumed rather than merely printed as an opaque handle.

5. **Graphics is a substrate for other applications.**
   Simulation, animation, AI, game systems, scientific visualization, and modeling are built on top rather than embedded into a monolithic editor.

6. **The programming environment and graphics environment are one system.**
   REPL, debugger, object inspector, source editor, and scene editor all operate on the same live world.

### 2.2 What should not be preserved blindly

A modern system should not inherit historical limitations merely for authenticity:

- CPU-only rendering;
- fixed-function graphics assumptions;
- small-memory data structures optimized for old hardware;
- architecture-specific Lisp Machine dependencies;
- exclusively polygonal workflows;
- animation systems that assume offline rendering;
- monolithic global state;
- inability to exploit GPU compute;
- lack of contemporary skeletal animation and physically based shading;
- lack of asset interoperability.

The project is therefore **spiritually S-Geometry, technically modern**.

---

## 3. Design Goals

### 3.1 Primary goals

The system SHALL:

- be implemented primarily in ANSI Common Lisp;
- expose all high-level scene and geometry objects as ordinary Lisp objects;
- support live code redefinition without requiring world restart;
- make editor state and runtime state mutually inspectable;
- provide a modern GPU rendering abstraction;
- provide editable topology, not just immutable render meshes;
- support procedural geometry as a first-class concept;
- provide a Lisp-native shader/GPU language;
- support both immediate experimentation and deployable applications;
- allow subsystems to be used independently;
- expose documented stable interfaces between subsystems;
- make errors recoverable where possible via the Common Lisp condition system;
- make extension through CLOS and generic functions normal rather than exceptional.

### 3.2 Secondary goals

The system SHOULD:

- support Windows, Linux, and macOS;
- permit Android and iOS targets when the host Lisp implementation supports deployment there;
- support Vulkan as a primary explicit graphics backend;
- support Metal either directly or through an appropriate translation/backend layer;
- optionally support OpenGL for compatibility and development;
- support deterministic headless scene processing;
- support glTF import/export;
- expose GPU compute kernels to Lisp;
- provide a lightweight in-engine UI toolkit rather than requiring Qt/GTK;
- permit automated manipulation by coding agents through ordinary Lisp APIs;
- support server/headless simulation without initializing graphics.

### 3.3 Non-goals for version 1

Version 1 SHALL NOT attempt to be:

- a full Blender replacement;
- a full Maya replacement;
- an Unreal Engine feature clone;
- a physically exact CAD/BREP system;
- a professional film compositor;
- a distributed MMO backend;
- a general theorem prover;
- a production ray tracer with every offline-film feature.

Those can become packages layered above the core later.

---

## 4. Fundamental Architectural Rule

The most important rule is:

> **The authoritative representation of an object is a Lisp object, not a GPU resource, editor proxy, ECS integer, or serialized asset.**

A GPU mesh is a cached projection of geometry.

A saved file is a serialized projection of objects.

An editor widget is a view of objects.

A runtime entity is an object or references objects.

A physics body is an associated backend representation.

This gives the architecture a clear direction of authority:

```text
                  Lisp Object
                      │
        ┌─────────────┼───────────────┐
        │             │               │
    GPU cache      Physics proxy   Editor view
        │             │               │
        └─────────────┼───────────────┘
                      │
                  derived state
```

Never invert this relationship accidentally.

---

## 5. System Layers

The system is divided into layers so that lower-level facilities remain independently useful.

```text
sgeo.core
sgeo.math
sgeo.conditions
sgeo.memory

sgeo.geometry
sgeo.topology
sgeo.curves
sgeo.surfaces
sgeo.procedural
sgeo.csg

sgeo.scene
sgeo.spatial
sgeo.camera
sgeo.light

sgeo.gpu
sgeo.shader
sgeo.render
sgeo.material

sgeo.animation
sgeo.physics
sgeo.audio
sgeo.input

sgeo.runtime
sgeo.game

sgeo.editor
sgeo.inspector
sgeo.ui
sgeo.commands

sgeo.assets
sgeo.serialization
sgeo.import.gltf
sgeo.export.gltf

sgeo.platform
sgeo.backend.vulkan
sgeo.backend.metal
sgeo.backend.opengl

sgeo.build
sgeo.deploy
sgeo.tests
```

No game-specific package should be required to use the geometry system.

---

## 6. Core Object Model

### 6.1 Base object

All significant user-visible objects derive from a small base protocol.

```lisp
(defclass sgeo-object ()
  ((id
    :initform (make-object-id)
    :reader object-id)
   (name
    :initarg :name
    :initform nil
    :accessor object-name)
   (metadata
    :initform (make-hash-table :test 'equal)
    :accessor object-metadata)
   (revision
    :initform 0
    :accessor object-revision)))
```

The engine SHALL NOT require every tiny math value to be a CLOS object. Performance-sensitive primitives should use specialized arrays, structures, or implementation-specific unboxed representations.

### 6.2 Protocol-oriented design

Behavior is exposed through generic functions rather than deep inheritance alone.

Examples:

```lisp
(defgeneric bounds (object))
(defgeneric transform-of (object))
(defgeneric renderable-p (object))
(defgeneric compile-render-data (object context))
(defgeneric update-object (object world dt))
(defgeneric serialize-object (object stream))
(defgeneric inspect-object (object inspector))
(defgeneric dependencies-of (object))
(defgeneric invalidate-object (object reason))
```

This allows user classes to participate without inheriting from a huge engine hierarchy.

### 6.3 Revision tracking

Every editable object has a monotonically increasing revision number.

When geometry changes:

```text
Lisp object revision 41
        ↓ edit
revision 42
        ↓
render cache detects stale revision
        ↓
rebuild/upload only affected resources
```

This enables automatic synchronization between live Lisp objects and backend resources.

---

## 7. Mathematical Kernel

A modern S-Geometry needs a deliberately designed math layer rather than scattered vector utilities.

### 7.1 Required primitives

- scalar types;
- `vec2`, `vec3`, `vec4`;
- integer vectors;
- quaternion;
- 2x2, 3x3, 4x4 matrices;
- affine transform;
- ray;
- plane;
- AABB;
- OBB;
- sphere;
- frustum;
- line and segment;
- triangle;
- barycentric coordinates;
- dual quaternion for skeletal transforms where beneficial.

### 7.2 Representation

Use specialized arrays or structures, with compiler macros for important operations.

Example surface API:

```lisp
(v+ a b)
(v- a b)
(v* a scalar)
(dot a b)
(cross a b)
(normalize v)
(mat* a b)
(transform-point matrix point)
(transform-direction matrix direction)
```

The implementation SHOULD provide type declarations and implementation-specific optimization modules for SBCL, CCL-like systems, ECL, clasp, or future implementations without contaminating the portable public API.

### 7.3 Allocation discipline

Both functional and destructive variants should exist where appropriate:

```lisp
(v+ a b)             ; convenient, may allocate
(v+! destination a b) ; explicit destination
```

Hot loops should use stack allocation or reusable arenas when supported.

---

## 8. Geometry Kernel

The geometry kernel is the heart of the system.

### 8.1 Two representations

A single representation is insufficient for both modeling and rendering.

Use two related forms:

#### Editable topology

A topology-rich structure optimized for mutation and queries.

Recommended baseline: **half-edge mesh**.

```text
Vertex ──> HalfEdge ──> Face
   ↑          │  │
   │          │  ├── next
   │          │  ├── twin
   └──────────┘  └── vertex
```

Advantages:

- efficient adjacency queries;
- face traversal;
- edge splitting;
- extrusion;
- beveling;
- topology-aware editing;
- manifold validation.

#### Render mesh

Flattened/indexed GPU representation:

```text
positions[]
normals[]
tangents[]
uv[]
colors[]
indices[]
material-ranges[]
```

It is derived from editable topology and cached by revision.

### 8.2 Core geometry classes

```text
geometry
├── mesh
│   ├── editable-mesh
│   └── render-mesh
├── curve
│   ├── polyline
│   ├── bezier-curve
│   ├── b-spline
│   └── nurbs-curve (later)
├── surface
│   ├── parametric-surface
│   └── subdivision-surface
├── implicit-shape
│   ├── sphere-field
│   ├── sdf
│   └── compound-field
└── procedural-geometry
```

### 8.3 Topological operations

Version 1 should support:

- create/delete vertex;
- create/delete edge;
- create/delete face;
- split edge;
- collapse edge;
- split face;
- triangulate;
- extrude face/region;
- inset;
- bevel;
- bridge loops;
- weld vertices;
- duplicate region;
- flip winding;
- recalculate normals;
- connected-component extraction;
- manifold checks;
- boundary-loop discovery.

### 8.4 Geometry queries

Required:

```lisp
(vertices mesh)
(edges mesh)
(faces mesh)
(neighbors vertex)
(adjacent-faces edge)
(face-normal face)
(face-area face)
(mesh-volume mesh)
(mesh-centroid mesh)
(ray-intersect mesh ray)
(closest-point mesh point)
```

### 8.5 Attributes

Arbitrary typed attributes should be attachable to geometric domains:

```text
vertex attributes
edge attributes
face attributes
corner/loop attributes
object attributes
```

Examples:

- UV coordinates;
- vertex colors;
- skin weights;
- selection flags;
- material IDs;
- procedural tags;
- simulation coefficients.

Do not hard-code every future attribute into mesh slots.

---

## 9. Procedural Geometry

Procedural geometry must be first-class rather than an optional plugin.

### 9.1 Primitive constructors

```lisp
(make-box :size '(1 1 1))
(make-sphere :radius 1.0 :segments 32)
(make-cylinder :radius 1.0 :height 2.0)
(make-grid :x 32 :y 32)
(make-torus ...)
```

### 9.2 Geometry programs

A procedural object stores both parameters and a generator.

```lisp
(defclass procedural-object (scene-object)
  ((generator :initarg :generator :accessor generator)
   (parameters :initarg :parameters :accessor parameters)
   (result :accessor generated-geometry)))
```

Example:

```lisp
(define-geometry-generator asteroid ((radius 10.0)
                                     (roughness 0.4)
                                     (seed 1))
  (-> (make-icosphere :radius radius)
      (noise-displace :amount (* radius roughness)
                      :seed seed)
      (recalculate-normals)))
```

Changing `roughness` in the inspector rebuilds the result.

### 9.3 Dependency graph

Procedural generation should use a dependency graph:

```text
radius ───────┐
roughness ────┼──> asteroid generator ──> mesh ──> render cache
seed ─────────┘
```

Only dependent nodes are invalidated.

### 9.4 Geometry-node compatibility without a node-only architecture

A visual node editor may be provided, but nodes SHALL compile to ordinary Lisp forms or dependency objects.

The canonical representation remains programmable Lisp, not a proprietary graph blob.

---

## 10. Constructive Solid Geometry and Implicit Geometry

### 10.1 CSG protocol

```lisp
(csg-union a b)
(csg-intersection a b)
(csg-difference a b)
```

Initially support mesh booleans with robust predicates. Later support SDF/implicit CSG.

### 10.2 Signed distance fields

A Lisp DSL can describe an SDF:

```lisp
(defsdf rounded-box ((p vec3) (size vec3) (radius single-float))
  (- (length (max (- (abs p) size) 0.0)) radius))
```

The same definition may target:

- CPU evaluation;
- meshing;
- collision approximation;
- GPU ray marching;
- GPU compute.

This reuse is exactly the sort of Lisp-native unification the project should encourage.

---

## 11. Scene Model

### 11.1 Scene object

```lisp
(defclass scene-object (sgeo-object)
  ((parent :initform nil :accessor parent)
   (children :initform (make-array 0 :adjustable t :fill-pointer 0)
             :accessor children)
   (local-transform :initform (identity-transform)
                    :accessor local-transform)
   (world-transform-cache :accessor world-transform-cache)
   (visible-p :initform t :accessor visible-p)
   (enabled-p :initform t :accessor enabled-p)))
```

### 11.2 Scene graph is not the whole world database

The hierarchy expresses transform/ownership relationships.

Spatial lookup should use separate indices:

- BVH;
- loose octree;
- dynamic AABB tree;
- uniform grid;
- specialized world partition.

This avoids abusing parent-child hierarchy for visibility and collision queries.

### 11.3 Scene API

```lisp
(add-child parent child)
(remove-child parent child)
(reparent child new-parent)
(world-transform object)
(local->world object point)
(world->local object point)
(find-object scene 'player)
(query-region scene aabb)
(ray-cast scene ray)
```

---

## 12. Entity and Game Model

S-Geometry/CL is a geometry system first, but it should make game development natural.

### 12.1 Avoid forcing a single ECS ideology

Support three styles simultaneously:

1. CLOS objects;
2. composition through capability objects/components;
3. packed data-oriented stores for large homogeneous populations.

A developer should not need an ECS for a door, but should not need ten million CLOS instances for a particle simulation either.

### 12.2 Capability protocols

Examples:

```lisp
(defgeneric update (object world dt))
(defgeneric fixed-update (object world dt))
(defgeneric receive-event (object event))
(defgeneric damage (object amount &key source))
(defgeneric interact (actor target))
```

### 12.3 Example entity

```lisp
(defclass enemy-ship (scene-object)
  ((health :initform 100 :accessor health)
   (velocity :initform (vec3 0 0 0) :accessor velocity)
   (target :initform nil :accessor target)
   (weapon :initarg :weapon :accessor weapon)))

(defmethod update ((ship enemy-ship) world dt)
  (when-let ((target (target ship)))
    (steer-toward ship target dt)))
```

The same instance remains visible to:

- the renderer;
- the game loop;
- the editor;
- the inspector;
- the debugger;
- REPL code.

---

## 13. Rendering Architecture

### 13.1 Do not expose Vulkan everywhere

Vulkan or Metal concepts should be confined to backend and advanced rendering packages.

Most users should work with:

```text
scene
camera
mesh
material
light
render-target
render-pass
```

### 13.2 Render graph

Represent each frame as a declarative render graph.

```lisp
(define-render-graph main-renderer
  (shadow-pass ...)
  (gbuffer-pass :depends-on (shadow-pass) ...)
  (lighting-pass :depends-on (gbuffer-pass) ...)
  (transparent-pass :depends-on (lighting-pass) ...)
  (post-process-pass :depends-on (transparent-pass) ...)
  (ui-pass :depends-on (post-process-pass) ...))
```

The backend determines resource barriers and transient resource lifetimes.

### 13.3 Rendering paths

Initial engine:

- forward+ or clustered forward rendering;
- physically based metallic/roughness material model;
- shadow maps;
- image-based lighting;
- MSAA where supported;
- HDR render target;
- tone mapping;
- GPU instancing;
- frustum culling;
- optional occlusion culling.

Later:

- deferred path;
- virtual shadow maps;
- mesh shaders where available;
- ray tracing backend;
- path-tracing viewport.

### 13.4 Renderable protocol

```lisp
(defgeneric gather-renderables (object collector view))
(defgeneric render-bounds (object))
(defgeneric render-layer (object))
```

This allows custom objects without modifying renderer internals.

---

## 14. Lisp Shader Language

A modern S-Geometry should not force users to leave Lisp for GLSL/HLSL unless they choose to.

### 14.1 Working name

`SGL` — **S-Geometry Language**.

It is a restricted Lisp language compiled to a GPU intermediate representation.

### 14.2 Example

```lisp
(defshader vertex standard-vertex
    ((position :vec3 :location 0)
     (normal   :vec3 :location 1)
     (uv       :vec2 :location 2)
     (model    :mat4 :uniform)
     (view-projection :mat4 :uniform))
  (values
   (:position (* view-projection model (vec4 position 1.0)))
   (:world-normal (normalize (* (mat3 model) normal)))
   (:uv uv)))

(defshader fragment standard-fragment
    ((world-normal :vec3)
     (uv :vec2)
     (albedo :sampler2d :uniform))
  (let ((base (texture albedo uv)))
    (:color (* base
               (max 0.05
                    (dot (normalize world-normal)
                         (normalize (vec3 0.3 0.8 0.2))))))))
```

### 14.3 Compiler pipeline

```text
SGL source
   │
read Lisp forms
   │
macro expansion
   │
typed shader AST
   │
validation
   │
SGIR
   │
   ├──> SPIR-V
   ├──> MSL
   └──> GLSL (compatibility/debug)
```

### 14.4 Shared CPU/GPU math

Where possible, pure mathematical definitions should have both CPU and GPU compilation paths.

Example:

```lisp
(defgpu-function fresnel-schlick ((cos-theta :float)
                                  (f0 :vec3))
  (+ f0 (* (- 1.0 f0)
           (pow (- 1.0 cos-theta) 5.0))))
```

The user can test this function on the CPU and compile it for shaders.

### 14.5 GPU compute

The same language should support compute kernels:

```lisp
(defcompute update-particles
    ((particles :storage-buffer particle)
     (dt :float :uniform))
  (:workgroup-size 256 1 1)
  (let* ((i (global-invocation-id-x))
         (p (aref particles i)))
    (incf (particle-position p)
          (* (particle-velocity p) dt))
    (setf (aref particles i) p)))
```

This is critical for simulation workloads.

---

## 15. Materials

Materials are Lisp objects describing shader programs and bound resources.

```lisp
(defclass material (sgeo-object)
  ((shader :initarg :shader :accessor material-shader)
   (parameters :initform (make-hash-table) :accessor material-parameters)))
```

### 15.1 Standard PBR material

```lisp
(make-pbr-material
 :base-color #(0.8 0.2 0.1 1.0)
 :metallic 0.4
 :roughness 0.25
 :normal-map texture)
```

### 15.2 Live shader replacement

If a shader recompiles successfully:

```text
old pipeline remains active
       ↓
compile new shader asynchronously
       ↓
create new pipeline
       ↓
atomically swap
       ↓
defer old GPU resource destruction
```

A shader compile failure should signal a recoverable Lisp condition and leave the old program active.

---

## 16. Cameras and Views

Cameras are normal scene objects.

```lisp
(defclass camera (scene-object)
  ((projection :accessor camera-projection)
   (near :initform 0.1)
   (far :initform 10000.0)
   (exposure :initform 1.0)))
```

Support:

- perspective;
- orthographic;
- physical camera parameters;
- stereo views;
- offscreen views;
- editor views;
- cubemap capture;
- picking rays.

The editor may display multiple simultaneous cameras using the same world.

---

## 17. Lighting

Initial lights:

- directional;
- point;
- spot;
- area approximation;
- environment light;
- emissive geometry contribution where supported.

Lighting objects remain Lisp objects and may be generated procedurally.

```lisp
(make-instance 'point-light
 :name 'lamp
 :intensity 1200.0
 :color #(1.0 0.82 0.65))
```

---

## 18. Animation System

The spiritual successor to S-Dynamics should be integrated as `sgeo.animation`.

### 18.1 Animation data model

```text
animation-clip
├── tracks
│   ├── property-track
│   ├── transform-track
│   ├── skeletal-track
│   └── event-track
└── duration
```

### 18.2 Animate arbitrary Lisp properties

A major Lisp-native feature:

```lisp
(animate object
  '(health)
  :from 0
  :to 100
  :duration 2.0)
```

or:

```lisp
(animate light
  '(intensity)
  :keys '((0.0 0.0)
          (0.2 5000.0)
          (1.0 800.0)))
```

Property paths are compiled/cached rather than interpreted every frame.

### 18.3 Skeletal animation

Support:

- skeletons;
- skinning;
- animation clips;
- blending;
- additive layers;
- masks;
- inverse kinematics;
- root motion.

GPU skinning is a render optimization; the authoritative skeleton state remains Lisp-side unless explicitly GPU-driven.

### 18.4 Timeline editor

A timeline is a view over animation objects, not a separate proprietary project representation.

---

## 19. Physics

### 19.1 Architectural rule

Physics is optional and detachable.

```text
scene-object
   │
physics-binding
   │
physics-world
```

### 19.2 Pure Lisp strategy

Long-term goal: a Common Lisp physics implementation for common primitives and constraints.

Version 1 can prioritize:

- broad-phase AABB tree;
- ray casts;
- overlap tests;
- sphere/capsule/box collision;
- convex collision using GJK/EPA;
- impulses;
- simple rigid bodies;
- character controller.

More advanced physics may be added progressively.

### 19.3 Foreign physics backends

Optional adapter packages may support Bullet/Jolt/etc., but these SHALL NOT become mandatory dependencies of the engine.

---

## 20. Spatial Database

The scene graph is insufficient for a modern world.

Provide a pluggable `spatial-index` protocol.

```lisp
(defgeneric spatial-insert (index object bounds))
(defgeneric spatial-remove (index object))
(defgeneric spatial-update (index object old-bounds new-bounds))
(defgeneric spatial-query-aabb (index bounds))
(defgeneric spatial-ray-query (index ray))
```

Implementations:

- dynamic AABB tree;
- BVH;
- loose octree;
- uniform grid;
- static mesh BVH.

Objects choose appropriate indices by role.

---

## 21. Editor Architecture

The editor must not become a separate application with a private copy of the scene.

### 21.1 Core rule

> **The editor is a collection of Lisp views and commands over the live world.**

### 21.2 Main panels

```text
┌─────────────────────────────────────────────────────────────┐
│ Menu / command bar                                          │
├─────────────┬───────────────────────────┬───────────────────┤
│ Hierarchy   │                           │ Inspector         │
│             │        3D Viewport        │                   │
│ Scene       │                           │ slots             │
│ Objects     │                           │ metadata          │
│             │                           │ components        │
├─────────────┴───────────────────────────┴───────────────────┤
│ REPL / Listener / Debugger / Build Output                  │
├─────────────────────────────────────────────────────────────┤
│ Timeline / Animation / Profiler                            │
└─────────────────────────────────────────────────────────────┘
```

### 21.3 UI implementation

Prefer an in-engine retained/immediate hybrid UI written in Common Lisp and rendered through the engine.

Reasons:

- deployment simplicity;
- consistent cross-platform behavior;
- easy integration with the graphics context;
- no Qt/GTK C++ object model controlling the architecture;
- easier reflection over Lisp objects;
- usable in a shipped game's debugging tools.

### 21.4 Editor commands

All editor actions should be represented as commands:

```lisp
(defclass command () ...)
(defgeneric execute-command (command world))
(defgeneric undo-command (command world))
```

Example:

```lisp
(move-object-command object old-transform new-transform)
```

This gives:

- undo/redo;
- macro recording;
- scripting;
- reproducibility;
- remote control;
- AI-assisted authoring.

### 21.5 Everything the mouse can do should have a Lisp API

If the user can extrude a face by mouse, there must be an underlying operation such as:

```lisp
(extrude-region mesh selected-faces :distance 1.0)
```

The GUI calls the Lisp function. The Lisp function is not reverse-engineered from GUI events.

---

## 22. Inspector

The inspector is one of the project's defining features.

### 22.1 Reflection protocol

Use MOP support when available, but keep a portable abstraction.

The inspector should understand:

- CLOS slots;
- structures;
- arrays;
- hash tables;
- sequences;
- geometry;
- textures;
- GPU buffers;
- scene relationships;
- animation tracks;
- custom user objects.

### 22.2 Editable slots

Slots can provide metadata:

```lisp
(defclass point-light (scene-object)
  ((intensity
    :initform 1000.0
    :accessor intensity
    :editor (:type :float :min 0.0 :max 100000.0 :log-scale t))))
```

A portability layer may implement `:editor` through separate metadata if a given CLOS implementation dislikes custom slot options.

### 22.3 Object references are navigable

Clicking:

```text
target = #<PLAYER 0x...>
```

opens that object.

Selecting geometry can navigate:

```text
scene-object
  → mesh
    → face 481
      → edge 31
        → vertex 87
```

This should feel like a graphical continuation of a Lisp Machine inspector.

---

## 23. Live Development

Live development is not a convenience feature. It is a core requirement.

### 23.1 Function redefinition

Running worlds must tolerate:

```lisp
(defun enemy-steering (...) ...)
```

being recompiled while enemies exist.

### 23.2 Class redefinition

CLOS class redefinition should be supported where the implementation permits it.

Example:

```lisp
(defclass enemy (scene-object)
  ((health ...)
   (target ...)))
```

later becomes:

```lisp
(defclass enemy (scene-object)
  ((health ...)
   (target ...)
   (morale :initform 1.0)))
```

Existing instances should update using the implementation's class-redefinition mechanisms.

### 23.3 Conditions and restarts

Engine operations should signal structured conditions.

Example:

```text
MESH-TOPOLOGY-ERROR
Face 348 refers to deleted half-edge 992.

Restarts:
  0. Delete invalid face.
  1. Attempt topology repair.
  2. Restore mesh to last valid revision.
  3. Ignore and keep editing.
  4. Abort operation.
```

Do not convert everything into strings and fatal exceptions.

### 23.4 Keep previous working resources

For recoverable development failures:

- shader compile fails → keep old shader;
- mesh rebuild fails → retain prior render mesh;
- procedural generator errors → retain prior result;
- script method errors → debugger can repair and continue.

---

## 24. World Loop

### 24.1 Explicit world object

Avoid hidden singleton state.

```lisp
(defclass world ()
  ((scene ...)
   (clock ...)
   (scheduler ...)
   (physics ...)
   (render-world ...)
   (event-bus ...)))
```

### 24.2 Update phases

```text
poll platform events
        ↓
input mapping
        ↓
pre-update
        ↓
fixed simulation steps
        ↓
variable update
        ↓
animation
        ↓
transform propagation
        ↓
spatial-index update
        ↓
render extraction
        ↓
render graph execution
        ↓
present
```

Each phase exposes hooks/generic functions.

### 24.3 Development loop

```lisp
(run-world *world* :mode :interactive)
```

The engine loop must cooperate with SLIME/Sly/REPL processing rather than monopolizing the Lisp thread.

Options include:

- dedicated render thread;
- implementation-specific event-loop integration;
- cooperative listener servicing;
- platform-specific main-thread dispatch where required.

---

## 25. Threading Model

### 25.1 Goals

- keep the Lisp REPL responsive;
- prevent arbitrary GPU calls from every thread;
- permit job-system parallelism;
- avoid making every object thread-safe by default.

### 25.2 Recommended model

```text
Main/UI thread
  - platform events
  - UI ownership where OS requires

Simulation thread
  - world mutation
  - gameplay

Render thread
  - render extraction consumption
  - GPU submission

Worker pool
  - asset decoding
  - mesh processing
  - BVH building
  - procedural generation
  - compilation work
```

For simpler programs, main/simulation/render can collapse into one thread.

### 25.3 Render snapshots

The renderer should consume immutable or versioned extraction data rather than traversing a world while the simulation mutates it.

```text
Live Lisp World
      ↓ extraction
Frame N render snapshot
      ↓
Render thread
```

This keeps the Lisp world authoritative without requiring global locks around rendering.

---

## 26. Memory Management

Common Lisp's GC is an advantage for authoring but requires discipline in frame-critical code.

### 26.1 Strategy

- ordinary Lisp allocation for tools and non-critical code;
- object pools/arenas for transient render extraction;
- specialized arrays for bulk numeric data;
- explicit foreign/GPU resource lifetime wrappers;
- finalizers only as a safety net, never primary GPU cleanup;
- frame allocators reset after fences complete.

### 26.2 Resource scopes

Provide macros:

```lisp
(with-command-buffer (cmd device)
  ...)

(with-temporary-buffer (buffer size)
  ...)
```

while long-lived resources use Lisp objects and explicit disposal:

```lisp
(dispose texture)
```

---

## 27. GPU Resource Model

GPU objects are backend resources referenced by Lisp wrappers.

```text
texture-resource
buffer-resource
sampler-resource
pipeline-resource
framebuffer/render-target
command-buffer
```

A high-level resource contains:

- backend handle;
- device association;
- generation/revision;
- destruction state;
- debug name;
- source object reference where applicable.

GPU handles must never be treated as authoritative world identity.

---

## 28. Asset System

### 28.1 Assets are optional persistence, not identity

Runtime objects do not need to originate from files.

A mesh can be:

- imported;
- generated procedurally;
- constructed from REPL calls;
- loaded from an image;
- downloaded;
- synthesized by simulation.

### 28.2 Asset objects

```lisp
(load-asset "models/ship.glb")
(load-asset "textures/stone.ktx2")
```

Assets have:

- source URI;
- content hash;
- importer version;
- dependencies;
- build products;
- live reload watcher;
- canonical Lisp representation when appropriate.

### 28.3 Import pipeline

```text
source file
   ↓
importer
   ↓
canonical Lisp asset objects
   ↓
validation
   ↓
optional optimization
   ↓
runtime cache
```

### 28.4 glTF

glTF 2 should be the first serious interchange target because it maps well to modern runtime assets.

Support:

- scenes;
- meshes;
- PBR materials;
- textures;
- skeletons;
- animation;
- morph targets.

---

## 29. Serialization

Use two modes.

### 29.1 Source representation

Human-readable Lisp data:

```lisp
(:scene
 (:object :id 1001
          :class enemy-ship
          :name "Interceptor"
          :transform (...)
          :health 100))
```

This should be diffable and version-controllable.

### 29.2 Packed runtime representation

For startup-sensitive applications, compile source assets into a binary cache with:

- schema/version;
- endianness metadata;
- hashes;
- packed arrays;
- prebuilt BVHs;
- precompiled shaders;
- texture transcodes.

Source is authoritative; packed caches are disposable build products.

---

## 30. Undo/Redo and Transactions

Geometry editing requires transactional operations.

```lisp
(with-edit-transaction (*scene* "Extrude roof")
  (extrude-region mesh faces :distance 2.0)
  (move-object chimney ...))
```

If an error occurs, a restart can roll back the transaction.

The transaction log also powers:

- undo/redo;
- collaborative editing later;
- command recording;
- reproducible editor actions.

---

## 31. Selection and Picking

Selection should be domain aware.

```text
object selection
vertex selection
edge selection
face selection
bone selection
curve-point selection
```

GPU ID buffers may accelerate picking, but the returned value resolves to real Lisp objects or stable geometric element IDs.

---

## 32. Input System

Separate raw platform input from semantic actions.

```lisp
(define-input-map gameplay
  (:move-forward (:key :w) (:gamepad-axis :left-y :positive))
  (:move-back    (:key :s))
  (:fire         (:mouse-button :left) (:gamepad-button :right-trigger)))
```

Queries:

```lisp
(action-down-p input :fire)
(action-value input :move-forward)
```

The editor uses a separate input context.

---

## 33. Audio

Audio is not central to geometry, but a game-ready environment needs it.

Provide a pure Lisp object layer over platform/audio backends.

Objects:

- audio-buffer;
- audio-stream;
- audio-source;
- listener;
- bus;
- effect;
- mixer.

3D audio sources use the same scene transforms as geometry.

---

## 34. Debug Visualization

Every subsystem should be able to draw diagnostics without building permanent meshes manually.

```lisp
(debug-line a b)
(debug-ray ray)
(debug-aabb bounds)
(debug-sphere center radius)
(debug-text position "Target")
```

Useful overlays:

- collision shapes;
- BVH nodes;
- normals/tangents;
- skeletons;
- nav graphs;
- light volumes;
- overdraw;
- shader complexity;
- frame timings.

---

## 35. Profiling

The profiler should expose Lisp and engine concepts together.

### 35.1 CPU profiler

```lisp
(with-profile-scope ("AI/steering")
  ...)
```

Aggregate by:

- function;
- subsystem;
- object class;
- thread;
- frame phase.

### 35.2 GPU profiler

Backends expose timestamp queries and pipeline statistics.

Results appear in the same profiler timeline as CPU events.

### 35.3 Allocation profiler

Per-frame allocation is especially important in Lisp games.

The editor should report:

```text
Frame 2841
  consed bytes: 1.3 MB
  top allocator:
    GATHER-RENDERABLES/ENEMY   640 KB
```

---

## 36. Determinism and Replay

For debugging and simulation, optionally record:

- input events;
- random seeds;
- fixed-step count;
- command log;
- external messages.

Then:

```lisp
(replay-session "bug-1842.sgreplay")
```

This is particularly useful when live-debugging a difficult state.

---

## 37. REPL-Driven Workflow

Example session:

```lisp
(ql:quickload :sgeo)

(defparameter *world* (make-world))
(defparameter *camera* (make-camera))

(add-to-world *world*
  (make-instance 'mesh-object
                 :geometry (make-box :size '(2 2 2))))

(open-editor *world*)
(run-world *world*)
```

While it is running:

```lisp
(spawn *world* 'enemy :position '(10 0 30))

(mapc (lambda (e)
        (setf (health e) 500))
      (objects-of-type *world* 'enemy))
```

Redefine:

```lisp
(defmethod update ((enemy enemy) world dt)
  (seek enemy (player world) dt))
```

The existing enemies now use the new method.

---

## 38. Authoring DSLs

Common Lisp macros should make high-level content pleasant to author.

### 38.1 Scene DSL

```lisp
(defscene hangar
  (camera main-camera
    :position '(0 3 -10))

  (light sun
    :type :directional
    :rotation '(35 -20 0))

  (object floor
    :geometry (box 40 0.25 40)
    :material 'concrete)

  (spawn enemy-ship
    :position '(0 2 20)
    :count 8))
```

### 38.2 Animation DSL

```lisp
(defanimation door-open
  (:duration 1.25)
  (track door '(rotation y)
    (0.0 0.0 :ease :in-out)
    (1.25 1.5708 :ease :in-out)))
```

### 38.3 Behavior/state-machine DSL

```lisp
(defstate-machine guard-ai
  (:idle
   (on :see-player -> :chase))
  (:chase
   (during (move-toward target))
   (on :lost-player -> :search))
  (:search
   (after 5.0 -> :idle)))
```

These DSLs expand to normal Lisp objects/functions and remain inspectable.

---

## 39. AI-Friendly Programming Surface

The system should be easy for both humans and coding agents to modify safely.

### 39.1 Principles

- textual Lisp API is complete;
- editor actions map to named commands;
- objects have stable IDs;
- introspection is programmatic;
- schemas can be queried;
- error conditions are structured;
- generated code can be evaluated in isolated packages/worlds;
- documentation strings and arglists are authoritative;
- no hidden binary scene format is required for basic authoring.

### 39.2 Introspection API

```lisp
(describe-scene *world*)
(list-objects *world* :class 'light)
(schema-of 'point-light)
(available-commands :selection *selection*)
(command-arguments 'extrude-region-command)
```

An external coding agent does not require a special MCP-like engine protocol to be useful; ordinary Lisp APIs are already machine-operable. A remote protocol can be layered on later.

---

## 40. Platform Abstraction

The platform layer supplies:

- windows;
- surfaces;
- monitors;
- keyboard/mouse/gamepad;
- clipboard;
- file dialogs where permitted;
- high-resolution timers;
- threads/synchronization abstraction where needed;
- dynamic library loading;
- application lifecycle;
- mobile touch lifecycle.

Public API:

```lisp
(make-window ...)
(poll-events ...)
(window-size ...)
(set-cursor-mode ...)
```

Backends can use SDL, GLFW, native APIs, or direct bindings, but no backend should define the engine architecture.

---

## 41. Graphics Backend Strategy

### 41.1 Preferred hierarchy

1. Vulkan backend for Linux/Windows and other supported platforms.
2. Metal backend for Apple platforms.
3. OpenGL backend as compatibility/development fallback.
4. WebGPU backend if a practical Common Lisp deployment target emerges.

### 41.2 Backend interface

```lisp
(defgeneric create-device (backend options))
(defgeneric create-buffer (device descriptor))
(defgeneric create-texture (device descriptor))
(defgeneric create-pipeline (device descriptor))
(defgeneric submit (device command-list))
(defgeneric present (swapchain))
```

High-level renderer code depends on this protocol, not Vulkan symbols.

---

## 42. Pure Common Lisp Definition

For this project, **pure Common Lisp** means:

- all engine algorithms are implemented in Common Lisp;
- all scene/geometry/game/editor logic is implemented in Common Lisp;
- all shader/compiler front-end logic is implemented in Common Lisp;
- asset processing is implemented in Common Lisp where practical;
- the engine does not wrap or embed a C/C++ game engine;
- foreign calls are limited to OS, graphics, audio, codecs, and optional specialized system libraries;
- such foreign dependencies are backend services, not the semantic owner of the world.

It does **not** mean pretending that Vulkan drivers, operating systems, or GPU firmware are written in Lisp.

A stricter configuration may avoid optional non-system foreign libraries entirely.

---

## 43. Deployment

### 43.1 Development image

The development environment favors maximum introspection:

```text
compiler
REPL
source locations
inspector
editor
debugger
profilers
hot reload
```

### 43.2 Release image

A release build may tree-shake or omit:

- editor panels;
- full compiler where implementation permits;
- source maps;
- debug UI;
- asset importers;
- development-only restarts.

It retains the same runtime object model.

### 43.3 Build description

```lisp
(define-application my-game
  :entry-point 'my-game:main
  :systems '(:my-game :sgeo.render :sgeo.audio)
  :assets '("assets/")
  :target :desktop
  :debug nil)
```

Then:

```lisp
(build-application 'my-game)
```

---

## 44. Mobile Considerations

Mobile should be possible but not allowed to distort desktop development architecture.

Required abstractions:

- touch input;
- lifecycle suspend/resume;
- orientation;
- safe areas;
- mobile GPU memory limits;
- Metal/Vulkan surface setup;
- packaged assets;
- no assumption of writable installation directories.

The editor itself need not run fully on mobile in v1, although runtime inspection over a remote connection is desirable.

---

## 45. Networking and Remote Inspection

Not part of the geometry core, but remote inspection is valuable.

A running game can expose a restricted development endpoint:

```text
Desktop Lisp IDE
       │
   secure link
       │
Running game/device
       │
 live object inspector
```

Operations:

- enumerate objects;
- inspect properties;
- request profiler data;
- issue approved commands;
- upload new shaders/assets;
- optionally evaluate code in development builds.

Never enable arbitrary evaluation in production builds by default.

---

## 46. Extensibility

Users must be able to define new types without registering them in a global C++ factory.

Example:

```lisp
(defclass portal (scene-object)
  ((destination :initarg :destination :accessor destination)))

(defmethod gather-renderables ((portal portal) collector view)
  ...)

(defmethod interact ((actor player) (portal portal))
  ...)
```

The class immediately participates through generic protocols.

---

## 47. Package and ASDF Structure

Suggested repository layout:

```text
s-geometry/
├── sgeo.asd
├── src/
│   ├── core/
│   ├── math/
│   ├── geometry/
│   ├── scene/
│   ├── spatial/
│   ├── gpu/
│   ├── shader/
│   ├── render/
│   ├── animation/
│   ├── physics/
│   ├── runtime/
│   ├── ui/
│   ├── editor/
│   ├── assets/
│   └── platform/
├── backends/
│   ├── vulkan/
│   ├── metal/
│   └── opengl/
├── examples/
│   ├── triangle/
│   ├── model-viewer/
│   ├── geometry-editor/
│   ├── boids/
│   ├── procedural-city/
│   └── mini-game/
├── tests/
├── benchmarks/
├── docs/
└── tools/
```

Separate ASDF systems prevent users from loading the editor when they only need the geometry library.

---

## 48. Public API Style

Prefer readable functions over giant option structures.

Good:

```lisp
(make-sphere :radius 3.0 :segments 32)
(add-child ship turret)
(translate ship '(0 0 10))
(ray-cast world ray)
```

Avoid forcing users into internal backend vocabulary:

```lisp
;; undesirable high-level API
(create-vk-indexed-drawable-with-descriptor-set-layout ...)
```

Backend APIs may of course expose such concepts under backend-specific packages.

---

## 49. Naming Conventions

Suggested public package nickname:

```lisp
:sg
```

Examples:

```lisp
(sg:make-box ...)
(sg:add-child ...)
(sg:open-editor ...)
```

Backend details:

```lisp
sg.vulkan:*
sg.metal:*
sg.opengl:*
```

Shader language:

```lisp
sg.shader:defshader
sg.shader:defcompute
```

Keep internal packages unexported.

---

## 50. Error Philosophy

The system should favor **recoverability**.

Examples:

### Missing texture

```text
ASSET-NOT-FOUND: textures/wall.ktx2

Restarts:
  Use checkerboard placeholder
  Browse for replacement
  Retry
  Abort asset load
```

### Invalid mesh

```text
NON-MANIFOLD-EDGE
Edge 489 has 3 incident faces.

Restarts:
  Split edge into manifold components
  Mark mesh as non-manifold
  Undo operation
  Enter debugger
```

### GPU out of memory

```text
GPU-ALLOCATION-FAILED

Restarts:
  Evict transient caches
  Reduce texture residency
  Retry
  Switch asset to CPU-only
```

This is a major opportunity to bring Lisp's condition system into graphics programming rather than hiding it.

---

## 51. Save Images vs Project Files

The environment should support both philosophies.

### Lisp image

Useful for:

- immediate continuation;
- research;
- experimentation;
- keeping live objects and tools.

### Project source

Required for:

- reproducible builds;
- source control;
- teams;
- deployment;
- long-term maintenance.

Therefore:

> Image persistence is a productivity feature, not the sole persistence format.

---

## 52. Example: Modeling and Simulating Boids

A historically appropriate validation demo is a modern Boids implementation.

```lisp
(defclass boid (scene-object)
  ((velocity :initform (random-unit-vector) :accessor velocity)
   (max-speed :initform 8.0 :accessor max-speed)))

(defmethod update ((b boid) world dt)
  (let ((neighbors (nearby-boids world b 10.0)))
    (adjust-velocity b
      (separation b neighbors)
      (alignment b neighbors)
      (cohesion b neighbors))
    (integrate-boid b dt)))
```

At runtime:

```lisp
(setf (max-speed (first (objects-of-type *world* 'boid))) 30.0)
```

Or redefine flocking behavior and resume without reconstructing the flock.

The demo should support:

- CPU boids using Lisp objects;
- packed data-oriented boids;
- GPU-compute boids using SGL;

thus demonstrating the whole scalability story.

---

## 53. Example: Interactive Modeling

```lisp
(defparameter *mesh* (make-box :size '(2 2 2)))
(open-mesh-editor *mesh*)
```

User selects the top face and extrudes it.

The UI issues:

```lisp
(with-edit-transaction (*mesh* "Extrude top")
  (extrude-region *mesh* selected-faces :distance 1.5))
```

The mesh revision increments.

The render cache sees that the topology changed, triangulates changed regions, updates the GPU buffer, and the viewport reflects the modification.

No export/import cycle occurs.

---

## 54. Example: Game Development

```lisp
(defclass door (scene-object)
  ((open-p :initform nil :accessor open-p)
   (locked-p :initform nil :accessor locked-p)))

(defmethod interact ((player player) (door door))
  (cond
    ((locked-p door)
     (show-message player "Locked."))
    (t
     (setf (open-p door) (not (open-p door)))
     (play-door-animation door))))
```

While the game is running, inspect a door:

```text
#<DOOR "Laboratory Entrance">

OPEN-P      NIL
LOCKED-P    T
PARENT       #<ROOM "LAB">
TRANSFORM    ...
MESH         #<EDITABLE-MESH ...>
```

Set `LOCKED-P` to `NIL`, resume, test immediately.

This is the desired development experience.

---

## 55. Testing Strategy

### 55.1 Unit tests

- vector/matrix correctness;
- topology operations;
- serialization roundtrips;
- shader type checking;
- spatial queries;
- animation interpolation.

### 55.2 Property tests

Examples:

- splitting then collapsing an edge preserves topology under defined conditions;
- transform inverse roundtrips points;
- serialization/deserialization preserves scene equivalence;
- BVH queries equal brute-force results.

### 55.3 Golden image tests

Render deterministic scenes and compare perceptual hashes within tolerance.

### 55.4 Backend conformance

Every rendering backend must pass a shared capability suite.

---

## 56. Performance Strategy

Do not prematurely rewrite everything around a hypothetical performance problem.

Profile first.

When optimization is needed, use this progression:

```text
clear Lisp implementation
        ↓
type declarations
        ↓
specialized arrays
        ↓
compiler macros / inlining
        ↓
data-oriented representation
        ↓
multithreading
        ↓
GPU compute
```

Keep the high-level object model even when internal representations become optimized.

### 56.1 Hot/cold split

Example:

```text
ENEMY Lisp object
  cold/semantic state:
    name
    behavior
    target
    inventory

  hot numeric store:
    positions[N]
    velocities[N]
    transforms[N]
```

This permits object-oriented authoring with data-oriented execution.

---

## 57. Metaobject Protocol Opportunities

Where available, MOP integration can power:

- editor metadata;
- automatic serialization;
- slot change observation;
- property animation;
- schema generation;
- hot class migration;
- documentation.

However, do not make a non-standard MOP implementation mandatory for the geometry core. Put advanced reflection behind `sgeo.mop`.

---

## 58. Security

Live code evaluation is powerful and dangerous.

Development build:

- unrestricted local REPL by user choice;
- remote evaluation disabled by default.

Release build:

- compiler/evaluator may be absent;
- remote inspector read-only by default;
- command whitelist;
- asset signature verification optional;
- no arbitrary network Lisp reader input.

Never `read` untrusted network text with reader evaluation enabled.

---

## 59. Documentation Strategy

Documentation should be generated from Lisp definitions where possible.

Every exported symbol requires:

- docstring;
- type expectations;
- examples;
- error conditions;
- thread restrictions;
- allocation notes where important.

Provide three documentation layers:

1. **Tutorials** — build things;
2. **Manual** — concepts and architecture;
3. **API reference** — every exported symbol.

---

## 60. Milestone Plan

### Milestone 0 — Foundation

Deliver:

- ASDF project structure;
- math package;
- IDs and base objects;
- condition hierarchy;
- test framework;
- platform window;
- minimal OpenGL or Vulkan triangle.

Exit criterion:

> Lisp can create a window and render a triangle through the engine abstraction.

### Milestone 1 — Live Scene

Deliver:

- transforms;
- scene objects;
- hierarchy;
- camera;
- mesh renderable;
- simple material;
- REPL manipulation;
- object picking.

Exit criterion:

> A running scene can be edited from the REPL without restarting.

### Milestone 2 — Geometry Kernel

Deliver:

- half-edge mesh;
- primitive creation;
- topology queries;
- extrusion;
- split/collapse;
- normals;
- triangulation;
- render-mesh conversion.

Exit criterion:

> A box can be interactively edited at vertex/edge/face level and re-rendered live.

### Milestone 3 — Editor

Deliver:

- viewport;
- hierarchy;
- inspector;
- transform gizmos;
- mesh selection;
- command system;
- undo/redo;
- integrated REPL panel.

Exit criterion:

> Most basic scene editing can be performed either by GUI or equivalent Lisp calls.

### Milestone 4 — Shader Lisp and Modern Renderer

Deliver:

- typed shader AST;
- SGIR;
- SPIR-V backend;
- material system;
- PBR;
- shadows;
- render graph;
- shader hot reload.

Exit criterion:

> PBR model viewer uses shaders authored in Lisp.

### Milestone 5 — Animation

Deliver:

- property animation;
- timeline;
- skeletons;
- skinning;
- blending;
- glTF animation import.

Exit criterion:

> Imported animated character plays and can be modified live.

### Milestone 6 — Simulation/Game Layer

Deliver:

- world loop;
- input maps;
- collision primitives;
- basic physics;
- events;
- debug draw;
- audio abstraction.

Exit criterion:

> A small interactive 3D game can be built entirely in Common Lisp.

### Milestone 7 — Deployment

Deliver:

- release build system;
- asset compiler;
- packed caches;
- Windows/Linux/macOS packaging;
- profiling and diagnostics.

Exit criterion:

> Example game runs standalone without the development editor.

### Milestone 8 — Advanced Geometry

Deliver:

- subdivision;
- robust booleans;
- SDFs;
- curve/surface tools;
- procedural node view;
- GPU geometry processing.

---

## 61. Recommended First Prototype

Do **not** begin by building the full editor.

Build this vertical slice:

```text
1. Common Lisp window
2. GPU backend
3. vec/matrix math
4. scene object + transform
5. editable half-edge cube
6. conversion to GPU mesh
7. perspective camera
8. mouse picking
9. face selection
10. extrude selected face
11. object inspector
12. redefine an operation while running
```

If this feels good, the architecture is working.

The most important prototype demo is:

> Create a cube, open a viewport, select a face, extrude it, inspect the mesh object from the REPL, redefine the extrusion behavior, and apply the new behavior to the **same live mesh** without restarting the world.

That test captures the project's identity better than rendering one million polygons.

---

## 62. Suggested Initial Class Diagram

```text
SGEO-OBJECT
│
├── ASSET
│   ├── TEXTURE
│   ├── MATERIAL
│   ├── GEOMETRY
│   │   ├── EDITABLE-MESH
│   │   ├── CURVE
│   │   ├── SURFACE
│   │   └── PROCEDURAL-GEOMETRY
│   └── ANIMATION-CLIP
│
└── SCENE-OBJECT
    ├── MESH-OBJECT
    ├── CAMERA
    ├── LIGHT
    ├── AUDIO-SOURCE
    ├── SKELETON-OBJECT
    └── USER CLASSES...
```

Separate runtime services:

```text
WORLD
├── SCENE
├── SPATIAL-INDEX
├── EVENT-BUS
├── ANIMATION-SYSTEM
├── PHYSICS-WORLD
├── AUDIO-WORLD
└── RENDER-WORLD
```

---

## 63. Suggested Geometry Data Structures

### Vertex

```lisp
(defstruct vertex
  id
  position
  half-edge)
```

### Half-edge

```lisp
(defstruct half-edge
  id
  vertex
  face
  next
  previous
  twin)
```

### Face

```lisp
(defstruct face
  id
  half-edge
  material-index)
```

The production implementation should store topology in packed vectors and use stable integer IDs rather than chains of conses for every element. The structures above illustrate semantics, not necessarily final memory layout.

A practical implementation may use:

```text
vertices[]
half-edges[]
faces[]
free-vertex-ids
free-edge-ids
free-face-ids
```

with generation counters to detect stale element references.

---

## 64. Stable Handles

Interactive editors require stable references even when packed arrays move.

Use handles:

```text
(index, generation)
```

Example:

```lisp
#S(VERTEX-HANDLE :INDEX 481 :GENERATION 7)
```

If slot 481 is deleted and reused, generation becomes 8. Old handle generation 7 is detected as stale instead of silently referring to a different vertex.

---

## 65. Change Notifications

Do not make every property assignment globally magical.

Provide explicit mutation protocols for engine-relevant state:

```lisp
(set-position object new-position)
(set-mesh-position mesh vertex value)
(set-material-parameter material :roughness 0.2)
```

Convenient `setf` expanders can call these functions.

Changes emit typed invalidation events:

```text
:transform-changed
:topology-changed
:vertex-data-changed
:material-changed
:shader-changed
:asset-reloaded
```

This avoids rebuilding everything on every modification.

---

## 66. Dependency and Invalidation System

A small generic dependency system should underpin procedural geometry, assets, and render caches.

```lisp
(depend render-mesh editable-mesh)
(depend pipeline shader-program)
(depend scene-bounds child-transform)
```

When source revisions change, consumers become stale.

Evaluation is lazy when appropriate:

```text
edit geometry
  → mark triangulation stale
  → mark render mesh stale
  → no work yet
render asks for mesh
  → rebuild once
```

---

## 67. Compiler Integration

S-Geometry/CL should exploit the native Lisp compiler.

### 67.1 Compile generated code

Procedural systems may generate specialized functions:

```lisp
(compile nil generated-form)
```

### 67.2 Compiler macros

Math and shader-adjacent APIs may use compiler macros for constant folding and unboxed paths.

### 67.3 Type policy

Debug builds favor safety:

```lisp
(declaim (optimize (safety 3) (debug 3) (speed 1)))
```

Hot production modules can locally choose:

```lisp
(declaim (optimize (speed 3) (safety 1) (debug 1)))
```

Never make globally unsafe optimization a requirement.

---

## 68. Implementation Compatibility

Primary development implementation: **SBCL**.

Reasons:

- strong native-code compiler;
- mature tooling;
- good performance;
- widely used Common Lisp implementation;
- good FFI ecosystem.

Portability layer should avoid unnecessary SBCL lock-in.

Secondary targets can include implementations with suitable deployment/platform support.

Implementation-specific optimization belongs in packages such as:

```text
sgeo.impl.sbcl
sgeo.impl.ecl
sgeo.impl.clasp
```

rather than contaminating public APIs.

---

## 69. Dependency Policy

Minimize dependencies in the core.

Possible categories:

### Acceptable core dependencies

- portability utilities;
- threads abstraction;
- CFFI or equivalent FFI;
- trivial-garbage for controlled finalization support;
- static vectors or equivalent where justified.

### Prefer internal implementation

- vector/matrix math;
- scene graph;
- geometry topology;
- render graph;
- shader compiler front-end;
- inspector/editor framework;
- asset graph.

### Optional adapters

- image codecs;
- audio codecs;
- Bullet/Jolt physics;
- Assimp;
- external mesh tools.

The project should never become unusable because a giant C++ dependency disappeared.

---

## 70. Relationship to Existing Common Lisp Graphics Work

The project should learn from, but not mechanically copy, existing Common Lisp graphics/game systems.

Examples worth studying include:

- **CEPL**, which deliberately emphasizes a REPL-friendly graphics workflow and treats the graphics window as a persistent part of a Lisp session;
- **Trial**, a modular Common Lisp game engine with live-development heritage and commercial game use;
- **Colony**, a Common Lisp game engine using modern OpenGL;
- current Common Lisp GLFW/Vulkan bindings and related FFI work.

The new system differs in emphasis:

> Its center is an editable, topology-aware, live Lisp geometry/world model from which rendering, simulation, and game development grow.

It should interoperate where sensible rather than assuming the rest of the Lisp ecosystem has nothing to teach it.

---

## 71. Architectural Invariants

These rules should be written into the contributor guide.

1. **No foreign engine owns the scene.**
2. **GPU resources are caches/projections, never authoritative objects.**
3. **Every GUI action has a programmatic Lisp operation underneath it.**
4. **Core geometry is usable without opening a window.**
5. **The editor works on the same live objects as the runtime.**
6. **Errors should preserve the running world whenever reasonably possible.**
7. **Source assets remain reproducible outside a saved Lisp image.**
8. **Optimization may change representation, not semantic ownership.**
9. **Subsystems communicate through explicit protocols rather than package-internal reach-through.**
10. **Game code must be allowed to define ordinary CLOS classes that participate naturally in the world.**
11. **A backend can be replaced without rewriting geometry or gameplay code.**
12. **Shader/GPU code should be authorable from Lisp.**
13. **Headless use must remain possible.**
14. **Development and shipped runtime use the same conceptual object model.**

---

## 72. What Success Looks Like

A successful modern S-Geometry environment should let a developer do this:

```lisp
;; Create a world.
(defparameter *world* (sg:make-world))

;; Create live geometry.
(defparameter *ship-geometry*
  (sg:make-procedural-geometry 'my-ship-generator
                               :length 14.0
                               :width 5.0))

;; Create a game object that uses it.
(defparameter *ship*
  (make-instance 'player-ship
                 :name "Kestrel"
                 :geometry *ship-geometry*))

(sg:add-to-world *world* *ship*)

;; Start editor/runtime.
(sg:open-editor *world*)
(sg:run *world*)
```

Then, without restarting:

```lisp
;; Inspect the same object visible in the viewport.
(inspect *ship*)

;; Modify its geometry generator.
(setf (sg:parameter *ship-geometry* :width) 6.25)

;; Redefine gameplay behavior.
(defmethod update ((ship player-ship) world dt)
  (new-flight-model ship world dt))

;; Compile a new GPU shader.
(sg.shader:compile-shader 'ship-material)

;; Continue playing the same world.
```

If the architecture makes this ordinary rather than miraculous, the project has achieved its main goal.

---

## 73. Final Design Principle

The final principle can be stated simply:

> **Do not embed Lisp into a 3D engine. Make the 3D engine be Lisp.**

A conventional engine often looks like:

```text
C++ engine
   ↓
object database
   ↓
editor
   ↓
scripting language
```

This project should look like:

```text
                    COMMON LISP
                         │
        ┌────────────────┼────────────────┐
        │                │                │
    Geometry          Runtime           Tools
        │                │                │
        └────────────────┼────────────────┘
                         │
                    Live World
                         │
                    GPU / OS
```

The editor is Lisp.

The geometry is Lisp.

The game objects are Lisp.

The procedural systems are Lisp.

The shader language is Lisp.

The debugger understands the same objects the player is looking at.

That is the design property worth carrying forward from the Symbolics era.

---

## 74. References and Historical/Technical Starting Points

These are starting points for implementation research, not normative dependencies.

1. Craig W. Reynolds, **Boids / Flocks, Herds, and Schools** — notes that the original implementation was written in Symbolics Common Lisp and based on S-Geometry and S-Dynamics.  
   https://www.red3d.com/cwr/boids/

2. Craig W. Reynolds, **Flocks, Herds, and Schools: A Distributed Behavioral Model**, SIGGRAPH 1987 — describes the Symbolics Common Lisp / Flavors / S-Geometry / S-Dynamics environment.  
   https://www.red3d.com/cwr/papers/1987/boids.html

3. Symbolics documentation archive — useful for studying Genera concepts, programming environment, UI conventions, CLOS transition, and Lisp Machine development practices.  
   https://www.chai.uni-hamburg.de/~moeller/symbolics-info/documentation/

4. CEPL — REPL-friendly Common Lisp graphics library and useful precedent for keeping graphics live during a Lisp session.  
   https://github.com/cbaggers/cepl

5. Trial — modular Common Lisp game engine; useful for studying contemporary Lisp game-engine architecture and deployed Common Lisp games.  
   https://codeberg.org/Shirakumo/trial

6. Colony — Common Lisp game engine built around modern OpenGL.  
   https://github.com/colonyengine/colony

7. cl-vulkan — Common Lisp Vulkan bindings, useful for backend research rather than as a mandated dependency.  
   https://github.com/awolven/cl-vulkan

---

## 75. Recommended Immediate Next Document

After approving this architecture, the next specification should be:

**`sgeo-geometry-kernel-spec.md`**

It should define in implementation-level detail:

- exact half-edge storage layout;
- stable handle representation;
- mutation invariants;
- topology validation;
- attribute domains;
- triangulation strategy;
- mesh revision tracking;
- CPU/GPU synchronization;
- memory layout;
- typed Common Lisp APIs;
- conditions and restarts;
- benchmarks;
- property-based tests.

That kernel should be built before the large editor, because every higher-level part of the system depends on it.

