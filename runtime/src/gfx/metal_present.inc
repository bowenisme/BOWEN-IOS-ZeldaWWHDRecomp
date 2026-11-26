// Shared Metal composition; included inside namespace gfx by each window host (display.mm on the Mac,
// platform/ios/host.mm on iPhone/iPad).
// Shared Metal composition; included inside namespace gfx by each window host.
// ---------------------------------------------------------------- presentation shader
static const char* kPresentShader = R"(
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; float2 uv; };
vertex VOut present_vs(uint vid [[vertex_id]], constant float4& rect [[buffer(0)]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);          // fullscreen triangle strip corners
    VOut o;
    o.uv = p * 0.5;                                       // 0..1 (flipped below)
    float2 ndc = rect.xy + p * 0.5 * rect.zw;
    o.pos = float4(ndc.x * 2.0 - 1.0, 1.0 - ndc.y * 2.0, 0.0, 1.0);
    return o;
}
// optional edge smoothing (FXAA, the classic console variant), evaluated on the source picture's
// texel grid while scaling it to the window
static float luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }
static float3 fxaa(texture2d<float> t, sampler s, float2 uv) {
    float2 rcp = 1.0 / float2(t.get_width(), t.get_height());
    float3 nw = t.sample(s, uv + float2(-1, -1) * rcp).rgb, ne = t.sample(s, uv + float2(1, -1) * rcp).rgb;
    float3 sw = t.sample(s, uv + float2(-1, 1) * rcp).rgb, se = t.sample(s, uv + float2(1, 1) * rcp).rgb;
    float3 m = t.sample(s, uv).rgb;
    float lnw = luma(nw), lne = luma(ne), lsw = luma(sw), lse = luma(se), lm = luma(m);
    float lmin = min(lm, min(min(lnw, lne), min(lsw, lse))), lmax = max(lm, max(max(lnw, lne), max(lsw, lse)));
    if (lmax - lmin < max(0.0312, lmax * 0.125)) return m;  // no edge here
    float2 dir = float2(-((lnw + lne) - (lsw + lse)), (lnw + lsw) - (lne + lse));
    float reduce = max((lnw + lne + lsw + lse) * (0.25 / 8.0), 1.0 / 128.0);
    dir = clamp(dir / (min(abs(dir.x), abs(dir.y)) + reduce), -8.0, 8.0) * rcp;
    float3 a = 0.5 * (t.sample(s, uv + dir * (1.0 / 3.0 - 0.5)).rgb + t.sample(s, uv + dir * (2.0 / 3.0 - 0.5)).rgb);
    float3 b = a * 0.5 + 0.25 * (t.sample(s, uv - dir * 0.5).rgb + t.sample(s, uv + dir * 0.5).rgb);
    float lb = luma(b);
    return (lb < lmin || lb > lmax) ? a : b;
}
struct Params {
    int aa;          // FXAA
    int conv;        // 1: source is display-encoded, target expects linear; 2: the other way round
    float sharp;     // > 1: sharp bilinear (the blend band between texels shrinks by this factor)
    float foot;      // source texels per target pixel (> 1: 4-tap box filter when shrinking)
};
static float3 to_linear(float3 c) { return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045); }
static float3 to_srgb(float3 c) { return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308); }
fragment float4 present_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],
                           constant Params& p [[buffer(0)]]) {
    float2 size = float2(tex.get_width(), tex.get_height());
    float2 uv = in.uv;
    if (p.sharp > 1.0) {
        float2 t = uv * size - 0.5, i = floor(t), f = t - i;
        f = clamp((f - 0.5) * p.sharp + 0.5, 0.0, 1.0);
        uv = (i + f + 0.5) / size;
    }
    float3 c;
    if (p.aa) {
        c = fxaa(tex, s, uv);
    } else if (p.foot > 1.25) {
        float2 d = 0.25 * min(p.foot, 4.0) / size;
        c = 0.25 * (tex.sample(s, uv + float2(-d.x, -d.y)).rgb + tex.sample(s, uv + float2(d.x, -d.y)).rgb +
                    tex.sample(s, uv + float2(-d.x, d.y)).rgb + tex.sample(s, uv + float2(d.x, d.y)).rgb);
    } else {
        c = tex.sample(s, uv).rgb;
    }
    if (p.conv == 1) c = to_linear(saturate(c));
    else if (p.conv == 2) c = to_srgb(saturate(c));
    return float4(c, 1.0);
}
fragment float4 solid_fs(VOut in [[stage_in]], constant float4& color [[buffer(0)]]) { return color; }
)";

static id<MTLLibrary> g_lib;
// pipelines by (target format, solid colour, blended)
static id<MTLRenderPipelineState> pipeline(MTLPixelFormat fmt, bool solid, bool blend) {
    static std::mutex mu;
    static std::map<std::tuple<int, bool, bool>, id<MTLRenderPipelineState>> cache;
    std::lock_guard<std::mutex> lk(mu);
    auto key = std::make_tuple((int)fmt, solid, blend);
    auto it = cache.find(key);
    if (it != cache.end()) return it->second;
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [g_lib newFunctionWithName:@"present_vs"];
    d.fragmentFunction = [g_lib newFunctionWithName:solid ? @"solid_fs" : @"present_fs"];
    d.colorAttachments[0].pixelFormat = fmt;
    if (blend) {
        // overlay opacity: the encoder's blend colour alpha (solid: the colour's alpha)
        auto* a = d.colorAttachments[0];
        a.blendingEnabled = YES;
        a.sourceRGBBlendFactor = a.sourceAlphaBlendFactor = solid ? MTLBlendFactorSourceAlpha : MTLBlendFactorBlendAlpha;
        a.destinationRGBBlendFactor = a.destinationAlphaBlendFactor =
            solid ? MTLBlendFactorOneMinusSourceAlpha : MTLBlendFactorOneMinusBlendAlpha;
    }
    NSError* err = nil;
    id<MTLRenderPipelineState> p = [R.device newRenderPipelineStateWithDescriptor:d error:&err];
    if (!p) fatal("present pipeline: %s", err.localizedDescription.UTF8String);
    cache[key] = p;
    return p;
}

static void create_present_pipeline() {
    NSError* err = nil;
    g_lib = [R.device newLibraryWithSource:[NSString stringWithUTF8String:kPresentShader] options:nil error:&err];
    if (!g_lib) fatal("present shader: %s", err.localizedDescription.UTF8String);
    R.presentPipeline = pipeline(MTLPixelFormatBGRA8Unorm, false, false);
    R.presentPipelineSRGB = pipeline(MTLPixelFormatBGRA8Unorm_sRGB, false, false);
    MTLSamplerDescriptor* sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    R.linearClamp = [R.device newSamplerStateWithDescriptor:sd];
}

// ---------------------------------------------------------------- composition
static bool is_srgb(MTLPixelFormat f) { return f == MTLPixelFormatBGRA8Unorm_sRGB || f == MTLPixelFormatRGBA8Unorm_sRGB; }

// draw `tex` into the target rectangle (pixels); src_linear: the image holds linear values (sRGB scan buffer)
// dyn: the picture's dynamic resolution factor (Screen::dyn; below 1: always scaled filtered, as the Vulkan
// presentation: integer scaling becomes smooth, sharp scaling takes its sharpness from the full size)
static void draw_image(id<MTLRenderCommandEncoder> e, MTLPixelFormat fmt, float dw, float dh, id<MTLTexture> tex,
                       bool src_linear, Box b, float alpha, float dyn = 1.0f, bool apply_fxaa = true) {
    if (!tex || b.w <= 0 || b.h <= 0) return;
    float rect[4] = {b.x / dw, b.y / dh, b.w / dw, b.h / dh};
    bool blend = alpha < 0.999f;
    [e setRenderPipelineState:pipeline(fmt, false, blend)];
    if (blend) [e setBlendColorRed:0 green:0 blue:0 alpha:alpha];
    struct { int aa, conv; float sharp, foot; } p;
    p.aa = apply_fxaa && fxaa_enabled() ? 1 : 0;
    bool dst_linear = is_srgb(fmt);
    p.conv = src_linear == dst_linear ? 0 : dst_linear ? 1 : 2;
    float scale = std::min(b.w / tex.width, b.h / tex.height);  // target pixels per source texel
    int filter = g_filter;
    float sharpScale = scale;
    if (dyn < 1.0f) {
        if (filter == kInteger) filter = kSmooth;
        else if (filter == kSharp) sharpScale = std::min(b.w / (tex.width / dyn), b.h / (tex.height / dyn));
    }
    p.sharp = filter == kSmooth || sharpScale <= 1.0f ? 1.0f : filter == kSharp ? sharpScale : 1e4f;
    p.foot = scale < 1.0f ? 1.0f / scale : 1.0f;
    [e setVertexBytes:rect length:sizeof rect atIndex:0];
    [e setFragmentTexture:tex atIndex:0];
    [e setFragmentBytes:&p length:sizeof p atIndex:0];
    [e setFragmentSamplerState:R.linearClamp atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

static void draw_solid(id<MTLRenderCommandEncoder> e, MTLPixelFormat fmt, float dw, float dh, Box b, const float rgba[4]) {
    float rect[4] = {b.x / dw, b.y / dh, b.w / dw, b.h / dh};
    [e setRenderPipelineState:pipeline(fmt, true, true)];
    [e setVertexBytes:rect length:sizeof rect atIndex:0];
    [e setFragmentBytes:rgba length:16 atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
}

// this frame's settings overlay (null: nothing shown)
static ImDrawData* g_overlay_draw = nullptr;
static void overlay_metal_init() { ImGui_ImplMetal_Init(R.device); }

#include "metal_upscale.inc"

// the TV window's picture: TV image scaled to fit, GamePad overlay on top
static void compose_tv(id<MTLTexture> target, const Layout& L, bool allow_upscale = false) {
    end_encoder();
    id<MTLTexture> tv_texture = R.tv.tex;
    bool tv_linear = R.tv.srgb.load(std::memory_order_relaxed);
    bool reconstructed = false;
#ifdef WWHD_IOS
    if (allow_upscale) {
        if (id<MTLTexture> scaled = upscale::prepare_tv_texture(R.tv.tex, L.tv.w, L.tv.h, !L.drc_only)) {
            tv_texture = scaled;
            reconstructed = true;
            tv_linear = false;  // the MetalFX output uses perceptually encoded RGBA8Unorm
        }
    }
#else
    (void)allow_upscale;
#endif
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [command_buffer() renderCommandEncoderWithDescriptor:rp];
    float dw = target.width, dh = target.height;
    MTLPixelFormat fmt = target.pixelFormat;
    // MetalFX output is already at screen size: no dynamic-resolution filtering and no second FXAA pass
    draw_image(e, fmt, dw, dh, tv_texture, tv_linear, L.tv, 1.0f, reconstructed ? 1.0f : float(R.tv.dyn), !reconstructed);
    if (L.pip_on && R.drc.tex) {
        float op = L.drc_only ? 1.0f : g_pip_opacity.load(), bw = std::max(1.0f, roundf(L.pip.w / 200.0f));
        float frame[4] = {0, 0, 0, 0.6f * op};
        draw_solid(e, fmt, dw, dh, {L.pip.x - bw, L.pip.y - bw, L.pip.w + 2 * bw, L.pip.h + 2 * bw}, frame);
        if (L.drc_only)
            gamepad_draw_bars(R.device, e, fmt, unsigned(dw), unsigned(dh), {0,0,dw,dh},
                             {L.pip.x,L.pip.y,L.pip.w,L.pip.h}, R.drc.tex, R.drc.backdrop, R.drc.srgb, op);
        draw_image(e, fmt, dw, dh, R.drc.tex, R.drc.srgb, L.pip, op, R.drc.dyn);
        if(auto* draw=overlay::guesthud::gamepad_region(dw,dh,L.pip.x,L.pip.y,L.pip.w,L.pip.h,op)) {
            if(is_srgb(fmt))overlay::linearize_colors(draw,true);
            ImGui_ImplMetal_NewFrame(rp);
            ImGui_ImplMetal_RenderDrawData(draw,command_buffer(),e);
        }
    }
    // settings overlay (overlay/overlay.h) on top: Dear ImGui's Metal backend in the same pass
    if (g_overlay_draw) {
        if (is_srgb(fmt)) overlay::linearize_colors(g_overlay_draw);
        ImGui_ImplMetal_NewFrame(rp);
        ImGui_ImplMetal_RenderDrawData(g_overlay_draw, command_buffer(), e);
    }
    [e endEncoding];
}

static void compose_drc(id<MTLTexture> target) {
    end_encoder();
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [command_buffer() renderCommandEncoderWithDescriptor:rp];
    Layout L = layout(target.width, target.height, nominal_w(R.drc), nominal_h(R.drc), 0, 0, false);
    gamepad_draw_bars(R.device,e,target.pixelFormat,unsigned(target.width),unsigned(target.height),
                     {0,0,float(target.width),float(target.height)}, {L.tv.x,L.tv.y,L.tv.w,L.tv.h},
                     R.drc.tex,R.drc.backdrop,R.drc.srgb,1);
    draw_image(e, target.pixelFormat, target.width, target.height, R.drc.tex, R.drc.srgb, L.tv, 1.0f, R.drc.dyn);
    if (auto* draw = overlay::guesthud::gamepad_region(target.width,target.height,L.tv.x,L.tv.y,L.tv.w,L.tv.h,1)) {
        if (is_srgb(target.pixelFormat)) overlay::linearize_colors(draw, true);
        ImGui_ImplMetal_NewFrame(rp);
        ImGui_ImplMetal_RenderDrawData(draw, command_buffer(), e);
    }
    [e endEncoding];
}

// ---------------------------------------------------------------- present
static id<MTLTexture> offscreen(NSUInteger w, NSUInteger h, bool srgb) {
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:srgb ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm
                                                                                 width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModePrivate;
    return [R.device newTextureWithDescriptor:d];
}

#ifdef WWHD_IOS
static std::atomic<uint64_t> g_ios_presented{0}, g_ios_drawables{0};
static std::atomic<uint64_t> g_ios_submitted{0};
static std::mutex g_ios_present_mutex;
static std::mutex g_ios_live_present_capture_mutex;
static std::string g_ios_live_present_capture_path;
static bool g_ios_live_present_capture_pending = false;
static bool ios_live_present_capture_enabled() {
    static const bool enabled = [] {
        const char* value = getenv("WWHD_IOS_LIVE_INPUT");
        return value && !strcmp(value, "1");
    }();
    return enabled;
}
static ios::pacing::PresentedTimes g_ios_present_times;
static ios::pacing::FrameHistory g_ios_frame_history;
static ios::pacing::FrameHistory ios_frame_history() {
    std::lock_guard<std::mutex> lock(g_ios_present_mutex);
    return g_ios_frame_history;
}
static ios::pacing::PresentedTimes ios_present_times() {
    std::lock_guard<std::mutex> lock(g_ios_present_mutex);
    return g_ios_present_times;
}
static std::atomic<uint32_t> g_ios_picture_width{0},g_ios_picture_height{0};
static bool duration_pacing_enabled() {
    static const bool enabled=[] {
        const char* value=getenv("WWHD_IOS_PRESENT_DURATION"); return !value || strcmp(value,"0")!=0;
    }();
    return enabled;
}

// The test bridge is opt-in. A path is queued only on an explicit JSON request; ordinary frames
// perform no readback allocation or PNG work.
bool request_ios_live_present_capture(const std::string& path) {
    if (!ios_live_present_capture_enabled() || path.empty()) return false;
    std::lock_guard<std::mutex> lock(g_ios_live_present_capture_mutex);
    if (g_ios_live_present_capture_pending) return false;
    g_ios_live_present_capture_path = path;
    g_ios_live_present_capture_pending = true;
    return true;
}

void cancel_ios_live_present_capture(const std::string& path) {
    std::lock_guard<std::mutex> lock(g_ios_live_present_capture_mutex);
    if (!g_ios_live_present_capture_pending || path != g_ios_live_present_capture_path) return;
    g_ios_live_present_capture_pending = false;
    g_ios_live_present_capture_path.clear();
}

static bool take_ios_live_present_capture_request(std::string& path) {
    std::lock_guard<std::mutex> lock(g_ios_live_present_capture_mutex);
    if (!g_ios_live_present_capture_pending) return false;
    g_ios_live_present_capture_pending = false;
    path.swap(g_ios_live_present_capture_path);
    return true;
}

static id<MTLTexture> ios_live_present_capture_target(id<MTLTexture> drawable) {
    if (!drawable || !drawable.width || !drawable.height) return nil;
    const MTLPixelFormat format = drawable.pixelFormat;
    if (format != MTLPixelFormatBGRA8Unorm && format != MTLPixelFormatBGRA8Unorm_sRGB &&
        format != MTLPixelFormatRGBA8Unorm && format != MTLPixelFormatRGBA8Unorm_sRGB) return nil;
    MTLTextureDescriptor* descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
        width:drawable.width height:drawable.height mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModePrivate;
    return [R.device newTextureWithDescriptor:descriptor];
}

static void capture_ios_live_present_texture(id<MTLTexture> texture, const std::string& path) {
    const NSUInteger w = texture.width, h = texture.height;
    const NSUInteger stride = w * 4, bytes = stride * h;
    const MTLPixelFormat format = texture.pixelFormat;
    const bool bgra = format == MTLPixelFormatBGRA8Unorm || format == MTLPixelFormatBGRA8Unorm_sRGB;
    end_encoder();
    id<MTLBuffer> buffer = [R.device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    if (!buffer) {
        LOG("[ios-live-input] final screenshot skipped: readback allocation failed");
        return;
    }
    id<MTLBlitCommandEncoder> blit = [command_buffer() blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                sourceSize:MTLSizeMake(w, h, 1) toBuffer:buffer destinationOffset:0 destinationBytesPerRow:stride
    destinationBytesPerImage:bytes];
    [blit endEncoding];
    const uint64_t frame = R.frame;
    const std::string file = path;
    [command_buffer() addCompletedHandler:^(id<MTLCommandBuffer> command) {
        if (command.status != MTLCommandBufferStatusCompleted) {
            LOG("[ios-live-input] final screenshot readback failed: %s", command.error.localizedDescription.UTF8String ?: "unknown");
            return;
        }
        std::shared_ptr<const void> owner(nullptr, [buffer](const void*) {});
        screenshot::write_async(file, (uint32_t)w, (uint32_t)h, stride, (const uint8_t*)buffer.contents,
                                owner, frame, false, bgra);
    }];
}

// CAMetalLayer drawables are framebuffer-only. Compose a requested frame once into a readable
// texture, copy that image to the drawable for presentation, and read the same pixels back.
static void compose_tv_for_ios_live_capture(id<MTLTexture> drawable, const Layout& layout) {
    if (!ios_live_present_capture_enabled()) {
        compose_tv(drawable, layout, true);
        return;
    }
    std::string path;
    if (!take_ios_live_present_capture_request(path)) {
        compose_tv(drawable, layout, true);
        return;
    }
    id<MTLTexture> capture = ios_live_present_capture_target(drawable);
    if (!capture) {
        LOG("[ios-live-input] final screenshot skipped: capture target unavailable");
        compose_tv(drawable, layout, true);
        return;
    }

    compose_tv(capture, layout, true);
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = drawable;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> encoder = [command_buffer() renderCommandEncoderWithDescriptor:rp];
    const bool source_linear = is_srgb(capture.pixelFormat);
    draw_image(encoder, drawable.pixelFormat, drawable.width, drawable.height, capture, source_linear,
        Box{0, 0, (float)drawable.width, (float)drawable.height}, 1.0f, 1.0f, false);
    [encoder endEncoding];
    capture_ios_live_present_texture(capture, path);
}
#else
// Mac: the window host presents the TV picture directly (no live-capture bridge, no MetalFX).
static void compose_tv_for_ios_live_capture(id<MTLTexture> drawable, const Layout& layout) { compose_tv(drawable, layout); }
#endif
static void present_to_layer(Screen& scr, void (^draw)(id<MTLTexture>)) {
    if (!scr.layer || !scr.tex) return;
    MTLPixelFormat want = scr.srgb ? MTLPixelFormatBGRA8Unorm_sRGB : MTLPixelFormatBGRA8Unorm;
    if (scr.layer.pixelFormat != want) scr.layer.pixelFormat = want;
    // Fast Forward retains the accelerated guest-vsync schedule, but must not also
    // wait for the physical display (90/120 logic frames/s on a 60 Hz display).
    const bool sync = !gx2::uncapped() && !mods::fast_forward_active();
#ifndef WWHD_IOS
    if (scr.layer.displaySyncEnabled != sync) {
        scr.layer.displaySyncEnabled = sync;
        if (&scr == &R.tv) interp::set_present_vsync(sync);
    }
#else
    interp::set_present_vsync(true);  // CAMetalLayer on iOS always waits for the display
#endif
    id<CAMetalDrawable> drawable = scr.visible ? [scr.layer nextDrawable] : nil;
    if (!drawable) return;
#ifdef WWHD_IOS
    ++g_ios_drawables;
    [drawable addPresentedHandler:^(id<MTLDrawable> shown) {
        ++g_ios_presented;
        std::lock_guard<std::mutex> lock(g_ios_present_mutex);
        g_ios_present_times.add(shown.presentedTime);
        static const bool report=getenv("WWHD_IOS_METRICS_HISTORY") || getenv("WWHD_IOS_METRICS_REPORT");
        if(perf::enabled() || report)g_ios_frame_history.add(shown.presentedTime,perf::generation());
        else g_ios_frame_history.reset();
    }];
#endif
    draw(drawable.texture);
#ifdef WWHD_IOS
    // Space displayed frames on ProMotion; the guest clock and interpolation schedule stay independent.
    if(duration_pacing_enabled() && sync) {
        const int target=ios::pacing::refresh_request(ios::pacing::target_output_fps(
            interp::mode(),interp::output_fps(),game_clock::rate(),mods::fast_forward_active()),interp::display_hz());
        [command_buffer() presentDrawable:drawable afterMinimumDuration:1.0/target];
    } else
#endif
    [command_buffer() presentDrawable:drawable];
#ifdef WWHD_IOS
    ++g_ios_submitted;
#endif
}

// Screenshot (screenshot.h): the picture at its own size, drawn as compose_tv draws it (FXAA, sRGB
// encoding) into an 8-bit image of the window's pixel format (its pipelines exist already) without the
// settings overlay, copied to a shared buffer in this frame's command buffer; the completion handler
// hands the buffer to the encoding thread (no wait here)
static void screenshot_screen(Screen& scr, const std::string& path, bool tv) {
    end_encoder();
    const NSUInteger w = scr.tex.width, h = scr.tex.height;
    // the TV window's pixel format for both pictures: its pipelines exist (the GamePad window's do not
    // while the GamePad picture is only shown as the overlay)
    const MTLPixelFormat pf = R.tv.layer ? R.tv.layer.pixelFormat : MTLPixelFormatRGBA8Unorm;
    const bool bgra = pf == MTLPixelFormatBGRA8Unorm || pf == MTLPixelFormatBGRA8Unorm_sRGB;
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:
                                   bgra || pf == MTLPixelFormatRGBA8Unorm_sRGB ? pf : MTLPixelFormatRGBA8Unorm
                                                                         width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [R.device newTextureWithDescriptor:d];
    MTLRenderPassDescriptor* rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [command_buffer() renderCommandEncoderWithDescriptor:rp];
    draw_image(e, t.pixelFormat, w, h, scr.tex, scr.srgb, Box{0, 0, (float)w, (float)h}, 1.0f, scr.dyn);
    [e endEncoding];
    id<MTLBuffer> buf = [R.device newBufferWithLength:w * h * 4 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> b = [command_buffer() blitCommandEncoder];
    [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, h, 1)
              toBuffer:buf destinationOffset:0 destinationBytesPerRow:w * 4 destinationBytesPerImage:w * h * 4];
    [b endEncoding];
    const uint64_t frame = R.frame;
    const std::string file = path;
    [command_buffer() addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        const bool ok = cb.status == MTLCommandBufferStatusCompleted;
        std::shared_ptr<const void> owner(nullptr, [buf](const void*) {});  // keeps the buffer until written
        screenshot::write_async(file, (uint32_t)w, (uint32_t)h, w * 4, ok ? (const uint8_t*)buf.contents : nullptr, owner, frame, tv,
                                bgra);
    }];
}
static void take_screenshot(const PresentPlan& P) {
    std::string tvPath, drcPath;
    if (!R.tv.tex || !screenshot::take(R.frame, tvPath, drcPath)) return;
    const CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    screenshot_screen(R.tv, tvPath, true);
    // the GamePad picture while it is shown (GamePad window, picture-in-picture, GamePad only)
    if (!drcPath.empty() && R.drc.tex && (P.drc_window || P.pip_on || P.drc_only)) {
        screenshot_screen(R.drc, drcPath, false);
    } else if (!drcPath.empty()) {
        LOG("[screenshot] GamePad picture not shown: only the TV picture saved");
        screenshot::write_async(drcPath, 0, 0, 0, nullptr, nullptr, R.frame, false);
    }
    LOG("[screenshot] frame %llu: recorded in %.2f ms (render thread)", (unsigned long long)R.frame, (CFAbsoluteTimeGetCurrent() - t0) * 1000.0);
}

// Metal, called from swap(): compose and present the TV window (with the GamePad overlay) and the GamePad window
void present_screens() {
#ifdef WWHD_IOS
    upscale::refresh();
    g_ios_picture_width=(uint32_t)R.tv.tex.width;
    g_ios_picture_height=(uint32_t)R.tv.tex.height;
#else
    // the iPhone GamePad picture's time: remote_pad::clock_ns's clock (not its header: this file is one of the
    // inputs of the prepared shaders' identity, cmake/pipeline_identity_inputs.txt)
    const uint64_t present_ns = uint64_t(std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
#endif
    CGSize ls = R.tv.layer ? R.tv.layer.drawableSize : CGSizeMake(0, 0);
    PresentPlan P = display_plan(R.tv.tex != nil, nominal_w(R.tv), nominal_h(R.tv), R.drc.tex != nil, nominal_w(R.drc), nominal_h(R.drc),
                                 ls.width, ls.height, R.frame);
    bool backdropNeeded = false;
    if (P.drc_only && P.pip_on && R.drc.tex && R.tv.layer && R.tv.visible) {
        if (P.sim) {
            const auto actual = layout(ls.width,ls.height,nominal_w(R.tv),nominal_h(R.tv),
                                       nominal_w(R.drc),nominal_h(R.drc),P.pip_wanted,P.drc_only);
            backdropNeeded = gamepad_backdrop::has_bars(ls.width,ls.height,
                {actual.pip.x,actual.pip.y,actual.pip.w,actual.pip.h});
        } else backdropNeeded = gamepad_backdrop::has_bars(P.dw,P.dh,{P.pip.x,P.pip.y,P.pip.w,P.pip.h});
    }
    if (P.drc_window && R.drc.tex && R.drc.layer && R.drc.visible) {
        const CGSize size = R.drc.layer.drawableSize;
        const auto drcLayout = layout(size.width,size.height,nominal_w(R.drc),nominal_h(R.drc),0,0,false);
        backdropNeeded |= gamepad_backdrop::has_bars(size.width,size.height,
            {drcLayout.tv.x,drcLayout.tv.y,drcLayout.tv.w,drcLayout.tv.h});
    }
    gamepad_backdrop::set_capture_requested(gamepad_backdrop::enabled.load(std::memory_order_relaxed) && backdropNeeded);
    Layout L;
    L.tv = P.tv;
    L.pip = P.pip;
    L.pip_on = P.pip_on;
    L.drc_only = P.drc_only;
    L.scale = P.scale;
    float dw = P.dw, dh = P.dh;
    bool pip = P.pip_wanted, drc_only = P.drc_only;
    Box game_box;
    const bool game_shown = game_picture_box(P, &game_box);
    overlay::guesthud::set_regions(P.tv.x,P.tv.y,P.tv.w,P.tv.h,!P.drc_only,game_box.x,game_box.y,game_box.w,game_box.h,game_shown);
    g_overlay_draw = overlay::frame(dw, dh, overlay_metal_init);  // settings overlay, drawn by compose_tv
#ifndef WWHD_IOS
    // The iPhone GamePad's screen (remote_video.h), the same picture whatever the GamePad screen mode here,
    // before anything for the windows and in a command buffer of its own: the encoder starts as soon as
    // it is drawn, not after the TV's composition and its wait for a drawable.
    if (R.drc.tex)
        if (id<MTLTexture> t = remote_video::begin_frame(R.device, R.drc.srgb, nominal_w(R.drc), nominal_h(R.drc))) {
            flush();  // the frame so far (the GamePad picture among it)
            compose_drc(t);
            remote_video::end_frame(command_buffer(), present_ns);
            flush();
        }
#endif
    // Hidden test-only composition: one reused GPU target, no drawable/readback/disk.
    // Like Metal's other resources this target is process-lifetime; replace on device/format change.
    const auto& diagnostic=headless_compose::policy();
    if(diagnostic.enabled()&&R.tv.tex) {
        static id<MTLTexture> target=nil;
        static headless_compose::Counter counter;
        counter.require_capacity(diagnostic);
        if(dw!=headless_compose::width||dh!=headless_compose::height)
            exception_report::raise("headless composition diagnostic requires WWHD_SIM_SCREEN=1280x720");
        const auto format=R.tv.srgb?MTLPixelFormatRGBA8Unorm_sRGB:MTLPixelFormatRGBA8Unorm;
        if(!target||target.device!=R.device||target.pixelFormat!=format)
            target=offscreen(headless_compose::width,headless_compose::height,R.tv.srgb);
        if(!target)exception_report::raise("headless Metal composition target allocation failed");
        compose_tv(target,L);
        unsigned commands=0;
        if(g_overlay_draw)for(const auto* list:g_overlay_draw->CmdLists)commands+=list->CmdBuffer.Size;
        const unsigned vertices=g_overlay_draw?g_overlay_draw->TotalVtxCount:0,indices=g_overlay_draw?g_overlay_draw->TotalIdxCount:0;
        if(counter.encoded(diagnostic,vertices,indices,commands))
            LOG("[headless-compose] Metal encoded_frames=%u last_vertices=%u last_indices=%u last_commands=%u total_vertices=%llu total_indices=%llu total_commands=%llu",counter.frames,vertices,indices,commands,
                (unsigned long long)counter.vertices,(unsigned long long)counter.indices,(unsigned long long)counter.commands);
    }
    take_screenshot(P);
    if (P.sim) {
        present_to_layer(R.tv, ^(id<MTLTexture> t) {
            CGSize ds = R.tv.layer.drawableSize;
            compose_tv_for_ios_live_capture(t, layout(ds.width, ds.height, nominal_w(R.tv), nominal_h(R.tv),
                                                      nominal_w(R.drc), nominal_h(R.drc), pip, drc_only));
        });
    } else {
        present_to_layer(R.tv, ^(id<MTLTexture> t) { compose_tv_for_ios_live_capture(t, L); });
    }
    bool drc_win = P.drc_window;
    if (drc_win) present_to_layer(R.drc, ^(id<MTLTexture> t) { compose_drc(t); });

    for (auto& path : display_take_present_dumps()) {
        if (!R.tv.tex || dw < 1 || dh < 1) continue;
        id<MTLTexture> t = offscreen((NSUInteger)dw, (NSUInteger)dh, R.tv.srgb);
        // Explicit display captures include the selected reconstruction, rather than an ordinary blit.
        compose_tv(t, L, true);
        dump_texture(t, path.c_str(), true, false);
        if (drc_win && R.drc.tex && R.drc.layer) {
            CGSize ds = R.drc.layer.drawableSize;
            id<MTLTexture> d = offscreen((NSUInteger)ds.width, (NSUInteger)ds.height, R.drc.srgb);
            compose_drc(d);
            std::string p = path;
            size_t dot = p.rfind(".png");
            p.insert(dot == std::string::npos ? p.size() : dot, "_drc");
            dump_texture(d, p.c_str(), true, false);
        }
        display_log_present_dump(path, P, nominal_w(R.tv), nominal_h(R.tv));
    }
}

