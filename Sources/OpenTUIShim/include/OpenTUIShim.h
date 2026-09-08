#ifndef OPENTUI_SHIM_H
#define OPENTUI_SHIM_H

#include <stdbool.h>
#include <stdint.h>

typedef uint32_t OpenTUIHandle;

typedef struct {
    uint16_t red;
    uint16_t green;
    uint16_t blue;
    uint16_t alpha;
} OpenTUIColor;

bool opentui_load(const char *path);
const char *opentui_last_error(void);
void opentui_unload(void);

OpenTUIHandle opentui_create_renderer(uint32_t width, uint32_t height);
void opentui_destroy_renderer(OpenTUIHandle renderer);
void opentui_setup_terminal(OpenTUIHandle renderer);
void opentui_enable_mouse(OpenTUIHandle renderer);
void opentui_disable_mouse(OpenTUIHandle renderer);
void opentui_restore_terminal_modes(OpenTUIHandle renderer);
uint8_t opentui_render(OpenTUIHandle renderer, bool force);
void opentui_resize_renderer(OpenTUIHandle renderer, uint32_t width, uint32_t height);
OpenTUIHandle opentui_next_buffer(OpenTUIHandle renderer);
OpenTUIHandle opentui_current_buffer(OpenTUIHandle renderer);

void opentui_clear_buffer(OpenTUIHandle buffer, OpenTUIColor color);
void opentui_draw_text(OpenTUIHandle buffer, const char *text, uint32_t length,
                       uint32_t x, uint32_t y, OpenTUIColor foreground,
                       OpenTUIColor background);
void opentui_set_cursor(OpenTUIHandle renderer, int32_t x, int32_t y, bool visible);
uint32_t opentui_buffer_width(OpenTUIHandle buffer);
uint32_t opentui_buffer_height(OpenTUIHandle buffer);

#endif
