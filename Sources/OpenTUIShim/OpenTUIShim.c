#include "OpenTUIShim.h"

#include <dlfcn.h>
#include <stdio.h>

static void *image;
static char error_message[256];

static void *symbol(const char *name) {
    void *value = dlsym(image, name);
    if (!value) {
        snprintf(error_message, sizeof(error_message), "missing OpenTUI symbol: %s", name);
    }
    return value;
}

bool opentui_load(const char *path) {
    if (image) return true;
    const char *library = path;
    if (!library || !library[0]) library = "Vendor/OpenTUI/0.5.10/libopentui.dylib";
    image = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (!image) {
        snprintf(error_message, sizeof(error_message), "OpenTUI dlopen failed: %s", dlerror());
        return false;
    }
    const char *required[] = {
        "createRenderer", "destroyRenderer", "render", "resizeRenderer",
        "getNextBuffer", "getCurrentBuffer", "bufferClear", "bufferDrawText",
        "getBufferWidth", "getBufferHeight", "setCursorPosition",
        "setupTerminal", "enableMouse", "disableMouse", "restoreTerminalModes"
    };
    for (size_t index = 0; index < sizeof(required) / sizeof(required[0]); index++) {
        if (!dlsym(image, required[index])) {
            snprintf(error_message, sizeof(error_message), "missing OpenTUI symbol: %s", required[index]);
            dlclose(image);
            image = NULL;
            return false;
        }
    }
    return true;
}

const char *opentui_last_error(void) { return error_message; }

void opentui_unload(void) {
    if (image) dlclose(image);
    image = NULL;
}

#define FN(name, type) ((type)symbol(name))
typedef OpenTUIHandle (*CreateRenderer)(uint32_t, uint32_t, uint8_t, uint8_t, void *);
typedef void (*DestroyRenderer)(OpenTUIHandle, bool);
typedef void (*SetupTerminal)(OpenTUIHandle, bool);
typedef void (*EnableMouse)(OpenTUIHandle, bool);
typedef void (*DisableMouse)(OpenTUIHandle);
typedef void (*RestoreTerminalModes)(OpenTUIHandle);
typedef uint8_t (*Render)(OpenTUIHandle, bool);
typedef void (*ResizeRenderer)(OpenTUIHandle, uint32_t, uint32_t);
typedef OpenTUIHandle (*GetBuffer)(OpenTUIHandle);
typedef void (*ClearBuffer)(OpenTUIHandle, OpenTUIColor *);
typedef void (*DrawText)(OpenTUIHandle, const char *, uint32_t, uint32_t, uint32_t,
                         OpenTUIColor *, OpenTUIColor *, uint32_t);
typedef uint32_t (*BufferSize)(OpenTUIHandle);
typedef void (*SetCursor)(OpenTUIHandle, int32_t, int32_t, bool);

OpenTUIHandle opentui_create_renderer(uint32_t width, uint32_t height) {
    return FN("createRenderer", CreateRenderer)(width, height, 0, 1, NULL);
}

void opentui_destroy_renderer(OpenTUIHandle renderer) {
    FN("destroyRenderer", DestroyRenderer)(renderer, false);
}

void opentui_setup_terminal(OpenTUIHandle renderer) {
    FN("setupTerminal", SetupTerminal)(renderer, true);
}

void opentui_enable_mouse(OpenTUIHandle renderer) {
    FN("enableMouse", EnableMouse)(renderer, false);
}

void opentui_disable_mouse(OpenTUIHandle renderer) {
    FN("disableMouse", DisableMouse)(renderer);
}

void opentui_restore_terminal_modes(OpenTUIHandle renderer) {
    FN("restoreTerminalModes", RestoreTerminalModes)(renderer);
}

uint8_t opentui_render(OpenTUIHandle renderer, bool force) {
    return FN("render", Render)(renderer, force);
}

void opentui_resize_renderer(OpenTUIHandle renderer, uint32_t width, uint32_t height) {
    FN("resizeRenderer", ResizeRenderer)(renderer, width, height);
}

OpenTUIHandle opentui_next_buffer(OpenTUIHandle renderer) {
    return FN("getNextBuffer", GetBuffer)(renderer);
}

OpenTUIHandle opentui_current_buffer(OpenTUIHandle renderer) {
    return FN("getCurrentBuffer", GetBuffer)(renderer);
}

void opentui_clear_buffer(OpenTUIHandle buffer, OpenTUIColor color) {
    FN("bufferClear", ClearBuffer)(buffer, &color);
}

void opentui_draw_text(OpenTUIHandle buffer, const char *text, uint32_t length,
                       uint32_t x, uint32_t y, OpenTUIColor foreground,
                       OpenTUIColor background) {
    FN("bufferDrawText", DrawText)(buffer, text, length, x, y, &foreground, &background, 0);
}

void opentui_set_cursor(OpenTUIHandle renderer, int32_t x, int32_t y, bool visible) {
    FN("setCursorPosition", SetCursor)(renderer, x, y, visible);
}

uint32_t opentui_buffer_width(OpenTUIHandle buffer) {
    return FN("getBufferWidth", BufferSize)(buffer);
}

uint32_t opentui_buffer_height(OpenTUIHandle buffer) {
    return FN("getBufferHeight", BufferSize)(buffer);
}
