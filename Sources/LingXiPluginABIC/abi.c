/* The ABI target exists so the contract structs are C types, not Swift ones: a pointer to a Swift
 * struct is not representable in a @convention(c) type, which is precisely the trap a published
 * plugin ABI must not have. This translation unit only anchors the header into the target. */
#include "lingxi_plugin_abi.h"

uint32_t lingxi_abi_major(void) { return LX_ABI_MAJOR; }
