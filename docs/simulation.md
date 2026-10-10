# Simulation, physics, input, and audio

Simulation services are optional extensions of a scene. A plain `sgeo.scene:world` remains usable without a simulation state; attaching services does not move scene ownership into a separate engine. Input, physics, audio, scheduled work, events, and spatial queries can be added independently, and the scene objects remain the source of transform data.

The systems are available headlessly:

```lisp
(asdf:load-system :sgeo/simulation)
(let* ((world (sgeo.scene:make-world))
       (physics (sgeo.physics:make-physics-world))
       (simulation (sgeo.simulation:attach-simulation world :physics physics)))
  (sgeo.scene:update-world world (/ 1d0 60d0))
  (sgeo.simulation:detach-simulation world))
```

The `sgeo` package re-exports the core math, scene, input, physics, audio, debug-drawing, and simulation APIs; `sg` is its short nickname. Load `sgeo/simulation` for the headless services. The OpenGL runtime is a separate dependency and is only needed to run the graphical demonstrations.

## World update and fixed steps

Attach at most one simulation state to a world. The default fixed interval is 1/60 second and the default maximum catch-up is eight fixed steps per rendered update. The accumulator retains unprocessed time when that limit is reached. A paused state does not accrue or process fixed-step time; variable-frame hooks, scene animation evaluation with zero elapsed time, audio rendering, and post-update hooks still run.

`update-world` runs the scene's simulation phases in this order:

1. `:input` applies queued physical input and publishes action edges.
2. `:pre-update` runs once per rendered update.
3. For each fixed step: scheduled tasks, `:fixed-update`, object `fixed-update-object` methods, physics, `:post-physics`, and event dispatch.
4. `:variable-update`, scene object updates, `:animation`, animation evaluation, and `:transforms`.
5. Spatial-index refresh, `:spatial`, offline audio rendering, `:audio`, and `:post-update`.

Simulation services are owned by the update thread. When changing their collections or state from another thread, hold `sgeo.scene:with-world-lock` for the associated world. Register callbacks with `(add-phase-hook state :fixed-update function)`. A hook receives `(world state dt)` and the function returned by `add-phase-hook` can be passed to `remove-phase-hook`. `fixed-update-object` is a generic method for logic owned by a scene-object class. The fixed interval is deterministic for a given sequence of inputs, but this small solver does not promise cross-platform bitwise determinism.

The scheduler uses simulation time and invokes functions with `(world state)`. A one-shot task is removed before its callback runs. Repeating tasks advance their due time before callback invocation, so an error does not cause the same deadline to loop endlessly.

```lisp
(sgeo.simulation:schedule-task simulation 2d0
  (lambda (world state)
    (declare (ignore state))
    (format t "Two simulation seconds elapsed in ~S~%" world)))

(let ((task (sgeo.simulation:schedule-task simulation 1d0 #'my-callback :interval 0.5d0)))
  (sgeo.simulation:cancel-task task))
```

## Input maps and frame-stable actions

An input map describes semantic actions in terms of key, mouse, gamepad-button, gamepad-axis, and scroll bindings. The native runtime queues platform events; headless code can queue the same event data directly. Pressed/released edges remain stable during the rendered frame even if it contains several fixed substeps.

```lisp
(sgeo.input:define-input-map editor-controls
  (:move-left (:key :a) (:gamepad-axis :left-x :negative))
  (:jump (:key :space) (:gamepad-button :a)))

(let ((input (sgeo.input:make-input-state :map 'editor-controls)))
  (sgeo.input:queue-input-event input :key :code :space :action :press)
  ;; O quadro aplica este evento antes de os hooks consultarem a ação.
  (sgeo.input:begin-input-frame input)
  (sgeo.input:action-pressed-p input :jump) ; => true for this frame
  (sgeo.input:end-input-frame input))
```

Use `action-value` for a normalized action value, `action-down-p` for a held action, and `action-pressed-p` / `action-released-p` for transitions. `bind-action` and `unbind-action` edit the active input context. Contexts can be pushed and popped to change which mappings are active. Focus loss clears held controls. The graphical runtime polls gamepads when available; keyboard/mouse event injection also works without a device. Trigger axes range from 0 to 1 and also expose digital trigger buttons above 50% pressure.

The game example binds WASD/arrows and the gamepad left stick to movement, Space/A to jump, E/mouse-left/X to interact, P to pause, R to restart, and F1 to toggle collision visualization.

## Rigid bodies and collision queries

Physics lives in an independent `sgeo.physics:physics-world`; `attach-simulation` optionally connects it to a scene's clock. A `rigid-body` refers to an existing scene object and one local-space shape. It does not create or own the object's visual geometry. Position reads use the complete world transform, and integration writes back through the parent transform.

```lisp
(let* ((world (sgeo.scene:make-world))
       (object (sgeo.scene:make-scene-object :position #(0d0 2d0 0d0)))
       (physics (sgeo.physics:make-physics-world))
       (body (sgeo.physics:make-rigid-body
              :object object
              :shape (sgeo.physics:make-sphere-shape :radius 0.4d0)
              :motion-type :dynamic :mass 1d0 :friction 0.7d0
              :restitution 0.1d0)))
  (sgeo.scene:add-to-world world object)
  (sgeo.physics:add-body physics body)
  (sgeo.physics:apply-force body #(0d0 4d0 0d0))
  (sgeo.physics:step-physics physics (/ 1d0 60d0)))
```

Supported shapes are spheres (`make-sphere-shape :radius`), oriented boxes (`make-box-shape :half-extents`), and Y-axis capsules (`make-capsule-shape :radius :half-height`). The narrow phase provides sphere/sphere, sphere/box, box/box, capsule/sphere, capsule/box, and capsule/capsule contacts. Boxes use the separating-axis test; capsule/box uses a bounded numerical minimization of its segment-to-box distance. `overlap-bodies` returns a contact or NIL without inserting it into a world. Contact normals point from body A toward body B.

Bodies can be `:static`, `:dynamic`, or `:kinematic`. Dynamic bodies integrate gravity and accumulated force, and receive impulses through `apply-impulse`. Set `body-velocity` for a direct linear velocity change. `move-body` places a kinematic body in world space; call `sync-body-from-object` after application code changes an object's hierarchy or transform and needs an explicit synchronization boundary. `body-inverse-mass` is zero for static and kinematic bodies. There is no rotational solver or angular collision response; `body-angular-velocity` currently returns a zero vector.

The contact solver applies linear normal impulses with restitution, a Coulomb-style tangential friction impulse, and positional correction. Trigger bodies (`:trigger-p t`, also accepted as `:sensor-p t`) produce contacts and contact events without physical response. A physics contact handler receives `(physics-world event contact)`, where event is `:begin`, `:stay`, or `:end`. Read `contact-body-a`, `contact-body-b`, `contact-normal`, `contact-depth`, `contact-point`, and `contact-event` from the contact. `simulation` wraps this callback and enqueues matching events on its event bus.

```lisp
(sgeo.simulation:on-event (sgeo.simulation:simulation-events simulation) :begin
  (lambda (event)
    (let ((contact (sgeo.simulation:event-payload event)))
      (format t "Contact: ~S with ~S~%"
              (sgeo.physics:contact-body-a contact)
              (sgeo.physics:contact-body-b contact)))))
```

Subscriptions can target a specific event type or `:all`, have integer priorities, and run once when requested with `:once-p t`. `emit-event` queues work; `dispatch-events` processes a snapshot so events emitted by handlers wait for a later dispatch. Handler errors are captured in `event-bus-errors` by default, and can be cleared with `clear-event-errors`.

`physics-ray-cast` returns the first body, distance, hit point, and normal (or NIL values); `max-distance` limits the ray. `query-aabb` returns bodies whose world-space collider bounds overlap the query. This physics broad phase is a sorted-X sweep and still updates by testing collider bounds. The scene simulation's independent `uniform-grid` indexes scene-object bounds and exposes `spatial-query-aabb` and `spatial-ray-query`. Use the grid for scene queries and the physics query for colliders.

Physics transforms must have orthogonal world-space basis vectors. Shear is rejected. Boxes support non-uniform scale and parent rotation; spheres and capsules require uniform world scale. Capsule local axes are Y-aligned before object rotation. The solver is a compact linear rigid-body system for game-sized scenes, not a replacement for a full-featured physics engine.

## Events, debug drawing, and spatial indexing

`attach-simulation` creates a default `uniform-grid` unless an index is supplied. The grid uses configurable cell size, supports insertion/removal/update, and diverts bounds covering too many cells to an overflow list. At each update, the scene bridge refreshes enabled objects' world-space AABBs from mesh render positions or the transformed origin for non-mesh nodes. Queries return objects in insertion order after exact AABB filtering. Ray queries return `(object . distance)` pairs in distance order.

Debug drawing records commands in the world rather than creating permanent scene objects. `debug-line`, `debug-ray`, `debug-aabb`, `debug-sphere`, and `debug-text` enqueue transient primitives; the renderer batches by color and expands the bitmap text font into triangles. A zero duration keeps a command through the next update boundary, positive durations count down at update boundaries, and `:duration -1d0` keeps it until cleared. `clear-debug-draw` removes pending commands. `debug-text` uses the `:height` keyword in world units.

```lisp
(sgeo.debug:debug-aabb world (sgeo.physics:body-bounds body)
                       :color #(0.2d0 1d0 0.3d0) :duration 0.1d0)
(sgeo.debug:debug-text world #(0d0 2d0 0d0) "Grounded"
                        :height 0.4d0 :duration 0.1d0)
```

## Audio

The audio system builds PCM buffers, scene-attached sources and listeners, buses, and an offline stereo mixer in Lisp. It does not open an audio device. Calling `mixer-render` returns interleaved stereo samples; the simulation's `:audio` stage renders the number of frames implied by elapsed time and sample rate, retaining fractional frames between updates. An audio hook can submit those samples to an optional output backend.

```lisp
(let* ((mixer (sgeo.audio:make-audio-mixer :sample-rate 44100))
       (buffer (sgeo.audio:make-tone-buffer 660d0 0.15d0))
       (source (sgeo.audio:make-audio-source :buffer buffer :gain 0.2d0)))
  (sgeo.audio:add-audio-source mixer source)
  (sgeo.audio:play-source source)
  (sgeo.audio:write-wav "tone.wav" (sgeo.audio:mixer-render mixer 8192))
  (sgeo.audio:close-audio-mixer mixer))
```

The mixer supports mono/stereo buffers, gain, pitch, looping for in-memory buffers, simple left/right positional panning with distance attenuation, buses and user-defined DSP effects. Stream sources consume queued buffers or a refill function in forward order; they cannot loop or seek backward. Native playback is an optional OpenAL backend, selected by the launcher rather than by headless simulation code.

## Examples

```bash
sbcl --script tools/boids.lisp --hidden --frames 120 --no-repl
sbcl --script tools/boids.lisp --packed --count 256 --hidden --frames 120 --no-repl
sbcl --script tools/game.lisp
sbcl --script tools/game.lisp --audio
```

`--capture path.ppm` writes a frame capture. `--audio` is specific to the game and requests the optional OpenAL output; the default game mixer remains offline. The Boids demo computes separation, alignment, cohesion, and a boundary force from a stable position/velocity snapshot. `:objects` reads positions from scene objects; `:packed` keeps numeric state in flat vectors while retaining the same scene visuals. Both modes are CPU Lisp implementations with a quadratic neighbor scan; packed storage is not a GPU compute path.

`make-game-world` returns the world and a `game-state` value. `*game*` holds the latest state for REPL inspection. `game-score`, `game-status`, `game-speed`, and `game-door-locked-p` are live accessors; the speed and lock flag support SETF. `restart-game` restores the player, collectibles, door, input, and simulation state. The player collects three trigger coins; two unlock the door, interacting near it plays an animation and removes its collider, and the player wins by crossing the exit threshold after collecting all three. The `run-game` wrapper resolves the graphical runtime when called; load `sgeo/runtime` first when using it from an existing Lisp session.

## Headless checks and current limits

Run the complete CPU suite without opening a window or audio device:

```bash
sbcl --dynamic-space-size 4096 --script tools/test.lisp
```

The headless suite has passed **2,346 checks with no skips or failures**. It includes typed input edges, fixed-step debt and pausing, scheduler/event behavior, spatial-grid overflow and ray ordering, collision shape pairs and transforms, contact response and events, offline audio, debug-draw batching/lifetimes, both Boids modes, and gameplay collection, jumping, door, win, restart, and live tuning.

Native checks also pass: **579 OpenGL checks** across a 172-frame game demonstration and 12 frames per Boids mode; **8-frame simulation and 4-frame game Vulkan checks** with no validation messages; and **10 OpenAL checks** using the null driver. Run `tools/m6-acceptance.lisp`, `tools/m6-vulkan-check.lisp`, and `tools/audio-check.lisp` to repeat them. The Vulkan check requires the [renderer dependencies](m4-implementation.md) and Khronos validation layer. OpenAL null-driver verification does not establish physical speaker playback. See the [M6 implementation notes](m6-implementation.md) for the tested scenarios.

Limitations to keep in view: physics is linear-only; body collision is an all-pairs step rather than a persistent spatial broad phase; audio streams are forward-only; scene simulation spatial-index ray queries use object AABBs; and both Boids implementations run on the CPU. GPU compute simulation, angular constraints, and production-scale broad-phase structures remain future work.
