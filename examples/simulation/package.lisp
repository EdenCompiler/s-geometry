(defpackage #:sgeo.examples.simulation
  (:use #:cl)
  (:export #:boid #:boid-velocity #:boid-max-speed #:flock #:flock-boids #:flock-mode
           #:flock-separation #:flock-alignment #:flock-cohesion #:flock-neighbor-radius
           #:make-boids-world #:update-flock #:run-boids #:*flock*
           #:game-state #:make-game-world #:run-game #:restart-game #:*game*
           #:game-player #:game-player-body #:game-score #:game-status
           #:game-speed #:game-door-locked-p #:game-door-open-p #:game-door
           #:game-input #:game-physics #:game-simulation #:game-debug-p))
