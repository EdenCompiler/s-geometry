# Historical S-Geometry reference

The project owner supplied this summary of the original S-Geometry system; it is recorded here as project context, not as an independently verified historical source.

The original system was described as an integrated, window-based polygon database and 3D editor for polygon and polyhedron operations. It supported orthographic and perspective display, displaying back faces, selecting screen features and modifying the database, and geometric/topological operations on vertices, edges, and faces. Its camera model included smooth eyepoint control and physical-camera concepts such as focal length, film format, angle, and view. The summary also mentions hidden-line drawings, color, hardcopy, S-Render interchange, and mouse/tablet interaction.

The current M3 editor is a modern, partial implementation of that interaction model: it provides a native window, polygon-mesh editing, orthographic and perspective views, scene selection, camera orbit/pan/zoom, an integrated Lisp listener, and vertex/edge/face operations. It does not currently implement hidden-line drawing, a physical film-and-lens camera, tablet input, hardcopy output, or S-Render interchange. This reference motivates the editor's direction; it does not expand M3's acceptance criteria to reproduce the original system.
