import SwiftUI
import RealityKit
import ARKit
import Vision

// MARK: - UI State Enum
enum InteractionMode {
    case none
    case drawing
    case erasing
    case hover
}

// MARK: - Main View
struct ContentView: View {
    @State private var handPoint: CGPoint? // Where your finger is on screen
    @State private var currentMode: InteractionMode = .none
    @State private var debugText: String = "Scan room & Show hand"
    
    var body: some View {
        ZStack {
            ARViewContainer(
                handPoint: $handPoint,
                currentMode: $currentMode,
                debugText: $debugText
            )
            .edgesIgnoringSafeArea(.all)
            
            // HUD Layers
            GeometryReader { geometry in
                ZStack {
                    // 1. Hand Tracker (Where Vision sees your finger)
                    if let point = handPoint {
                        Circle()
                            .stroke(Color.white.opacity(0.5), lineWidth: 2)
                            .frame(width: 20, height: 20)
                            .position(point)
                        
                        // Connection Line (Laser beam visual)
                        // Note: The actual 3D cursor is rendered in RealityKit
                    }
                    
                    // 2. Mode Indicator (Top Center)
                    VStack {
                        Text(modeLabel)
                            .font(.system(size: 24, weight: .black, design: .rounded))
                            .foregroundColor(modeColor)
                            .padding(.top, 60)
                            .shadow(color: .black, radius: 2)
                        
                        Spacer()
                        
                        // 3. Bottom Debug/Status Panel
                        VStack(alignment: .leading, spacing: 6) {
                            Text(debugText)
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.yellow)
                            
                            Divider().background(Color.white)
                            
                            Text("👆 INDEX OUT = DRAW")
                                .foregroundColor(currentMode == .drawing ? .green : .gray)
                            Text("👍 THUMB OUT = ERASE")
                                .foregroundColor(currentMode == .erasing ? .red : .gray)
                        }
                        .font(.caption)
                        .padding()
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(16)
                        .padding(.bottom, 40)
                        .padding(.horizontal, 20)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }
    
    var modeColor: Color {
        switch currentMode {
        case .drawing: return .green
        case .erasing: return .red
        case .hover: return .yellow
        case .none: return .gray
        }
    }
    
    var modeLabel: String {
        switch currentMode {
        case .drawing: return "DRAWING"
        case .erasing: return "ERASING"
        case .hover: return "AIMING"
        case .none: return ""
        }
    }
}

// MARK: - ARView Container
struct ARViewContainer: UIViewRepresentable {
    @Binding var handPoint: CGPoint?
    @Binding var currentMode: InteractionMode
    @Binding var debugText: String
    
    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        
        // Enable LiDAR Mesh visualization so you can see the surface
        arView.debugOptions = [.showSceneUnderstanding]
        
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        config.environmentTexturing = .automatic
        
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        
        arView.session.run(config)
        arView.session.delegate = context.coordinator
        context.coordinator.arView = arView
        
        return arView
    }
    
    func updateUIView(_ uiView: ARView, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
}

// MARK: - Coordinate Smoother (Reduces Jitter)
struct PointSmoother {
    var history: [CGPoint] = []
    let maxSize: Int = 6 // Average over last 6 frames
    
    mutating func add(point: CGPoint) -> CGPoint {
        history.append(point)
        if history.count > maxSize { history.removeFirst() }
        
        let sumX = history.reduce(0) { $0 + $1.x }
        let sumY = history.reduce(0) { $0 + $1.y }
        return CGPoint(x: sumX / CGFloat(history.count), y: sumY / CGFloat(history.count))
    }
    
    mutating func reset() {
        history.removeAll()
    }
}

// MARK: - Coordinator
class Coordinator: NSObject, ARSessionDelegate {
    var parent: ARViewContainer
    weak var arView: ARView?
    
    // 3D Objects
    var cursorEntity: ModelEntity? // The glowing ring on the wall
    var inkEntities: [ModelEntity] = []
    
    // Vision & Logic
    let handPoseRequest = VNDetectHumanHandPoseRequest()
    var isProcessingFrame = false
    let visionQueue = DispatchQueue(label: "com.arhand.visionQueue")
    var bufferSize: CGSize = .zero
    
    // Smoothing
    var smoother = PointSmoother()
    
    init(parent: ARViewContainer) {
        self.parent = parent
        // Revision 1 is the standard, reliable hand pose model
        handPoseRequest.revision = VNDetectHumanHandPoseRequestRevision1
        handPoseRequest.maximumHandCount = 1
        
        super.init()
        setupCursor()
    }
    
    func setupCursor() {
        // REPLACED: generateTorus -> generateSphere (flattened to look like a disc)
        // A sphere with a small radius acts as a clear "laser dot"
        let mesh = MeshResource.generateSphere(radius: 0.015)
        let material = UnlitMaterial(color: .yellow)
        let cursor = ModelEntity(mesh: mesh, materials: [material])
        
        // Flatten it slightly to look like a puck/cursor
        cursor.scale = [1.0, 0.2, 1.0]
        
        self.cursorEntity = cursor
    }
    
    // MARK: - AR Loop
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !isProcessingFrame else { return }
        isProcessingFrame = true
        
        let pixelBuffer = frame.capturedImage
        // Store buffer size to fix aspect ratio scaling
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        self.bufferSize = CGSize(width: height, height: width) // Swap for portrait
        
        visionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Orientation .right rotates the sensor image (landscape) to portrait
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
            
            do {
                try handler.perform([self.handPoseRequest])
                
                if let observation = self.handPoseRequest.results?.first {
                    DispatchQueue.main.async {
                        self.processHand(observation: observation)
                        self.isProcessingFrame = false
                    }
                } else {
                    DispatchQueue.main.async {
                        self.lostHand()
                        self.isProcessingFrame = false
                    }
                }
            } catch {
                self.isProcessingFrame = false
            }
        }
    }
    
    func lostHand() {
        parent.handPoint = nil
        parent.currentMode = .none
        parent.debugText = "No hand detected"
        smoother.reset()
        cursorEntity?.isEnabled = false // Hide cursor
    }
    
    // MARK: - Hand Processing
    func processHand(observation: VNHumanHandPoseObservation) {
        guard let arView = arView else { return }
        
        do {
            // 1. Get Key Points with HIGH confidence requirement
            // Using MCP (knuckles) vs TIP to detect extension accurately
            let indexTip = try observation.recognizedPoint(.indexTip)
            
            let thumbTip = try observation.recognizedPoint(.thumbTip)
            
            let wrist = try observation.recognizedPoint(.wrist)
            
            // Strict Confidence Check (0.5 = 50% sure)
            let confidenceThreshold: Float = 0.5
            guard indexTip.confidence > confidenceThreshold,
                  thumbTip.confidence > confidenceThreshold,
                  wrist.confidence > confidenceThreshold else {
                lostHand()
                return
            }
            
            // 2. Logic: Calculate Extensions (How far is the tip from the knuckle/wrist?)
            // We use the distance from Wrist to Tip as the primary "Extension" metric
            let indexDist = distance(p1: wrist, p2: indexTip)
            let thumbDist = distance(p1: wrist, p2: thumbTip)
            
            // 3. Determine Mode
            var newMode: InteractionMode = .hover
            var activePointRaw = indexTip // Default tracking point
            
            // Heuristic:
            // If Index is very extended AND Thumb is retracted (Index distance > 1.3x Thumb distance)
            if indexDist > thumbDist * 1.3 {
                newMode = .drawing
                activePointRaw = indexTip
            }
            // If Thumb is very extended AND Index is retracted (Thumb distance > 1.1x Index distance)
            // Thumb is naturally shorter, so multiplier is lower
            else if thumbDist > indexDist * 1.1 {
                newMode = .erasing
                activePointRaw = thumbTip
            }
            else {
                newMode = .hover
                activePointRaw = indexTip
            }
            
            // 4. Smooth the Screen Point
            let rawScreenPoint = visionPointToScreen(point: activePointRaw, view: arView)
            let smoothedPoint = smoother.add(point: rawScreenPoint)
            
            // 5. Update UI
            parent.handPoint = smoothedPoint
            parent.currentMode = newMode
            
            // 6. Perform Raycast & Action
            if let hitResult = performRaycast(screenPoint: smoothedPoint) {
                let position = hitResult.worldTransform
                update3DCursor(at: position, normal: hitResult.worldTransform, mode: newMode)
                
                if newMode == .drawing {
                    drawInk(at: position)
                    parent.debugText = "Drawing on Surface"
                } else if newMode == .erasing {
                    eraseInk(at: position)
                    parent.debugText = "Erasing Ink"
                } else {
                    parent.debugText = "Aiming..."
                }
            } else {
                cursorEntity?.isEnabled = false // Hide cursor if pointing at empty air
                parent.debugText = "Hand detected (Too far/No surface)"
            }
            
        } catch {
            lostHand()
        }
    }
    
    // MARK: - Raycasting & Cursor
    func performRaycast(screenPoint: CGPoint) -> ARRaycastResult? {
        guard let arView = arView else { return nil }
        
        // "estimatedPlane" allows drawing on irregular surfaces (like couches/messy tables)
        // "alignment: .any" allows walls, floors, and slanted surfaces
        let query = arView.makeRaycastQuery(from: screenPoint, allowing: .estimatedPlane, alignment: .any)
        
        if let query = query {
            let results = arView.session.raycast(query)
            return results.first
        }
        return nil
    }
    
    func update3DCursor(at transform: simd_float4x4, normal: simd_float4x4, mode: InteractionMode) {
        guard let arView = arView, let cursor = cursorEntity else { return }
        
        // Add cursor to scene if not there
        if cursor.parent == nil {
            let anchor = AnchorEntity(world: transform)
            anchor.addChild(cursor)
            arView.scene.addAnchor(anchor)
        }
        
        // Show and Position
        cursor.isEnabled = true
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        
        // Move cursor slightly off the wall (0.5cm) so it doesn't clip
        // (Simple approach: just move to world position. For advanced normal alignment, we'd need the normal vector)
        cursor.setPosition(position, relativeTo: nil)
        
        // Color Feedback
        var color: SimpleMaterial.Color = .yellow
        if mode == .drawing { color = .green }
        if mode == .erasing { color = .red }
        
        // Apply Glowing Material
        if var material = cursor.model?.materials.first as? UnlitMaterial {
            material.color = .init(tint: color.withAlphaComponent(0.8))
            cursor.model?.materials = [material]
        }
    }
    
    // MARK: - Ink Logic
    var lastDrawTime: TimeInterval = 0
    
    func drawInk(at transform: simd_float4x4) {
        let currentTime = Date().timeIntervalSince1970
        // Draw at 60fps cap (0.016s)
        guard currentTime - lastDrawTime > 0.016 else { return }
        
        let mesh = MeshResource.generateSphere(radius: 0.01) // 1cm thick line
        let material = UnlitMaterial(color: .green)
        let inkDot = ModelEntity(mesh: mesh, materials: [material])
        
        let position = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        inkDot.position = position
        
        // Attach to a world anchor so it stays fixed in space
        let anchor = AnchorEntity(world: position)
        anchor.addChild(inkDot)
        arView?.scene.addAnchor(anchor)
        
        inkEntities.append(inkDot)
        lastDrawTime = currentTime
    }
    
    func eraseInk(at transform: simd_float4x4) {
        let eraserPos = SIMD3<Float>(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z)
        let eraseRadius: Float = 0.15 // 15cm Eraser
        
        // Find dots near the eraser
        inkEntities.removeAll { inkDot in
            if distance3D(inkDot.position, eraserPos) < eraseRadius {
                if let anchor = inkDot.parent as? AnchorEntity {
                    arView?.scene.removeAnchor(anchor)
                }
                return true
            }
            return false
        }
    }
    
    // MARK: - Math
    func distance(p1: VNRecognizedPoint, p2: VNRecognizedPoint) -> CGFloat {
        // Raw distance in normalized coordinate space
        return hypot(p1.x - p2.x, p1.y - p2.y)
    }
    
    func distance3D(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        return simd_distance(a, b)
    }
    
    func visionPointToScreen(point: VNRecognizedPoint, view: ARView) -> CGPoint {
        let screenSize = view.bounds.size
        let bufferRatio = bufferSize.width / bufferSize.height
        let screenRatio = screenSize.width / screenSize.height
        var scale: CGFloat
        var offsetX: CGFloat = 0
        var offsetY: CGFloat = 0
        
        if screenRatio > bufferRatio {
            scale = screenSize.width / bufferSize.width
            let scaledHeight = bufferSize.height * scale
            offsetY = (screenSize.height - scaledHeight) / 2
        } else {
            scale = screenSize.height / bufferSize.height
            let scaledWidth = bufferSize.width * scale
            offsetX = (screenSize.width - scaledWidth) / 2
        }
        
        let x = (point.x * bufferSize.width * scale) + offsetX
        let y = ((1 - point.y) * bufferSize.height * scale) + offsetY
        return CGPoint(x: x, y: y)
    }
}
