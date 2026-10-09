#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CADisplayLink.h>
#import <QuartzCore/CAMetalLayer.h>

#include "body_kind.h"
#include "mesh.hpp"
#include "world_sim.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>

// Keep this in step with FrameUniforms in shaders/World.metal.
struct FrameUniforms {
    float viewProj[16];
    float model[16];
    float normalMat[16];
    float camera[4];
    float light[4];
    float params0[4];
    float params1[4];
};

static_assert(sizeof(FrameUniforms) == 256, "uniform block must match the Metal stride");

static const NSUInteger kMaxDraws = 32;
static const NSUInteger kUniformStride = 256;
static const int kInFlight = 3;

static const Vec3 kSunDirection = normalize(Vec3{0.62f, 0.48f, 0.62f});

@interface GpuMesh : NSObject
@property(nonatomic, strong) id<MTLBuffer> vertices;
@property(nonatomic, strong) id<MTLBuffer> indices;
@property(nonatomic) NSUInteger indexCount;
@end

@implementation GpuMesh
@end

@interface WorldRenderer : NSObject
@property(nonatomic, readonly) id<MTLDevice> device;
@property(nonatomic, readonly) BOOL ready;
- (WorldSim&)sim;
- (void)frame:(NSTimeInterval)dt layer:(CAMetalLayer*)layer;
@end

@implementation WorldRenderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeSky;
    id<MTLRenderPipelineState> _pipeOpaque;
    id<MTLRenderPipelineState> _pipeAtmosphere;
    id<MTLRenderPipelineState> _pipeGlow;
    id<MTLRenderPipelineState> _pipeRibbon;
    id<MTLDepthStencilState> _depthOff;
    id<MTLDepthStencilState> _depthWrite;
    id<MTLDepthStencilState> _depthRead;
    id<MTLTexture> _msaaColour;
    id<MTLTexture> _msaaDepth;
    NSUInteger _targetWidth;
    NSUInteger _targetHeight;
    NSUInteger _samples;
    id<MTLBuffer> _uniforms[kInFlight];
    dispatch_semaphore_t _gate;
    NSUInteger _slot;
    NSUInteger _draw;
    GpuMesh* _sphere;
    GpuMesh* _box;
    GpuMesh* _dish;
    GpuMesh* _moonOrbit;
    GpuMesh* _satOrbit;
    WorldSim _sim;
}

- (WorldSim&)sim {
    return _sim;
}

- (id<MTLDevice>)device {
    return _device;
}

- (BOOL)ready {
    return _pipeOpaque != nil;
}

- (GpuMesh*)upload:(const Mesh&)mesh {
    GpuMesh* gpu = [GpuMesh new];
    gpu.vertices = [_device newBufferWithBytes:mesh.vertices.data()
                                         length:mesh.vertices.size() * sizeof(Vertex)
                                        options:MTLResourceStorageModeShared];
    gpu.indices = [_device newBufferWithBytes:mesh.indices.data()
                                        length:mesh.indices.size() * sizeof(uint32_t)
                                       options:MTLResourceStorageModeShared];
    gpu.indexCount = mesh.indices.size();
    return gpu;
}

- (BOOL)buildPipelines:(id<MTLLibrary>)library {
    id<MTLFunction> vertex = [library newFunctionWithName:@"worldVertex"];
    id<MTLFunction> fragment = [library newFunctionWithName:@"worldFragment"];
    if (!vertex || !fragment) {
        return NO;
    }

    MTLVertexDescriptor* vertices = [MTLVertexDescriptor vertexDescriptor];
    vertices.attributes[0].format = MTLVertexFormatFloat3;
    vertices.attributes[0].offset = 0;
    vertices.attributes[0].bufferIndex = 0;
    vertices.attributes[1].format = MTLVertexFormatFloat3;
    vertices.attributes[1].offset = 12;
    vertices.attributes[1].bufferIndex = 0;
    vertices.attributes[2].format = MTLVertexFormatFloat2;
    vertices.attributes[2].offset = 24;
    vertices.attributes[2].bufferIndex = 0;
    vertices.layouts[0].stride = sizeof(Vertex);
    vertices.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    auto make = [&](BOOL additive) -> id<MTLRenderPipelineState> {
        MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = vertex;
        desc.fragmentFunction = fragment;
        desc.vertexDescriptor = vertices;
        desc.rasterSampleCount = _samples;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        if (additive) {
            desc.colorAttachments[0].blendingEnabled = YES;
            desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
            desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOne;
            desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        }
        NSError* error = nil;
        id<MTLRenderPipelineState> state = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!state) {
            fprintf(stderr, "pipeline: %s\n", error.localizedDescription.UTF8String);
        }
        return state;
    };

    // Cull mode is set on the encoder per draw. One opaque pipeline and one
    // additive pipeline cover the sky, the world, the air, and the lamp halo.
    _pipeOpaque = make(NO);
    _pipeSky = _pipeOpaque;
    _pipeAtmosphere = make(YES);
    _pipeGlow = _pipeAtmosphere;
    _pipeRibbon = _pipeAtmosphere;
    (void)make;

    auto depth = [&](MTLCompareFunction compare, BOOL write) {
        MTLDepthStencilDescriptor* desc = [MTLDepthStencilDescriptor new];
        desc.depthCompareFunction = compare;
        desc.depthWriteEnabled = write;
        return [_device newDepthStencilStateWithDescriptor:desc];
    };
    _depthOff = depth(MTLCompareFunctionAlways, NO);
    _depthWrite = depth(MTLCompareFunctionLess, YES);
    _depthRead = depth(MTLCompareFunctionLess, NO);
    return _pipeOpaque != nil && _pipeAtmosphere != nil;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        return self;
    }
    _samples = [_device supportsTextureSampleCount:4] ? 4 : 1;
    _queue = [_device newCommandQueue];
    _gate = dispatch_semaphore_create(kInFlight);
    for (int i = 0; i < kInFlight; ++i) {
        _uniforms[i] = [_device newBufferWithLength:kMaxDraws * kUniformStride
                                            options:MTLResourceStorageModeShared];
    }

    NSError* error = nil;
    NSString* path = [NSBundle.mainBundle pathForResource:@"World" ofType:@"metallib"];
    id<MTLLibrary> library = nil;
    if (path) {
        library = [_device newLibraryWithURL:[NSURL fileURLWithPath:path] error:&error];
    }
    if (!library) {
        fprintf(stderr, "World.metallib: %s\n", error.localizedDescription.UTF8String ?: "not in the bundle");
        return self;
    }
    if (![self buildPipelines:library]) {
        return self;
    }

    _sphere = [self upload:makeSphere(80, 120)];
    _box = [self upload:makeBox()];
    _dish = [self upload:makeDish(12, 28)];
    _moonOrbit = [self upload:makeOrbitRibbon(kMoonOrbitRadius, kMoonInclination, 0.028f, 160)];
    _satOrbit = [self upload:makeOrbitRibbon(kSatOrbitRadius, kSatInclination, 0.018f, 160)];
    return self;
}

- (void)ensureTargets:(NSUInteger)width height:(NSUInteger)height {
    if (width == _targetWidth && height == _targetHeight && _msaaColour) {
        return;
    }
    // State change: the window's pixel size changed, so the sample targets
    // that resolve into the drawable have to be rebuilt to match.
    _targetWidth = width;
    _targetHeight = height;

    MTLTextureDescriptor* colour = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                                                      width:width
                                                                                     height:height
                                                                                  mipmapped:NO];
    colour.textureType = _samples > 1 ? MTLTextureType2DMultisample : MTLTextureType2D;
    colour.sampleCount = _samples;
    colour.usage = MTLTextureUsageRenderTarget;
    colour.storageMode = MTLStorageModePrivate;
    _msaaColour = [_device newTextureWithDescriptor:colour];

    MTLTextureDescriptor* depth = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                     width:width
                                                                                    height:height
                                                                                 mipmapped:NO];
    depth.textureType = colour.textureType;
    depth.sampleCount = _samples;
    depth.usage = MTLTextureUsageRenderTarget;
    depth.storageMode = MTLStorageModePrivate;
    _msaaDepth = [_device newTextureWithDescriptor:depth];
}

- (void)drawMesh:(GpuMesh*)mesh
           model:(const Mat4&)model
            kind:(int)kind
            pipe:(id<MTLRenderPipelineState>)pipe
           depth:(id<MTLDepthStencilState>)depth
            cull:(MTLCullMode)cull
         encoder:(id<MTLRenderCommandEncoder>)encoder
            base:(const FrameUniforms&)base
            slot:(NSUInteger)slot {
    if (!mesh || _draw >= kMaxDraws) {
        return;
    }
    FrameUniforms uniforms = base;
    std::memcpy(uniforms.model, model.m, sizeof(uniforms.model));
    Mat4 normals = normalMatrixOf(model);
    std::memcpy(uniforms.normalMat, normals.m, sizeof(uniforms.normalMat));
    uniforms.params0[2] = static_cast<float>(kind);

    auto* bytes = static_cast<uint8_t*>(_uniforms[slot].contents);
    std::memcpy(bytes + _draw * kUniformStride, &uniforms, sizeof(uniforms));

    [encoder setRenderPipelineState:pipe];
    [encoder setDepthStencilState:depth];
    [encoder setCullMode:cull];
    [encoder setVertexBuffer:mesh.vertices offset:0 atIndex:0];
    [encoder setVertexBuffer:_uniforms[slot] offset:_draw * kUniformStride atIndex:1];
    [encoder setFragmentBuffer:_uniforms[slot] offset:_draw * kUniformStride atIndex:1];
    [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:mesh.indexCount
                         indexType:MTLIndexTypeUInt32
                       indexBuffer:mesh.indices
                 indexBufferOffset:0];
    ++_draw;
}

- (void)frame:(NSTimeInterval)dt layer:(CAMetalLayer*)layer {
    if (!_pipeOpaque || !layer || layer.drawableSize.width < 1 || layer.drawableSize.height < 1) {
        return;
    }
    _sim.update(static_cast<float>(dt));

    // Interesting: the semaphore is the CPU/GPU handshake. Three uniform buffers
    // are in rotation. We wait until the GPU has finished the one we are about
    // to overwrite, then write this frame's draws into it.
    dispatch_semaphore_wait(_gate, DISPATCH_TIME_FOREVER);
    NSUInteger slot = _slot;
    _slot = (_slot + 1) % kInFlight;
    _draw = 0;

    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) {
        dispatch_semaphore_signal(_gate);
        return;
    }
    NSUInteger width = drawable.texture.width;
    NSUInteger height = drawable.texture.height;
    [self ensureTargets:width height:height];

    Vec3 eye;
    Vec3 target;
    _sim.eyeTarget(eye, target);
    float aspect = static_cast<float>(width) / static_cast<float>(height);
    Mat4 viewProj = mul(perspectiveMetal(48.f * kPi / 180.f, aspect, 0.05f, 180.f), lookAt(eye, target, {0.f, 1.f, 0.f}));

    FrameUniforms base{};
    std::memcpy(base.viewProj, viewProj.m, sizeof(base.viewProj));
    base.camera[0] = eye.x;
    base.camera[1] = eye.y;
    base.camera[2] = eye.z;
    base.light[0] = kSunDirection.x;
    base.light[1] = kSunDirection.y;
    base.light[2] = kSunDirection.z;
    base.params0[0] = _sim.lampTime;
    base.params0[1] = _sim.style == SurfaceStyle::SmoothBrown ? 1.f : 0.f;
    base.params1[0] = static_cast<float>(width);
    base.params1[1] = static_cast<float>(height);
    base.params1[2] = _sim.travel;
    base.params1[3] = _sim.paused ? 1.f : 0.f;

    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    if (_samples > 1) {
        pass.colorAttachments[0].texture = _msaaColour;
        pass.colorAttachments[0].resolveTexture = drawable.texture;
        pass.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
    } else {
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    }
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.004, 0.005, 0.012, 1.0);
    pass.depthAttachment.texture = _msaaDepth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionDontCare;
    pass.depthAttachment.clearDepth = 1.0;

    id<MTLCommandBuffer> buffer = [_queue commandBuffer];
    dispatch_semaphore_t gate = _gate;
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> finished) {
        (void)finished;
        dispatch_semaphore_signal(gate);
    }];

    id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
    // Mesh winding is counter-clockwise from the outside. Metal's default front
    // face is clockwise, which would cull every sphere.
    [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
    ScenePoses poses = _sim.poses();

    // Draw order is the depth story:
    // sky first (no depth), then solid bodies write depth, then the air,
    // the orbit ribbons, and the lamp halo test against that depth.
    Mat4 sky = mul(translate(eye), scaleUniform(40.f));
    [self drawMesh:_sphere model:sky kind:BODY_SKY pipe:_pipeSky depth:_depthOff cull:MTLCullModeFront encoder:encoder base:base slot:slot];

    [self drawMesh:_sphere model:poses.planet kind:BODY_PLANET pipe:_pipeOpaque depth:_depthWrite cull:MTLCullModeBack encoder:encoder base:base slot:slot];
    [self drawMesh:_sphere model:poses.moon kind:BODY_MOON pipe:_pipeOpaque depth:_depthWrite cull:MTLCullModeBack encoder:encoder base:base slot:slot];

    Mat4 craft = poses.satellite;
    Mat4 bus = mul(craft, scale(0.20f, 0.13f, 0.32f));
    Mat4 panelRight = mul(craft, mul(translate({0.38f, 0.f, 0.f}), scale(0.50f, 0.012f, 0.22f)));
    Mat4 panelLeft = mul(craft, mul(translate({-0.38f, 0.f, 0.f}), scale(0.50f, 0.012f, 0.22f)));
    Mat4 dish = mul(craft, mul(translate({0.f, 0.f, 0.22f}), scaleUniform(0.18f)));
    Mat4 horn = mul(craft, mul(translate({0.f, 0.f, 0.30f}), scale(0.035f, 0.035f, 0.08f)));
    Mat4 mast = mul(craft, mul(translate({0.f, 0.16f, -0.05f}), scale(0.018f, 0.20f, 0.018f)));
    Mat4 lamp = mul(craft, mul(translate({0.f, 0.28f, -0.05f}), scaleUniform(0.04f)));
    Mat4 halo = mul(craft, mul(translate({0.f, 0.28f, -0.05f}), scaleUniform(0.11f)));

    [self drawMesh:_box model:bus kind:BODY_METAL pipe:_pipeOpaque depth:_depthWrite cull:MTLCullModeBack encoder:encoder base:base slot:slot];
    [self drawMesh:_box model:panelRight kind:BODY_PANEL pipe:_pipeOpaque depth:_depthWrite cull:MTLCullModeBack encoder:encoder base:base slot:slot];
    [self drawMesh:_box model:panelLeft kind:BODY_PANEL pipe:_pipeOpaque depth:_depthWrite cull:MTLCullModeBack encoder:encoder base:base slot:slot];
    [self drawMesh:_dish model:dish kind:BODY_DISH pipe:_pipeOpaque depth:_depthWrite cull:MTLCullModeBack encoder:encoder base:base slot:slot];
    [self drawMesh:_box model:horn kind:BODY_HORN pipe:_pipeOpaque depth:_depthWrite cull:MTLCullModeBack encoder:encoder base:base slot:slot];
    [self drawMesh:_box model:mast kind:BODY_METAL pipe:_pipeOpaque depth:_depthWrite cull:MTLCullModeBack encoder:encoder base:base slot:slot];
    [self drawMesh:_sphere model:lamp kind:BODY_BEACON pipe:_pipeOpaque depth:_depthWrite cull:MTLCullModeBack encoder:encoder base:base slot:slot];

    Mat4 air = scaleUniform(1.08f);
    [self drawMesh:_sphere model:air kind:BODY_ATMOSPHERE pipe:_pipeAtmosphere depth:_depthRead cull:MTLCullModeFront encoder:encoder base:base slot:slot];

    if (_sim.showOrbits) {
        Mat4 identity = mat4Identity();
        [self drawMesh:_moonOrbit model:identity kind:BODY_ORBIT_MOON pipe:_pipeRibbon depth:_depthRead cull:MTLCullModeNone encoder:encoder base:base slot:slot];
        [self drawMesh:_satOrbit model:identity kind:BODY_ORBIT_SAT pipe:_pipeRibbon depth:_depthRead cull:MTLCullModeNone encoder:encoder base:base slot:slot];
    }
    [self drawMesh:_sphere model:halo kind:BODY_BEACON_HALO pipe:_pipeGlow depth:_depthRead cull:MTLCullModeBack encoder:encoder base:base slot:slot];

    [encoder endEncoding];
    [buffer presentDrawable:drawable];
    [buffer commit];
}

@end

@interface WorldView : NSView
@property(nonatomic, strong) WorldRenderer* renderer;
@property(nonatomic, copy) void (^chromeChanged)(NSString* body, NSString* title, BOOL help);
@end

@implementation WorldView {
    CADisplayLink* _link;
    BOOL _left, _right, _up, _down;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) {
        return nil;
    }
    self.wantsLayer = YES;
    CAMetalLayer* metal = [CAMetalLayer layer];
    metal.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    metal.opaque = YES;
    metal.framebufferOnly = YES;
    self.layer = metal;
    _renderer = [WorldRenderer new];
    metal.device = _renderer.device;
    return self;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)isOpaque {
    return YES;
}

- (void)syncDrawableSize {
    CAMetalLayer* metal = (CAMetalLayer*)self.layer;
    CGFloat scale = self.window.backingScaleFactor;
    if (scale < 1.f) {
        scale = NSScreen.mainScreen.backingScaleFactor;
    }
    if (scale < 1.f) {
        scale = 2.f;
    }
    metal.contentsScale = scale;
    metal.drawableSize = CGSizeMake(MAX(self.bounds.size.width * scale, 1.0), MAX(self.bounds.size.height * scale, 1.0));
}

- (void)layout {
    [super layout];
    [self syncDrawableSize];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self syncDrawableSize];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [_link invalidate];
    _link = nil;
    if (self.window) {
        _link = [self displayLinkWithTarget:self selector:@selector(step:)];
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        [self.window makeFirstResponder:self];
    }
}

- (void)step:(CADisplayLink*)link {
    NSTimeInterval dt = link.targetTimestamp - link.timestamp;
    if (!(dt > 0.0) || dt > 0.1) {
        dt = link.duration > 0.0 ? link.duration : (1.0 / 60.0);
    }
    [_renderer frame:dt layer:(CAMetalLayer*)self.layer];
    [self publishChrome];
}

- (void)publishChrome {
    if (!self.chromeChanged) {
        return;
    }
    WorldSim& sim = _renderer.sim;
    NSString* surface = sim.style == SurfaceStyle::SmoothBrown ? @"Smooth brown world" : @"Rust-red world";
    NSString* motion = @"moon and satellite in motion";
    if (sim.paused) {
        motion = @"orbits paused";
    } else if (sim.intro) {
        motion = @"opening approach";
    }
    int percent = (int)lroundf(sim.travel * 100.f);
    NSString* status = [NSString stringWithFormat:@"%@    ·    banana %d%%    ·    %@", surface, percent, motion];
    NSString* body = status;
    if (sim.showHelp) {
        body = [status stringByAppendingString:@"\nLeft / Right or drag    orbit          Up / Down or scroll    travel the banana\nB surface     O orbit lines     Space pause     H hide keys     F full screen"];
    }
    NSString* title = [NSString stringWithFormat:@"PCFE 3D World — %@", surface];
    self.chromeChanged(body, title, sim.showHelp);
}

- (void)syncAxes {
    float orbit = (_right ? 1.f : 0.f) - (_left ? 1.f : 0.f);
    float zoom = (_up ? 1.f : 0.f) - (_down ? 1.f : 0.f);
    _renderer.sim.orbitAxis = orbit;
    _renderer.sim.zoomAxis = zoom;
}

- (void)setHeld:(unsigned short)code down:(BOOL)down {
    switch (code) {
        case 123: _left = down; break;
        case 124: _right = down; break;
        case 126: _up = down; break;
        case 125: _down = down; break;
        case 0: _left = down; break;    // A
        case 2: _right = down; break;   // D
        case 13: _up = down; break;     // W
        case 1: _down = down; break;    // S
        default: break;
    }
    [self syncAxes];
}

- (void)keyDown:(NSEvent*)event {
    if (event.isARepeat && (event.keyCode == 49 || event.charactersIgnoringModifiers.length == 1)) {
        unichar ch = [event.charactersIgnoringModifiers characterAtIndex:0];
        if (ch == ' ' || ch == 'b' || ch == 'B' || ch == 'o' || ch == 'O' || ch == 'h' || ch == 'H' || ch == 'f' || ch == 'F') {
            return;
        }
    }
    NSString* chars = event.charactersIgnoringModifiers.lowercaseString;
    if ([chars isEqualToString:@" "]) {
        _renderer.sim.togglePause = YES;
        return;
    }
    if ([chars isEqualToString:@"b"]) {
        _renderer.sim.toggleStyle = YES;
        return;
    }
    if ([chars isEqualToString:@"o"]) {
        _renderer.sim.toggleOrbits = YES;
        return;
    }
    if ([chars isEqualToString:@"h"]) {
        _renderer.sim.toggleHelp = YES;
        return;
    }
    if ([chars isEqualToString:@"f"]) {
        [self.window toggleFullScreen:nil];
        return;
    }
    if (event.keyCode == 53) {
        if ((self.window.styleMask & NSWindowStyleMaskFullScreen) != 0) {
            [self.window toggleFullScreen:nil];
        }
        return;
    }
    [self setHeld:event.keyCode down:YES];
}

- (void)keyUp:(NSEvent*)event {
    [self setHeld:event.keyCode down:NO];
}

- (void)flagsChanged:(NSEvent*)event {
    // State change: shift is a rate, not a new mode. The world clock is untouched.
    _renderer.sim.rateScale = (event.modifierFlags & NSEventModifierFlagShift) ? 2.4f : 1.f;
}

- (void)mouseDown:(NSEvent*)event {
    (void)event;
    [self.window makeFirstResponder:self];
}

- (void)mouseDragged:(NSEvent*)event {
    _renderer.sim.pointerOrbit(static_cast<float>(event.deltaX) * 0.007f, static_cast<float>(event.deltaY) * 0.005f);
}

- (void)scrollWheel:(NSEvent*)event {
    float dy = static_cast<float>(event.scrollingDeltaY);
    if (!event.hasPreciseScrollingDeltas) {
        dy *= 8.f;
    }
    _renderer.sim.pointerOrbit(0.f, dy * 0.0035f);
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:NSCursor.openHandCursor];
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate {
    NSWindow* _window;
    NSTextField* _hud;
    WorldView* _view;
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    (void)notification;
    NSRect frame = NSMakeRect(0, 0, 1120, 720);
    _window = [[NSWindow alloc] initWithContentRect:frame
                                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    _window.title = @"PCFE 3D World";
    _window.backgroundColor = [NSColor colorWithCalibratedRed:0.01 green:0.012 blue:0.02 alpha:1];
    _window.minSize = NSMakeSize(720, 480);
    [_window center];

    NSView* content = _window.contentView;
    _view = [[WorldView alloc] initWithFrame:content.bounds];
    _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:_view];

    _hud = [[NSTextField alloc] initWithFrame:NSMakeRect(24, 16, content.bounds.size.width - 48, 64)];
    _hud.editable = NO;
    _hud.selectable = NO;
    _hud.bezeled = NO;
    _hud.drawsBackground = YES;
    _hud.backgroundColor = [NSColor colorWithCalibratedRed:0.02 green:0.015 blue:0.012 alpha:0.62];
    _hud.textColor = [NSColor colorWithCalibratedRed:0.96 green:0.91 blue:0.82 alpha:1];
    _hud.font = [NSFont monospacedSystemFontOfSize:12.5 weight:NSFontWeightMedium];
    _hud.alignment = NSTextAlignmentCenter;
    _hud.lineBreakMode = NSLineBreakByWordWrapping;
    _hud.maximumNumberOfLines = 3;
    _hud.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    _hud.stringValue = @"PCFE 3D World";
    [content addSubview:_hud];

    __weak NSTextField* hud = _hud;
    __weak NSWindow* window = _window;
    _view.chromeChanged = ^(NSString* body, NSString* title, BOOL help) {
        if (hud && ![hud.stringValue isEqualToString:body]) {
            hud.stringValue = body;
        }
        if (window && ![window.title isEqualToString:title]) {
            window.title = title;
        }
        if (!hud) {
            return;
        }
        CGFloat height = help ? 64.0 : 36.0;
        if (fabs(hud.frame.size.height - height) > 0.5) {
            NSRect hudFrame = hud.frame;
            hudFrame.size.height = height;
            hud.frame = hudFrame;
        }
    };

    if (!_view.renderer.ready) {
        NSAlert* alert = [NSAlert new];
        alert.messageText = @"Metal could not start";
        alert.informativeText = @"This tribute needs a Metal device and the World.metallib in the app bundle. Build it with make from the project folder.";
        [alert runModal];
    }

    [self installMenus];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activate];
}

- (void)installMenus {
    NSMenu* bar = [NSMenu new];
    NSMenuItem* appItem = [NSMenuItem new];
    [bar addItem:appItem];
    NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"PCFE 3D World"];
    NSMenuItem* about = [[NSMenuItem alloc] initWithTitle:@"About PCFE 3D World" action:@selector(showAbout:) keyEquivalent:@""];
    about.target = self;
    [appMenu addItem:about];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit PCFE 3D World" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    NSMenuItem* viewItem = [NSMenuItem new];
    [bar addItem:viewItem];
    NSMenu* viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem* full = [[NSMenuItem alloc] initWithTitle:@"Full Screen" action:@selector(toggleFullScreenFromMenu:) keyEquivalent:@"f"];
    full.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
    full.target = self;
    [viewMenu addItem:full];
    viewItem.submenu = viewMenu;
    NSApp.mainMenu = bar;
}

- (void)showAbout:(id)sender {
    (void)sender;
    NSString* credits =
        @"A tribute to a 3D world shown on a BTEC National Diploma Advanced Programming course, around 2001–2003.\n\n"
        @"It may have shipped with DirectX, or the lecturer may have written it. This version remembers one world — rust-red and rough, or smooth and brown — a moon, a man-made satellite, a horizontal orbit, and a zoom that travels a banana-shaped curve.\n\n"
        @"Drawn with Metal. It is not a copy of a DirectX sample.";
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        NSAboutPanelOptionApplicationName : @"PCFE 3D World",
        NSAboutPanelOptionApplicationVersion : @"1.0",
        NSAboutPanelOptionCredits : [[NSAttributedString alloc] initWithString:credits],
    }];
}

- (void)toggleFullScreenFromMenu:(id)sender {
    [_window toggleFullScreen:sender];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    return YES;
}

@end

int main() {
    @autoreleasepool {
        NSApplication* app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate* delegate = [AppDelegate new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
