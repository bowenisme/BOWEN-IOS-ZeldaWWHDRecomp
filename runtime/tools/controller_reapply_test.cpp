// The re-apply decision after a save-state load: the game's controller mode (as the state left it)
// against the host's choice, which a load never changes.
#include "controller_reapply.h"
#include <cassert>
#include <cstdio>
#include <initializer_list>
using controller_reapply::needed_category;
int main() {
    using controller_reapply::follow_game_switch;
    using controller_reapply::pro_delivery;
    static_assert(follow_game_switch(false,true,1,true));
    static_assert(follow_game_switch(false,true,0,false));
    static_assert(!follow_game_switch(true,true,1,true)); // host change/load remains authoritative
    static_assert(!follow_game_switch(false,false,1,true));
    static_assert(!follow_game_switch(false,true,3,true));
    static_assert(pro_delivery(false,true,0)); // old Pro menu can still close during migration
    static_assert(!pro_delivery(false,true,1));
    static_assert(!pro_delivery(false,false,0));
    // GamePad state (mode 1), now playing with the Pro Controller: switch the game to the Pro Controller
    static_assert(needed_category(1, true) == 0);
    // Off-TV GamePad play (mode 2) as well
    static_assert(needed_category(2, true) == 0);
    // Pro Controller state (mode 0), now playing with the GamePad: switch the game to the GamePad
    static_assert(needed_category(0, false) == 1);
    // same-controller loads: nothing changes
    static_assert(needed_category(0, true) == -1);
    static_assert(needed_category(1, false) == -1);
    static_assert(needed_category(2, false) == -1);
    // boot, title and file select (both), no manager yet (-1) or no controller (4): the game picks itself
    for (int mode : {-1, 3, 4, 5})
        for (bool pro : {false, true}) assert(needed_category(mode, pro) == -1);
    // Issue #330, GamePad -> Pro Controller: the GamePad stays live until the game's mode has followed
    using controller_reapply::keeps_gamepad;
    using controller_reapply::may_give_up;
    static_assert(keeps_gamepad(true, 1, true, -1));   // waiting for play (pause menu, file select)
    static_assert(keeps_gamepad(true, 2, true, -1));   // Off-TV GamePad play as well
    static_assert(!keeps_gamepad(true, 1, true, 0));   // the menu path is switching it: idle
    static_assert(!keeps_gamepad(true, 0, true, -1));  // the game follows: released
    static_assert(!keeps_gamepad(false, 1, true, -1)); // re-apply over (done, given up): released
    static_assert(!keeps_gamepad(true, 1, false, -1)); // switched back to the GamePad: nothing to keep
    static_assert(!keeps_gamepad(true, 0, false, 1));  // Pro Controller -> GamePad is holds_pro_controller's
    for (int mode : {-1, 3, 4})                        // title, boot, no manager: the game picks for itself
        assert(!keeps_gamepad(true, mode, true, -1));
    // without an in-game UI: the file select waits for the player's press, the title gives up
    static_assert(!may_give_up(true, 100000, 3600));
    static_assert(!may_give_up(false, 3600, 3600));
    static_assert(may_give_up(false, 3601, 3600));
    puts("controller re-apply decision: cross-controller loads switch the game, same-controller loads and title scenes do not");
    puts("GamePad -> Pro Controller: the GamePad stays live until the game's mode follows, never past the switch");
}
