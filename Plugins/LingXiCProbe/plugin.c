/* A plugin written in plain C against the published header. Its job in the test suite is to prove
 * the ABI is genuinely cross-language: same table layout, same ownership rule, same JSON payloads. */
#include "lingxi_plugin_abi.h"

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int32_t emit_bytes(const char *text, uint8_t **out, uint32_t *outLength) {
    size_t length = strlen(text);
    uint8_t *buffer = (uint8_t *)malloc(length);
    if (buffer == NULL) { return -1; }
    memcpy(buffer, text, length);
    *out = buffer;
    *outLength = (uint32_t)length;
    return 0;
}

static int32_t probe_describe(uint8_t **out, uint32_t *outLength) {
    static const char *identity =
        "{\"bundleID\":\"site.lingxi.plugin.cprobe\",\"version\":\"1.0.0\","
        "\"hooks\":[{\"id\":\"cProbe\",\"node\":\"contextPrepare\",\"priority\":60,\"canVeto\":true}]}";
    return emit_bytes(identity, out, outLength);
}

static int crash_on_next_invocation = 0;
static volatile int slow_mode = 0;
static volatile int cancelled_flag = 0;

static int32_t probe_start(const uint8_t *granted, uint32_t grantedLength, LingXiStatus *status) {
    /* test-only fault injection: the host passes the granted set at start */
    if (granted != NULL && grantedLength > 0) {
        char probe[128] = {0};
        uint32_t copy = grantedLength < sizeof(probe) - 1 ? grantedLength : (uint32_t)(sizeof(probe) - 1);
        memcpy(probe, granted, copy);
        if (strstr(probe, "fault.crash") != NULL) { crash_on_next_invocation = 1; }
        if (strstr(probe, "fault.slow") != NULL) { slow_mode = 1; }
    }
    status->code = LX_OK;
    return 0;
}

static int32_t probe_stop(void) { return 0; }
static int32_t probe_dispose(void) { return 0; }

static int32_t probe_invoke(const char *requestID,
                            const char *capability,
                            const uint8_t *payload, uint32_t payloadLength,
                            uint8_t **outReply, uint32_t *outReplyLength,
                            LingXiStatus *status) {
    (void)payload;
    (void)payloadLength;
    (void)requestID;
    if (slow_mode) {
        for (int waited = 0; waited < 2000; waited += 20) {
            if (cancelled_flag) { cancelled_flag = 0; status->code = LX_CANCELLED; return -1; }
            usleep(20000);
        }
    }
    if (crash_on_next_invocation) {
        crash_on_next_invocation = 0;
        abort(); /* the plugin dies inside its host, exactly as a segfault would */
    }
    if (capability == NULL || strcmp(capability, "hook.cProbe") != 0) {
        status->code = LX_METHOD_NOT_IMPLEMENTED;
        return -1;
    }
    static const char *reply =
        "{\"verdict\":\"rewrite\",\"injections\":[{\"id\":\"cprobe.marker\","
        "\"text\":\"[c-probe] context rewritten by a C plugin\",\"segment\":\"derivedPage\"}]}";
    if (emit_bytes(reply, outReply, outReplyLength) != 0) {
        status->code = LX_CAPABILITY_FAILED;
        return -1;
    }
    status->code = LX_OK;
    return 0;
}

static int32_t probe_cancel(const char *requestID) {
    (void)requestID;
    cancelled_flag = 1;
    return 0;
}

static void probe_free(void *buffer) { free(buffer); }

static const LingXiPluginAPI probe_api = {
    sizeof(LingXiPluginAPI),
    LX_ABI_MAJOR,
    probe_describe,
    probe_start,
    probe_stop,
    probe_dispose,
    probe_invoke,
    probe_cancel,
    probe_free
};

__attribute__((visibility("default")))
int32_t LingXiPlugin_Init(const LingXiHostAPI *hostAPI,
                          uint32_t hostABIMajor,
                          const LingXiPluginAPI **outAPI,
                          uint32_t *outABIMajor,
                          LingXiStatus *outStatus) {
    (void)hostAPI;
    outStatus->structSize = sizeof(LingXiStatus);
    outStatus->abiMajor = LX_ABI_MAJOR;
    outStatus->code = LX_OK;
    if (hostABIMajor != LX_ABI_MAJOR) {
        outStatus->code = LX_ABI_VIOLATION;
        return -1;
    }
    if (outAPI == NULL || outABIMajor == NULL) {
        outStatus->code = LX_ABI_VIOLATION;
        return -1;
    }
    *outAPI = &probe_api;
    *outABIMajor = LX_ABI_MAJOR;
    return 0;
}
