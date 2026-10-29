// Placeholder scene: a board background and an animated cursor moved with the D-pad.
// Exists to prove the art pipeline (graphics/*.bmp + *.json -> bn::*_items) works end to end.

#include "bn_core.h"
#include "bn_keypad.h"
#include "bn_regular_bg_ptr.h"
#include "bn_sprite_animate_actions.h"
#include "bn_sprite_ptr.h"

#include "bn_regular_bg_items_board.h"
#include "bn_sprite_items_cursor.h"

int main()
{
    bn::core::init();

    bn::regular_bg_ptr board = bn::regular_bg_items::board.create_bg(0, 0);
    bn::sprite_ptr cursor = bn::sprite_items::cursor.create_sprite(0, 40);

    // cursor.bmp holds 4 stacked 16x16 frames; advance one frame every 8 screen refreshes.
    bn::sprite_animate_action<4> cursor_animation = bn::create_sprite_animate_action_forever(
            cursor, 8, bn::sprite_items::cursor.tile_item(), 0, 1, 2, 3);

    while(true)
    {
        if(bn::keypad::left_held())
        {
            cursor.set_x(cursor.x() - 1);
        }
        else if(bn::keypad::right_held())
        {
            cursor.set_x(cursor.x() + 1);
        }

        if(bn::keypad::up_held())
        {
            cursor.set_y(cursor.y() - 1);
        }
        else if(bn::keypad::down_held())
        {
            cursor.set_y(cursor.y() + 1);
        }

        cursor_animation.update();
        bn::core::update();
    }
}
