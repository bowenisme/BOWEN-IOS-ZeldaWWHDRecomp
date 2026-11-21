#!/usr/bin/env python3
"""Guard iOS settings categories and visible-only UI refreshes without UIKit or a device."""
from pathlib import Path

source = (Path(__file__).resolve().parents[1] / "src/platform/ios/controls.mm").read_text()


def section(start: str, end: str) -> str:
    begin = source.index(start)
    return source[begin:source.index(end, begin)]


build = section("UIStackView* screenStack=", "UILabel* detailsTitle=")
assert '@[@"画面",@"操控",@"辅助",@"存档"]' in build
assert "self.settingsPages=@[[self scrollWithContent:screenStack],[self scrollWithContent:controlsStack]," in build
assert "[self scrollWithContent:assistStack],[self scrollWithContent:saveStack]]" in build
screen, tail = build.split("UIStackView* controlsStack=", 1)
controls, tail = tail.split("UIStackView* assistStack=", 1)
assist, tail = tail.split("UIStackView* saveStack=", 1)
saves = tail.split("self.settingsPages=", 1)[0]
assert "self.performance" in screen and "self.quality" in screen
assert "self.controllerMode" in controls and "self.touchMode" in controls
assert "self.fastEnabled" in assist and "self.fast" in assist and "self.rate" in assist
assert "self.states" in saves and "self.thumbnail" in saves
assert "[close.widthAnchor constraintEqualToConstant:112]" in build
assert "self.settingsPage.topAnchor" in build and "self.settingsBody.bottomAnchor" in build

update = section("void update_controls(NSDictionary* metrics)", "NSDictionary* controls_state()")
assert "[controls refresh]" not in update
assert all(name not in update for name in ("full_slot_info", "slot_info", "renderSlot"))
assert "if(enforce_frame_limit()&&panel_open.load()" in update
assert "if(controls.performance.on)[controls refreshHUD];" in update
assert "if(!controls.detailsPage.hidden)[controls refreshDetails];" in update
assert "if(!controls.settingsPage.hidden&&controls.settingsCategory.selectedSegmentIndex==kSettingsScreen)" in update

details = section("- (void)refreshDetails {", "- (void)resetPerformance {")
assert details.startswith("- (void)refreshDetails {\n    if(!panel_open.load()||self.detailsPage.hidden)return;")
assert "self.detailsGraph.samples=graph" in details
assert "self.hudGraph" not in details

slot = section("- (void)refreshSlot {", "- (void)scheduleThumbnailRetryForPath:")
assert "!panel_open.load()||self.settingsPage.hidden||self.settingsCategory.selectedSegmentIndex!=kSettingsSaves" in slot

assert "Each settings category selects exactly one independent scroll page" in source
assert "Hidden details text and graph do not refresh from metrics" in source
assert "settingsPage.hidden&&!controls.detailsPage.hidden" in source
assert "controls.detailsPage.hidden&&!controls.settingsPage.hidden" in source
print("PASS: four scrollable settings categories, visible-only metric UI updates, hidden-details guard")
