#pragma once
#include <functional>
#include <string>
namespace ios {
void prompt_text(const std::u16string&, int, std::function<void(bool, std::u16string)>);
void run_gpu(void (*fn)());
bool controls_block_input();
void adopt_game_controller(bool pro);
void reset_performance_window();
struct PlayTime { double totalSeconds, sessionSeconds; };
PlayTime play_time();
}
