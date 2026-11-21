#pragma once

#include <cstdint>

namespace gfx::upscale {

// UI-owned preference. The renderer observes changes on its own serial thread.
void set_requested(bool enabled);
bool requested();

// Renderer-published state; safe to read from the host/UI thread.
bool available();
bool active();
const char* status();
uint32_t source_format();
uint32_t input_width();
uint32_t input_height();
uint32_t output_width();
uint32_t output_height();

}  // namespace gfx::upscale
