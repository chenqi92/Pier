import AppKit
import Metal
import MetalKit
import CoreText

/// Metal-accelerated terminal renderer.
///
/// Uses Core Text to rasterize glyphs into a texture atlas, then renders the
/// terminal grid on the GPU using a simple instanced-quad shader.
/// Falls back to the existing Core-Graphics rendering when Metal is unavailable.
class MetalTerminalRenderer {

    // MARK: - Glyph Atlas

    struct GlyphInfo {
        let textureX: Float      // u0 in atlas
        let textureY: Float      // v0 in atlas
        let textureW: Float      // width in atlas (normalised)
        let textureH: Float      // height in atlas (normalised)
    }

    /// Per-cell instance data sent to the vertex shader.
    struct CellInstance {
        var posX: Float
        var posY: Float
        var texX: Float
        var texY: Float
        var texW: Float
        var texH: Float
        var fgR: Float
        var fgG: Float
        var fgB: Float
        var fgA: Float
        var bgR: Float
        var bgG: Float
        var bgB: Float
        var bgA: Float
    }

    // MARK: - Properties

    private(set) var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var atlasTexture: MTLTexture?
    private var glyphCache: [Character: GlyphInfo] = [:]

    /// Font used for glyph atlas generation.
    var font: CTFont
    /// Cell dimensions (points).
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    /// Atlas texture size.
    private let atlasSize: Int = 2048

    /// Whether Metal-based rendering is available.
    var isAvailable: Bool { device != nil && pipelineState != nil }

    // MARK: - Init

    init(fontSize: CGFloat = 13, fontFamily: String = "SF Mono") {
        self.font = CTFontCreateWithName(fontFamily as CFString, fontSize, nil)

        // Calculate cell dimensions
        let advances = UnsafeMutablePointer<CGSize>.allocate(capacity: 1)
        defer { advances.deallocate() }
        var glyphs = [CGGlyph](repeating: 0, count: 1)
        var chars: [UniChar] = [UniChar(0x4D)] // 'M'
        CTFontGetGlyphsForCharacters(font, &chars, &glyphs, 1)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, advances, 1)
        self.cellWidth = ceil(advances.pointee.width)
        self.cellHeight = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))

        setupMetal()
    }

    // MARK: - Metal Setup

    private func setupMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("[MetalTerminalRenderer] Metal not available, using fallback")
            return
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()

        // Build shader library
        let shaderSource = MetalTerminalRenderer.shaderSource
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let vertexFn = library.makeFunction(name: "vertexShader")
            let fragmentFn = library.makeFunction(name: "fragmentShader")

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFn
            descriptor.fragmentFunction = fragmentFn
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha

            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("[MetalTerminalRenderer] Shader compilation failed: \(error)")
            self.device = nil
        }

        buildGlyphAtlas()
    }

    // MARK: - Glyph Atlas

    /// Rasterise printable ASCII + common glyphs into a texture atlas.
    private func buildGlyphAtlas() {
        guard let device else { return }

        let textureDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: atlasSize,
            height: atlasSize,
            mipmapped: false
        )
        textureDesc.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: textureDesc) else { return }
        atlasTexture = texture

        // Bitmap context for Core Text rendering
        let bytesPerRow = atlasSize
        var bitmapData = [UInt8](repeating: 0, count: atlasSize * atlasSize)

        guard let cgContext = CGContext(
            data: &bitmapData,
            width: atlasSize,
            height: atlasSize,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return }

        cgContext.setAllowsAntialiasing(true)
        cgContext.setShouldAntialias(true)

        // Pack glyphs into atlas in a grid
        let glyphW = Int(ceil(cellWidth)) + 2
        let glyphH = Int(ceil(cellHeight)) + 2
        let cols = atlasSize / glyphW
        var slot = 0

        // ASCII 32-126 + some common extras
        let chars: [Character] = (32...126).map { Character(UnicodeScalar($0)) }

        for char in chars {
            let col = slot % cols
            let row = slot / cols
            let x = col * glyphW
            let y = row * glyphH

            // Render glyph with Core Text
            let str = String(char) as CFString
            let attrStr = CFAttributedStringCreateMutable(nil, 0)!
            CFAttributedStringReplaceString(attrStr, CFRangeMake(0, 0), str)
            CFAttributedStringSetAttribute(attrStr, CFRangeMake(0, 1), kCTFontAttributeName, font)

            let line = CTLineCreateWithAttributedString(attrStr)
            let descent = CTFontGetDescent(font)

            cgContext.saveGState()
            cgContext.textPosition = CGPoint(x: CGFloat(x) + 1, y: CGFloat(atlasSize - y - glyphH) + descent + 1)
            CTLineDraw(line, cgContext)
            cgContext.restoreGState()

            // Store glyph info (normalised UV)
            let info = GlyphInfo(
                textureX: Float(x) / Float(atlasSize),
                textureY: Float(y) / Float(atlasSize),
                textureW: Float(glyphW) / Float(atlasSize),
                textureH: Float(glyphH) / Float(atlasSize)
            )
            glyphCache[char] = info
            slot += 1
        }

        // Upload to Metal texture
        texture.replace(
            region: MTLRegionMake2D(0, 0, atlasSize, atlasSize),
            mipmapLevel: 0,
            withBytes: bitmapData,
            bytesPerRow: bytesPerRow
        )
    }

    // MARK: - Draw

    /// Render the terminal grid into the given Metal drawable.
    func render(
        cells: [[Character]],
        viewportWidth: Float,
        viewportHeight: Float,
        renderPassDescriptor: MTLRenderPassDescriptor,
        drawable: CAMetalDrawable
    ) {
        guard let device, let commandQueue, let pipelineState, let atlasTexture else { return }

        // Build instance buffer
        var instances: [CellInstance] = []
        for (row, line) in cells.enumerated() {
            for (col, char) in line.enumerated() {
                guard let glyph = glyphCache[char] ?? glyphCache[" "] else { continue }

                let posX = Float(col) * Float(cellWidth) / viewportWidth * 2.0 - 1.0
                let posY = 1.0 - Float(row + 1) * Float(cellHeight) / viewportHeight * 2.0

                instances.append(CellInstance(
                    posX: posX,
                    posY: posY,
                    texX: glyph.textureX,
                    texY: glyph.textureY,
                    texW: glyph.textureW,
                    texH: glyph.textureH,
                    fgR: 0.9, fgG: 0.9, fgB: 0.9, fgA: 1.0,
                    bgR: 0.1, bgG: 0.1, bgB: 0.12, bgA: 1.0
                ))
            }
        }

        guard !instances.isEmpty else { return }

        let instanceBuffer = device.makeBuffer(
            bytes: instances,
            length: instances.count * MemoryLayout<CellInstance>.stride,
            options: .storageModeShared
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(instanceBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(atlasTexture, index: 0)

        // Draw 6 vertices (2 triangles) per cell instance
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: instances.count)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Metal Shaders

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct CellInstance {
        float posX;
        float posY;
        float texX;
        float texY;
        float texW;
        float texH;
        float fgR;
        float fgG;
        float fgB;
        float fgA;
        float bgR;
        float bgG;
        float bgB;
        float bgA;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
        float4 fgColor;
        float4 bgColor;
    };

    vertex VertexOut vertexShader(
        uint vertexID [[vertex_id]],
        uint instanceID [[instance_id]],
        constant CellInstance *instances [[buffer(0)]]
    ) {
        CellInstance cell = instances[instanceID];

        // Quad vertices (two triangles)
        float2 positions[6] = {
            float2(0, 0), float2(1, 0), float2(0, 1),
            float2(1, 0), float2(1, 1), float2(0, 1)
        };
        float2 texCoords[6] = {
            float2(0, 0), float2(1, 0), float2(0, 1),
            float2(1, 0), float2(1, 1), float2(0, 1)
        };

        float2 pos = positions[vertexID];

        VertexOut out;
        out.position = float4(
            cell.posX + pos.x * cell.texW * 4.0,
            cell.posY + pos.y * cell.texH * 4.0,
            0.0, 1.0
        );
        out.texCoord = float2(
            cell.texX + texCoords[vertexID].x * cell.texW,
            cell.texY + texCoords[vertexID].y * cell.texH
        );
        out.fgColor = float4(cell.fgR, cell.fgG, cell.fgB, cell.fgA);
        out.bgColor = float4(cell.bgR, cell.bgG, cell.bgB, cell.bgA);

        return out;
    }

    fragment float4 fragmentShader(
        VertexOut in [[stage_in]],
        texture2d<float> atlas [[texture(0)]]
    ) {
        constexpr sampler s(mag_filter::linear, min_filter::linear);
        float alpha = atlas.sample(s, in.texCoord).r;

        // Mix foreground and background based on glyph alpha
        return mix(in.bgColor, in.fgColor, alpha);
    }
    """
}
