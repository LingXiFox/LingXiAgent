#include "OpenTUIShim.h"

#include <stdio.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#define NOGDI
#define NOUSER
#include <windows.h>
#undef SetCursor
#undef DrawText
static HMODULE image;
#define DLOPEN(p) LoadLibraryA(p)
#define DLSYM(h, n) (void *)GetProcAddress(h, n)
#define DLCLOSE(h) FreeLibrary(h)
#define DLERROR() "LoadLibrary failed"
#else
#include <dlfcn.h>
static void *image;
#define DLOPEN(p) dlopen(p, RTLD_NOW | RTLD_LOCAL)
#define DLSYM(h, n) dlsym(h, n)
#define DLCLOSE(h) dlclose(h)
#define DLERROR() dlerror()
#endif

static char error_message[256];

static void *symbol(const char *name) {
    void *value = DLSYM(image, name);
    if (!value) {
        snprintf(error_message, sizeof(error_message), "missing OpenTUI symbol: %s", name);
    }
    return value;
}

bool opentui_load(const char *path) {
    if (image) return true;

    const char *candidates[] = {
#if defined(_WIN32)
        path,
        "Vendor\\OpenTUI\\0.5.10\\opentui.dll",
        "opentui.dll"
#elif defined(__APPLE__)
        path,
        "Vendor/OpenTUI/0.5.10/libopentui.dylib",
        "/usr/local/lib/libopentui.dylib",
        "libopentui.dylib"
#else // Linux / POSIX
        path,
        "Vendor/OpenTUI/0.5.10/libopentui.so",
        "/usr/local/lib/libopentui.so",
        "/usr/lib/libopentui.so",
        "libopentui.so"
#endif
    };

    for (size_t i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        const char *candidate = candidates[i];
        if (!candidate || !candidate[0]) continue;
        image = DLOPEN(candidate);
        if (image) break;
    }

    if (!image) {
        snprintf(error_message, sizeof(error_message), "OpenTUI dynamic load failed: %s", DLERROR());
        return false;
    }

    const char *required[] = {
        "createRenderer", "destroyRenderer", "render", "resizeRenderer",
        "getNextBuffer", "getCurrentBuffer", "bufferClear", "bufferDrawText",
        "getBufferWidth", "getBufferHeight", "setCursorPosition",
        "setupTerminal", "enableMouse", "disableMouse", "restoreTerminalModes"
    };
    for (size_t index = 0; index < sizeof(required) / sizeof(required[0]); index++) {
        if (!DLSYM(image, required[index])) {
            snprintf(error_message, sizeof(error_message), "missing OpenTUI symbol: %s", required[index]);
            DLCLOSE(image);
            image = NULL;
            return false;
        }
    }
    return true;
}

const char *opentui_last_error(void) { return error_message; }

void opentui_unload(void) {
    if (image) DLCLOSE(image);
    image = NULL;
}

#define FN(name, type) ((type)symbol(name))
typedef OpenTUIHandle (*OpenTUI_FN_CreateRenderer)(uint32_t, uint32_t, uint8_t, uint8_t, void *);
typedef void (*OpenTUI_FN_DestroyRenderer)(OpenTUIHandle, bool);
typedef void (*OpenTUI_FN_SetupTerminal)(OpenTUIHandle, bool);
typedef void (*OpenTUI_FN_EnableMouse)(OpenTUIHandle, bool);
typedef void (*OpenTUI_FN_DisableMouse)(OpenTUIHandle);
typedef void (*OpenTUI_FN_RestoreTerminalModes)(OpenTUIHandle);
typedef uint8_t (*OpenTUI_FN_Render)(OpenTUIHandle, bool);
typedef void (*OpenTUI_FN_ResizeRenderer)(OpenTUIHandle, uint32_t, uint32_t);
typedef OpenTUIHandle (*OpenTUI_FN_GetBuffer)(OpenTUIHandle);
typedef void (*OpenTUI_FN_ClearBuffer)(OpenTUIHandle, OpenTUIColor *);
typedef void (*OpenTUI_FN_DrawText)(OpenTUIHandle, const char *, uint32_t, uint32_t, uint32_t,
                                    OpenTUIColor *, OpenTUIColor *, uint32_t);
typedef uint32_t (*OpenTUI_FN_BufferSize)(OpenTUIHandle);
typedef void (*OpenTUI_FN_SetCursor)(OpenTUIHandle, int32_t, int32_t, bool);

OpenTUIHandle opentui_create_renderer(uint32_t width, uint32_t height) {
    return FN("createRenderer", OpenTUI_FN_CreateRenderer)(width, height, 0, 1, NULL);
}

void opentui_destroy_renderer(OpenTUIHandle renderer) {
    FN("destroyRenderer", OpenTUI_FN_DestroyRenderer)(renderer, false);
}

void opentui_setup_terminal(OpenTUIHandle renderer) {
    FN("setupTerminal", OpenTUI_FN_SetupTerminal)(renderer, true);
}

void opentui_enable_mouse(OpenTUIHandle renderer) {
    FN("enableMouse", OpenTUI_FN_EnableMouse)(renderer, false);
}

void opentui_disable_mouse(OpenTUIHandle renderer) {
    FN("disableMouse", OpenTUI_FN_DisableMouse)(renderer);
}

void opentui_restore_terminal_modes(OpenTUIHandle renderer) {
    FN("restoreTerminalModes", OpenTUI_FN_RestoreTerminalModes)(renderer);
}

uint8_t opentui_render(OpenTUIHandle renderer, bool force) {
    return FN("render", OpenTUI_FN_Render)(renderer, force);
}

void opentui_resize_renderer(OpenTUIHandle renderer, uint32_t width, uint32_t height) {
    FN("resizeRenderer", OpenTUI_FN_ResizeRenderer)(renderer, width, height);
}

OpenTUIHandle opentui_next_buffer(OpenTUIHandle renderer) {
    return FN("getNextBuffer", OpenTUI_FN_GetBuffer)(renderer);
}

OpenTUIHandle opentui_current_buffer(OpenTUIHandle renderer) {
    return FN("getCurrentBuffer", OpenTUI_FN_GetBuffer)(renderer);
}

void opentui_clear_buffer(OpenTUIHandle buffer, OpenTUIColor color) {
    FN("bufferClear", OpenTUI_FN_ClearBuffer)(buffer, &color);
}

void opentui_draw_text(OpenTUIHandle buffer, const char *text, uint32_t length,
                       uint32_t x, uint32_t y, OpenTUIColor foreground,
                       OpenTUIColor background) {
    FN("bufferDrawText", OpenTUI_FN_DrawText)(buffer, text, length, x, y, &foreground, &background, 0);
}

void opentui_set_cursor(OpenTUIHandle renderer, int32_t x, int32_t y, bool visible) {
    FN("setCursorPosition", OpenTUI_FN_SetCursor)(renderer, x, y, visible);
}

uint32_t opentui_buffer_width(OpenTUIHandle buffer) {
    return FN("getBufferWidth", OpenTUI_FN_BufferSize)(buffer);
}

uint32_t opentui_buffer_height(OpenTUIHandle buffer) {
    return FN("getBufferHeight", OpenTUI_FN_BufferSize)(buffer);
}
