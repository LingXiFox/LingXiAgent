/*
 * LingXi plugin ABI, major version 1.
 *
 * Published contract for plugin authors. A plugin exports exactly one symbol:
 *
 *   int32_t LingXiPlugin_Init(const LingXiHostAPI* hostAPI,
 *                             uint32_t hostABIMajor,
 *                             const LingXiPluginAPI** outAPI,
 *                             uint32_t* outABIMajor,
 *                             LingXiStatus* outStatus);
 *
 * Every call returns int32_t (0 = accepted) and reports the reason through an explicit
 * LingXiStatus out-parameter. A status is three integers and carries no pointers, so it is
 * representable in C, Swift and Objective-C without ownership rules of its own. Human-readable
 * failure text travels in JSON reply bodies, which already have one owner.
 *
 * Rules that are not negotiable (Plugin-System-Design.md §3.2):
 *   1. Every struct crossing the boundary begins with structSize then abiMajor. The host reads
 *      structSize to decide which trailing fields exist; new fields are always appended.
 *   2. Only fixed-width integers, pointers, (const uint8_t* + uint32_t length) UTF-8 buffers that
 *      are NOT nul-terminated, and function-pointer tables cross the boundary. No Swift or C++
 *      types, no exceptions, no standard-library containers.
 *   3. Ownership is explicit: argument buffers are valid only for the duration of the call; copy
 *      what you must keep. A returned buffer is allocated by the callee and freed by the caller
 *      through the table's `free`.
 *   4. An ABI major mismatch is a hard failure with a named status. Never a silent downgrade.
 *   5. A plugin calls back into the host only through LingXiHostAPI, and never spawns a thread
 *      that touches host state directly.
 *   6. Lifecycle order is Init -> Start -> (run) -> Stop -> Dispose. dlclose happens only with no
 *      call in flight.
 *
 * The Swift definitions in LingXiPluginABI/ABITypes.swift are the same layout, and ContractTests
 * pin the sizes and offsets recorded in ABI-MANIFEST.
 */
#ifndef LINGXI_PLUGIN_ABI_H
#define LINGXI_PLUGIN_ABI_H

#include <stdint.h>

#define LX_ABI_MAJOR 1u
#define LX_ENTRY_SYMBOL "LingXiPlugin_Init"

/* Codes mirror the kernel fault taxonomy in Plugin-System-Design.md §六. */
typedef enum {
    LX_OK = 0,
    LX_CAPABILITY_FAILED = 1,
    LX_PROTOCOL_VIOLATION = 2,
    LX_ABI_VIOLATION = 3,
    LX_PERMISSION_VIOLATION = 4,
    LX_TIMEOUT = 5,
    LX_UNRESPONSIVE = 6,
    LX_CRASHED = 7,
    LX_METHOD_NOT_IMPLEMENTED = 8,
    LX_NOT_STARTED = 9
} LingXiStatusCode;

/* Scalar-only: no pointers, so the struct is C-representable everywhere. */
typedef struct {
    uint32_t structSize;
    uint32_t abiMajor;
    int32_t code;
} LingXiStatus;

typedef struct {
    uint32_t structSize;
    uint32_t abiMajor;
    /* Identity and declared capabilities, as UTF-8 JSON. Callee allocates, caller frees. */
    int32_t (*describe)(uint8_t** out, uint32_t* outLength);
    int32_t (*start)(const uint8_t* grantedJson, uint32_t grantedLength, LingXiStatus* outStatus);
    int32_t (*stop)(void);
    int32_t (*dispose)(void);
    int32_t (*invoke)(const char* capability,
                      const uint8_t* payload, uint32_t payloadLength,
                      uint8_t** outReply, uint32_t* outReplyLength,
                      LingXiStatus* outStatus);
    int32_t (*cancel)(const char* requestID);
    void (*free)(void* buffer);
} LingXiPluginAPI;

typedef struct {
    uint32_t structSize;
    uint32_t abiMajor;
    void (*log)(int32_t level, const uint8_t* text, uint32_t length);
    void (*emit)(const char* event, const uint8_t* payload, uint32_t payloadLength);
} LingXiHostAPI;

typedef int32_t (*LingXiPluginInitFn)(const LingXiHostAPI* hostAPI,
                                      uint32_t hostABIMajor,
                                      const LingXiPluginAPI** outAPI,
                                      uint32_t* outABIMajor,
                                      LingXiStatus* outStatus);

#endif /* LINGXI_PLUGIN_ABI_H */
