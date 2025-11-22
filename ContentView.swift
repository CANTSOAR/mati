import SwiftUI
import RealityKit
import ARKit
import Vision

// MARK: - Main View
struct ContentView: View {
    var body: some View {
        ZStack {
            ARViewContainer()
                .edgesIgnoringSafeArea(.all)
            
            VStack {
                Spacer()
                Text("1. Tap wall/table to place board\n2. Point Index Finger to Draw\n3. Use Thumb to Erase")
                    .font(.subheadline)
                    .padding()
                    .background(Color.black.opacity(0.6))
                    .foregroundColor(.white)
                    .cornerRadius(10)
                    .padding(.bottom, 30)
            }
        }
    }
}

// MARK: - ARView Container
struct ARViewContainer: UIViewRepresentable {
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        // Configure AR Session for LiDAR and Plane Detection
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        
        // Enable Scene Reconstruction (LiDAR) if available
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        
        arView.session.run(config)
        
        // Set delegate for per-frame updates
        arView.session.delegate = context.coordinator
        context.coordinator.arView = arView
        
        // Add Tap Gesture for Board Placement
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        arView.addGestureRecognizer(tapGesture)
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
}

// MARK: - Coordinator (The Brain)
class Coordinator: NSObject, ARSessionDelegate {
    weak var arView: ARView?
    
    // The virtual drawing board
    var boardEntity: ModelEntity?
    var boardAnchor: AnchorEntity?
    
    // Hand Pose Request
    let handPoseRequest = VNDetectHumanHandPoseRequest()
    
    // Drawing State
    var inkEntities: [ModelEntity] = []
    
    // Performance throttling
    var lastDrawTime: TimeInterval = 0
    
    // MARK: - AR Session Loop
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Run Vision request on the captured image
        let pixelBuffer = frame.capturedImage
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        
        do {
            // Perform hand detection
            try handler.perform([handPoseRequest])
            
            // If we have a board, try to interact with it
            if let _ = boardEntity, let observation = handPoseRequest.results?.first {
                processHand(observation: observation)
            }
        } catch {
            print("Vision error: \(error)")
        }
    }
    
    // MARK: - Hand Logic
    func processHand(observation: VNHumanHandPoseObservation) {
        guard let arView = arView, let board = boardEntity else { return }
        
        // 1. Get Index Finger Tip (For Drawing)
        if let indexTip = try? observation.recognizedPoint(.indexTip), indexTip.confidence > 0.3 {
            // Convert normalized Vision point (0-1) to Screen point
            let screenPoint = visionPointToScreen(point: indexTip, view: arView)
            
            // Raycast to find where this hits the Board
            if let hitPosition = raycastToBoard(screenPoint: screenPoint) {
                drawInk(at: hitPosition)
            }
        }
        
        // 2. Get Thumb Tip (For Erasing)
        if let thumbTip = try? observation.recognizedPoint(.thumbTip), thumbTip.confidence > 0.3 {
            let screenPoint = visionPointToScreen(point: thumbTip, view: arView)
            
            if let hitPosition = raycastToBoard(screenPoint: screenPoint) {
                eraseInk(at: hitPosition)
            }
        }
    }
    
    // MARK: - Drawing Logic
    func drawInk(at position: SIMD3<Float>) {
        let currentTime = Date().timeIntervalSince1970
        // Throttle drawing to prevent millions of entities (draw every 0.015s)
        guard currentTime - lastDrawTime > 0.015 else { return }
        
        // Create a small red sphere (The "Ink")
        let mesh = MeshResource.generateSphere(radius: 0.005) // 5mm radius
        let material = SimpleMaterial(color: .red, isMetallic: false)
        let inkDot = ModelEntity(mesh: mesh, materials: [material])
        
        inkDot.position = position
        
        // Add to the board anchor so it moves with the board
        boardAnchor?.addChild(inkDot)
        inkEntities.append(inkDot)
        
        lastDrawTime = currentTime
    }
    
    // MARK: - Eraser Logic
    func eraseInk(at position: SIMD3<Float>) {
        // Remove any ink dots within 3cm of the thumb
        let eraseRadius: Float = 0.03
        
        // Filter in place to find dots to remove
        // (Note: optimizing this with a spatial hash grid is better for large scale apps, but array filter is fine for < 5000 dots)
        inkEntities.removeAll { inkDot in
            if distance(inkDot.position, position) < eraseRadius {
                inkDot.removeFromParent() // Remove visually
                return true // Remove from array
            }
            return false
        }
    }
    
    // MARK: - Board Placement
    @objc func handleTap(_ sender: UITapGestureRecognizer) {
        guard let arView = arView else { return }
        let location = sender.location(in: arView)
        
        // 1. Raycast to find a wall or table
        let results = arView.raycast(from: location, allowing: .estimatedPlane, alignment: .any)
        
        if let firstResult = results.first {
            // If we already have a board, move it. If not, create it.
            if boardAnchor == nil {
                createBoard(at: firstResult.worldTransform)
            } else {
                boardAnchor?.move(to: firstResult.worldTransform, relativeTo: nil)
            }
        }
    }
    
    func createBoard(at transform: simd_float4x4) {
        // Create an Anchor at the tap location
        let anchor = AnchorEntity(world: transform)
        
        // Create the Board Mesh (0.5m x 0.3m translucent pane)
        let boardMesh = MeshResource.generatePlane(width: 0.5, depth: 0.3)
        var boardMaterial = SimpleMaterial(color: .blue.withAlphaComponent(0.2), isMetallic: false)
        boardMaterial.roughness = 0.5
        
        let board = ModelEntity(mesh: boardMesh, materials: [boardMaterial])
        
        // Add a white border (Wireframe box)
        let borderMesh = MeshResource.generateBox(size: [0.52, 0.01, 0.32]) // Slightly larger
        let borderMat = SimpleMaterial(color: .white, isMetallic: false)
        let border = ModelEntity(mesh: borderMesh, materials: [borderMat])
        
        board.addChild(border)
        
        // Collision component is needed for Raycasting logic if we used physics,
        // but here we use mathematical plane projection for speed.
        
        anchor.addChild(board)
        arView?.scene.addAnchor(anchor)
        
        self.boardEntity = board
        self.boardAnchor = anchor
    }
    
    // MARK: - Helper Functions
    
    // Convert normalized Vision Point (Bottom-Left 0,0) to Screen Point (Top-Left 0,0)
    func visionPointToScreen(point: VNRecognizedPoint, view: ARView) -> CGPoint {
        let width = view.bounds.width
        let height = view.bounds.height
        
        // Vision x is 0.0 (left) to 1.0 (right) -> Screen x
        // Vision y is 0.0 (bottom) to 1.0 (top) -> Screen y (flipped)
        return CGPoint(x: point.x * width, y: (1 - point.y) * height)
    }
    
    // Project a 2D screen point onto the 3D Board Plane
    func raycastToBoard(screenPoint: CGPoint) -> SIMD3<Float>? {
        guard let arView = arView, let board = boardEntity else { return nil }
        
        // 1. Create a Ray from the Camera through the Screen Point
        guard let ray = arView.ray(through: screenPoint) else { return nil }
        
        // 2. Define the Mathematical Plane of the Board
        // The board is a flat plane at its local (0,0,0) with Up normal (0,1,0) usually,
        // but since we used generatePlane(width, depth), the normal is Y-up.
        // We need the board's World Position and Up Vector.
        
        let boardTransform = board.transformMatrix(relativeTo: nil)
        let boardPosition = SIMD3<Float>(boardTransform.columns.3.x, boardTransform.columns.3.y, boardTransform.columns.3.z)
        
        // RealityKit Planes are typically X-Z plane (Normal is Y).
        // We need to rotate the normal by the board's orientation.
        let boardRotation = board.orientation(relativeTo: nil)
        let planeNormal = boardRotation.act(SIMD3<Float>(0, 1, 0)) // The "Up" of the board
        
        // 3. Intersect Ray with Plane
        // Math: t = (center - origin) . normal / (direction . normal)
        let t = dot(boardPosition - ray.origin, planeNormal) / dot(ray.direction, planeNormal)
        
        // If t < 0, the plane is behind the camera
        if t < 0 { return nil }
        
        let intersectionPoint = ray.origin + (ray.direction * t)
        
        // 4. Check if the point is within the Board's Width/Depth bounds
        // Convert intersection to Board's Local Space
        let localPoint = board.convert(position: intersectionPoint, from: nil)
        
        let width = Float(0.5)
        let depth = Float(0.3)
        
        if abs(localPoint.x) < width / 2 && abs(localPoint.z) < depth / 2 {
            // We are inside the board boundaries!
            // Return local point so drawing stays attached to board
            return localPoint
        }
        
        return nil
    }
}
