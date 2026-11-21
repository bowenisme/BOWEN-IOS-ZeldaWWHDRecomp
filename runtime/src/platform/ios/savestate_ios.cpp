// iOS settings panel's instant-state slots, built on the main project's save-state API (savestate.h).
// The panel (controls.mm) came from the community iOS fork, which had its own save-state backend; this
// keeps the panel and uses the upstream backend, so save states follow upstream fixes.
#include "../../savestate.h"
#include <filesystem>
#include <fstream>

namespace ss {
namespace {
std::string switch_file() { return states_dir() + "/ios_instant_states_off"; }
void link_thumbnail(SlotInfo& info) {
    if (!info.used || info.path.empty()) return;
    std::filesystem::path png(info.path);
    png.replace_extension(".png");
    std::error_code ec;
    if (std::filesystem::exists(png, ec)) {
        info.thumbnail_path = png.string();
        info.thumbnail_linked = true;
    }
}
}  // namespace

SlotInfo full_slot_info(int slot) {
    SlotInfo info = slot_info(slot);
    if (info.used && info.portable) return SlotInfo{};  // the panel only loads full states
    link_thumbnail(info);
    return info;
}

void request_save_full(int slot, std::function<void(bool, const std::string&)> done) {
    if (!full_states()) set_full_states(true);  // the panel's slots are exact snapshots
    request_save(slot, std::move(done));
}

void request_load_full(int slot, std::function<void(bool, const std::string&)> done) {
    request_load(slot, std::move(done));
}

bool instant_states_enabled() {
    std::error_code ec;
    return !std::filesystem::exists(switch_file(), ec);
}

void set_instant_states_enabled(bool on) {
    std::error_code ec;
    if (on) std::filesystem::remove(switch_file(), ec);
    else std::ofstream(switch_file()) << "off\n";
}
}  // namespace ss
