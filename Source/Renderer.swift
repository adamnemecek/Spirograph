import MetalKit
import simd

var translation = float3(0,0,170)

let alignedUniformsSize = (MemoryLayout<Uniforms>.size & ~0xFF) + 0x100
let maxBuffersInFlight = 3

enum RendererError: Error { case badVertexDescriptor }

class Renderer: NSObject, MTKViewDelegate {
    var ident:Int = 0
    let commandQueue: MTLCommandQueue
    var dynamicUniformBuffer: MTLBuffer
    var pipelineState: MTLRenderPipelineState
    var depthState: MTLDepthStencilState

    let inFlightSemaphore = DispatchSemaphore(value: maxBuffersInFlight)
    var uniformBufferOffset = 0
    var uniformBufferIndex = 0
    var uniforms: UnsafeMutablePointer<Uniforms>
    var projectionMatrix: matrix_float4x4 = matrix_float4x4()

    final class VertexDescriptor : MTLVertexDescriptor {
        override init() {
            super.init()
            attributes[0].format = .float3   // pos
            attributes[0].offset = 0
            attributes[0].bufferIndex = 0

            attributes[1].format = .float2   // txt
            attributes[1].offset = 0
            attributes[1].bufferIndex = 1

            layouts[0].stride = 12
            layouts[0].stepRate = 1
            layouts[0].stepFunction = .perVertex

            layouts[1].stride = 8
            layouts[1].stepRate = 1
            layouts[1].stepFunction = .perVertex
        }
    }

    final class DepthStencilDescriptor : MTLDepthStencilDescriptor {
        override init() {
            super.init()
            depthCompareFunction = .less
            isDepthWriteEnabled = true
        }
    }

    init?(metalKitView: MTKView, _ mIdent:Int) {
        ident = mIdent
        guard let queue = gDevice.makeCommandQueue() else { return nil }
        self.commandQueue = queue

        let uniformBufferSize = alignedUniformsSize * maxBuffersInFlight

        guard let buffer = gDevice.makeBuffer(length:uniformBufferSize, options: .storageModeShared) else { return nil }
        dynamicUniformBuffer = buffer

        self.dynamicUniformBuffer.label = "UniformBuffer"

        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents()).bindMemory(to:Uniforms.self, capacity:1)

        metalKitView.depthStencilPixelFormat = .depth32Float_stencil8
        metalKitView.colorPixelFormat = .bgra8Unorm_srgb
        metalKitView.sampleCount = 1

        let mtlVertexDescriptor = VertexDescriptor()

        do {
            pipelineState = try Renderer.buildRenderPipelineWithDevice(device: gDevice,
                                                                       metalKitView: metalKitView,
                                                                       mtlVertexDescriptor: mtlVertexDescriptor)
        } catch {
            print("Unable to compile render pipeline state.  Error info: \(error)")
            return nil
        }

        let depthStateDesciptor = DepthStencilDescriptor()

        guard let state = gDevice.makeDepthStencilState(descriptor:depthStateDesciptor) else { return nil }
        depthState = state

        super.init()
    }

    class func buildRenderPipelineWithDevice(device: MTLDevice,
                                             metalKitView: MTKView,
                                             mtlVertexDescriptor: MTLVertexDescriptor) throws -> MTLRenderPipelineState {
        let library = device.makeDefaultLibrary()

        let vertexFunction = library?.makeFunction(name: "texturedVertexShader")
        let fragmentFunction = library?.makeFunction(name: "texturedFragmentShader")

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "RenderPipeline"
        pipelineDescriptor.sampleCount = metalKitView.sampleCount
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor

        pipelineDescriptor.colorAttachments[0].pixelFormat = metalKitView.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = metalKitView.depthStencilPixelFormat
        pipelineDescriptor.stencilAttachmentPixelFormat = metalKitView.depthStencilPixelFormat

        return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
    }

    //MARK:-

    func draw(in view: MTKView) {
        _ = inFlightSemaphore.wait(timeout: .distantFuture)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in semaphore.signal() }

        let toeIn:Float = 0.01
        let stereoAngle:Float = ident == 0 ? -toeIn : +toeIn

        guard let r = view.currentRenderPassDescriptor else { return }
        r.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0, 1.0)

        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: r) else { return }
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(depthState)

        uniformBufferIndex = (uniformBufferIndex + 1) % maxBuffersInFlight
        uniformBufferOffset = alignedUniformsSize * uniformBufferIndex
        uniforms = UnsafeMutableRawPointer(dynamicUniformBuffer.contents() + uniformBufferOffset).bindMemory(to:Uniforms.self, capacity:1)
        uniforms[0].mvp =
            projectionMatrix
            * translate(translation.x,translation.y,-translation.z)
            * rotate(stereoAngle,float3(0,1,0))
            * arcBall.transformMatrix

        renderEncoder.setVertexBuffer(dynamicUniformBuffer, offset:0, index:1)

        //-----------------------------------
        spirograph.render(renderEncoder)
        //-----------------------------------

        renderEncoder.endEncoding()
        if let drawable = view.currentDrawable { commandBuffer.present(drawable) }
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let aspect = Float(size.width) / Float(size.height)
        projectionMatrix = matrix_perspective_right_hand(fovyRadians: radians_from_degrees(65), aspectRatio:aspect, nearZ: 0.01, farZ: 5000.0)
    }
}

//MARK:-

func matrix_perspective_right_hand(fovyRadians fovy: Float, aspectRatio: Float, nearZ: Float, farZ: Float) -> matrix_float4x4 {
    let ys = 1 / tanf(fovy * 0.5)
    let xs = ys / aspectRatio
    let zs = farZ / (nearZ - farZ)
    return matrix_float4x4(columns:(vector_float4(xs,  0, 0,   0),
                                    vector_float4( 0, ys, 0,   0),
                                    vector_float4( 0,  0, zs, -1),
                                    vector_float4( 0,  0, zs * nearZ, 0)))
}

func radians_from_degrees(_ degrees: Float) -> Float {
    return (degrees / 180) * .pi
}

func translate(_ t: float3) -> float4x4 {
    var M = matrix_identity_float4x4

    M.columns.3.x = t.x
    M.columns.3.y = t.y
    M.columns.3.z = t.z

    return M //    float4x4(M)
}

func translate(_ x: Float, _ y: Float, _ z: Float) -> float4x4 {
    return translate(float3(x: x, y: y, z: z))
}

func rotate(_ a: Float, _ r: float3) -> float4x4 {
    var c: Float = 0.0
    var s: Float = 0.0

    // Computes the sine and cosine of pi times angle (measured in radians)
    // faster and gives exact results for angle = 90, 180, 270, etc.
    __sincospif(a, &s, &c)

    let k = 1.0 - c

    let u = normalize(r)
    let v = s * u
    let w = k * u

    let P = float4(
        x: w.x * u.x + c,
        y: w.x * u.y + v.z,
        z: w.x * u.z - v.y,
        w: 0.0
    )

    let Q = float4(
        x: w.x * u.y - v.z,
        y: w.y * u.y + c,
        z: w.y * u.z + v.x,
        w: 0.0
    )

    let R = float4(
        x: w.x * u.z + v.y,
        y: w.y * u.z - v.x,
        z: w.z * u.z + c,
        w: 0.0
    )

    let S = float4(
        x: 0.0,
        y: 0.0,
        z: 0.0,
        w: 1.0
    )

    return float4x4([P, Q, R, S])
}

func rotate(_ angle: Float, _ x: Float, _ y: Float, _ z: Float) -> float4x4 {
    return rotate(angle, float3(x: x, y: y, z: z))
}
