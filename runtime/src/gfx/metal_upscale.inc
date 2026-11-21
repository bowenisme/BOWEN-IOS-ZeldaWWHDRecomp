// iOS-only MetalFX spatial upscaling. Included once by metal_present.inc inside namespace gfx.
#ifdef WWHD_IOS

#include <atomic>
#include <cmath>

namespace upscale {
namespace {

enum State : int {
    kOff,
    kChecking,
    kUnsupportedDevice,
    kUnsupportedFormat,
    kInvalidDimensions,
    kScalerFailure,
    kTextureFailure,
    kNoTv,
    kActive,
};

std::atomic<bool> g_requested{false};
std::atomic<bool> g_available{false};
std::atomic<bool> g_active{false};
std::atomic<int> g_status{kOff};
std::atomic<uint32_t> g_source_format{0};
std::atomic<uint32_t> g_input_width{0}, g_input_height{0}, g_output_width{0}, g_output_height{0};
std::atomic<uint64_t> g_request_generation{0};

id<MTLDevice> g_checked_device = nil;
bool g_checked_capability = false;
bool g_device_supports_scaling = false;
id<MTLDevice> g_normalize_device = nil;
id<MTLRenderPipelineState> g_normalize_pipeline = nil;
bool g_normalize_attempted = false;

struct Cache {
    id<MTLDevice> device = nil;
    id<MTLFXSpatialScaler> scaler = nil;
    id<MTLTexture> input = nil;
    id<MTLTexture> output = nil;
    NSUInteger source_width = 0, source_height = 0;
    NSUInteger output_width = 0, output_height = 0;
    MTLPixelFormat source_format = MTLPixelFormatInvalid;
    bool source_linear = false;
    bool attempted = false;
    bool ready = false;
};

Cache g_cache;
uint64_t g_cache_generation = UINT64_MAX;

void publish(State state) {
    g_status.store(state, std::memory_order_release);
    g_active.store(state == kActive, std::memory_order_release);
}

void clear_cache() {
    g_cache.output = nil;
    g_cache.input = nil;
    g_cache.scaler = nil;
    g_cache.device = nil;
    g_cache.source_width = g_cache.source_height = 0;
    g_cache.output_width = g_cache.output_height = 0;
    g_cache.source_format = MTLPixelFormatInvalid;
    g_cache.source_linear = false;
    g_cache.attempted = false;
    g_cache.ready = false;
    g_input_width.store(0, std::memory_order_relaxed);
    g_input_height.store(0, std::memory_order_relaxed);
    g_output_width.store(0, std::memory_order_relaxed);
    g_output_height.store(0, std::memory_order_relaxed);
}

void observe_request_change() {
    const uint64_t generation = g_request_generation.load(std::memory_order_acquire);
    if (generation == g_cache_generation) return;
    clear_cache();
    g_cache_generation = generation;
}

bool supported_source_format(MTLPixelFormat format) {
    switch (format) {
        case MTLPixelFormatRGBA8Unorm:
        case MTLPixelFormatBGRA8Unorm:
        case MTLPixelFormatRGBA8Unorm_sRGB:
        case MTLPixelFormatBGRA8Unorm_sRGB:
        case MTLPixelFormatRGB10A2Unorm:
        case MTLPixelFormatRGBA16Float:
        case MTLPixelFormatRG11B10Float: return true;
        default: return false;
    }
}

void refresh_device() {
    if (g_checked_capability && g_checked_device == R.device) return;
    g_checked_device = R.device;
    g_checked_capability = true;
    g_device_supports_scaling = false;
    if (@available(iOS 16.0, *)) {
        g_device_supports_scaling = R.device && [MTLFXSpatialScalerDescriptor supportsDevice:R.device];
    }
    g_available.store(g_device_supports_scaling, std::memory_order_release);
    if (requested() && !g_device_supports_scaling) publish(kUnsupportedDevice);
}

bool cache_matches(id<MTLTexture> source, bool source_linear, NSUInteger out_width, NSUInteger out_height) {
    return g_cache.attempted && g_cache.device == R.device && g_cache.source_width == source.width &&
           g_cache.source_height == source.height && g_cache.source_format == source.pixelFormat &&
           g_cache.source_linear == source_linear && g_cache.output_width == out_width &&
           g_cache.output_height == out_height;
}

bool create_cache(id<MTLTexture> source, bool source_linear, NSUInteger out_width, NSUInteger out_height) {
    clear_cache();
    g_cache.device = R.device;
    g_cache.source_width = source.width;
    g_cache.source_height = source.height;
    g_cache.source_format = source.pixelFormat;
    g_source_format.store((uint32_t)source.pixelFormat,std::memory_order_relaxed);
    g_cache.source_linear = source_linear;
    g_cache.output_width = out_width;
    g_cache.output_height = out_height;
    g_cache.attempted = true;

    if (!supported_source_format(source.pixelFormat)) {
        publish(kUnsupportedFormat);
        return false;
    }
    if (!R.device || !source.width || !source.height || out_width < source.width || out_height < source.height ||
        (out_width == source.width && out_height == source.height) || out_width > 8192 || out_height > 8192 ||
        source.textureType != MTLTextureType2D || source.sampleCount != 1 ||
        !(source.usage & MTLTextureUsageShaderRead)) {
        publish(kInvalidDimensions);
        return false;
    }

    if (@available(iOS 16.0, *)) {
        MTLFXSpatialScalerDescriptor* descriptor = [MTLFXSpatialScalerDescriptor new];
        descriptor.inputWidth = source.width;
        descriptor.inputHeight = source.height;
        descriptor.outputWidth = out_width;
        descriptor.outputHeight = out_height;
        // The copy pass below normalizes every supported source to perceptually encoded RGBA8.
        descriptor.colorTextureFormat = MTLPixelFormatRGBA8Unorm;
        descriptor.outputTextureFormat = MTLPixelFormatRGBA8Unorm;
        descriptor.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        g_cache.scaler = [descriptor newSpatialScalerWithDevice:R.device];
    }
    if (!g_cache.scaler) {
        publish(kScalerFailure);
        return false;
    }

    MTLTextureDescriptor* input_desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                           width:source.width
                                                                                          height:source.height
                                                                                       mipmapped:NO];
    input_desc.storageMode = MTLStorageModePrivate;
    input_desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | g_cache.scaler.colorTextureUsage;
    g_cache.input = [R.device newTextureWithDescriptor:input_desc];

    MTLTextureDescriptor* output_desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                            width:out_width
                                                                                           height:out_height
                                                                                        mipmapped:NO];
    output_desc.storageMode = MTLStorageModePrivate;
    output_desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | g_cache.scaler.outputTextureUsage;
    g_cache.output = [R.device newTextureWithDescriptor:output_desc];
    g_cache.ready = g_cache.input && g_cache.output;
    if (!g_cache.ready) {
        publish(kTextureFailure);
        return false;
    }
    return true;
}

bool normalize_input(id<MTLCommandBuffer> commands, id<MTLTexture> source, bool source_linear) {
    if (g_normalize_device != R.device) {
        g_normalize_device = R.device;
        g_normalize_pipeline = nil;
        g_normalize_attempted = false;
    }
    if (!g_normalize_attempted) {
        g_normalize_attempted = true;
        MTLRenderPipelineDescriptor* descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = [g_lib newFunctionWithName:@"present_vs"];
        descriptor.fragmentFunction = [g_lib newFunctionWithName:@"present_fs"];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        NSError* error = nil;
        g_normalize_pipeline = [R.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (!g_normalize_pipeline)
            LOG("[upscale] normalization pipeline unavailable: %s", error.localizedDescription.UTF8String ?: "unknown error");
    }
    if (!g_normalize_pipeline) {
        publish(kTextureFailure);
        return false;
    }
    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = g_cache.input;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
    if (!encoder) return false;

    // Match the normal present shader's transfer handling, with edge smoothing before reconstruction, rather than sharpening aliased edges.
    float rect[4] = {0, 0, 1, 1};
    struct PresentParams { int aa, conv; float sharp, foot; } params{1, source_linear ? 2 : 0, 1.0f, 1.0f};
    [encoder setRenderPipelineState:g_normalize_pipeline];
    [encoder setVertexBytes:rect length:sizeof(rect) atIndex:0];
    [encoder setFragmentTexture:source atIndex:0];
    [encoder setFragmentBytes:&params length:sizeof(params) atIndex:0];
    [encoder setFragmentSamplerState:R.linearClamp atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    return true;
}

}  // namespace

static id<MTLTexture> prepare_tv_texture(id<MTLTexture> source, float target_width, float target_height, bool allow_upscale) {
    observe_request_change();
    g_active.store(false, std::memory_order_release);
    g_input_width.store(0, std::memory_order_relaxed);
    g_input_height.store(0, std::memory_order_relaxed);
    g_output_width.store(0, std::memory_order_relaxed);
    g_output_height.store(0, std::memory_order_relaxed);
    if (!requested()) {
        publish(kOff);
        return nil;
    }
    refresh_device();
    if (!g_device_supports_scaling) {
        publish(kUnsupportedDevice);
        return nil;
    }
    if (!allow_upscale) {
        publish(kNoTv);
        return nil;
    }
    if (!source || target_width <= 0 || target_height <= 0) {
        publish(kInvalidDimensions);
        return nil;
    }

    const NSUInteger out_width = (NSUInteger)std::lround(target_width);
    const NSUInteger out_height = (NSUInteger)std::lround(target_height);
    const bool source_linear = R.tv.srgb.load(std::memory_order_relaxed);
    if (!cache_matches(source, source_linear, out_width, out_height) &&
        !create_cache(source, source_linear, out_width, out_height)) return nil;
    if (!g_cache.ready) return nil;

    // MetalFX input/output usage comes from the instantiated scaler; the scan texture itself is
    // sampled only by this copy pass. The private output is always an intermediate, never a drawable.
    end_encoder();
    id<MTLCommandBuffer> commands = command_buffer();
    if (!normalize_input(commands, source, source_linear)) return nil;
    g_cache.scaler.colorTexture = g_cache.input;
    g_cache.scaler.outputTexture = g_cache.output;
    g_cache.scaler.inputContentWidth = g_cache.source_width;
    g_cache.scaler.inputContentHeight = g_cache.source_height;
    [g_cache.scaler encodeToCommandBuffer:commands];

    g_input_width.store((uint32_t)g_cache.source_width, std::memory_order_relaxed);
    g_input_height.store((uint32_t)g_cache.source_height, std::memory_order_relaxed);
    g_output_width.store((uint32_t)g_cache.output_width, std::memory_order_relaxed);
    g_output_height.store((uint32_t)g_cache.output_height, std::memory_order_relaxed);
    publish(kActive);
    return g_cache.output;
}

void set_requested(bool enabled) {
    const bool previous = g_requested.exchange(enabled, std::memory_order_acq_rel);
    if (previous == enabled) return;
    g_request_generation.fetch_add(1, std::memory_order_release);
    g_active.store(false, std::memory_order_release);
    g_input_width.store(0, std::memory_order_relaxed);
    g_input_height.store(0, std::memory_order_relaxed);
    g_output_width.store(0, std::memory_order_relaxed);
    g_output_height.store(0, std::memory_order_relaxed);
    g_status.store(enabled ? kChecking : kOff, std::memory_order_release);
}

bool requested() { return g_requested.load(std::memory_order_acquire); }
bool available() { return g_available.load(std::memory_order_acquire); }
bool active() { return g_active.load(std::memory_order_acquire); }

const char* status() {
    switch (g_status.load(std::memory_order_acquire)) {
        case kChecking: return "checking";
        case kUnsupportedDevice: return "unsupported: device";
        case kUnsupportedFormat: return "fallback: source format";
        case kInvalidDimensions: return "fallback: dimensions";
        case kScalerFailure: return "fallback: scaler creation";
        case kTextureFailure: return "fallback: texture or encoder";
        case kNoTv: return "inactive: GamePad view";
        case kActive: return "active";
        default: return "off";
    }
}

uint32_t source_format() { return g_source_format.load(std::memory_order_relaxed); }
uint32_t input_width() { return g_input_width.load(std::memory_order_relaxed); }
uint32_t input_height() { return g_input_height.load(std::memory_order_relaxed); }
uint32_t output_width() { return g_output_width.load(std::memory_order_relaxed); }
uint32_t output_height() { return g_output_height.load(std::memory_order_relaxed); }

void refresh() { refresh_device(); }

}  // namespace upscale

#else

namespace upscale {
void set_requested(bool) {}
bool requested() { return false; }
bool available() { return false; }
bool active() { return false; }
const char* status() { return "unsupported: platform"; }
uint32_t source_format() { return 0; }
uint32_t input_width() { return 0; }
uint32_t input_height() { return 0; }
uint32_t output_width() { return 0; }
uint32_t output_height() { return 0; }
}  // namespace upscale

#endif
