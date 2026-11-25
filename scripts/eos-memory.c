#include <stddef.h>

/*
 * PortningsbolagetMemory obtains these three pointers and passes them together
 * to EOS_Initialize. The EOS desktop SDK selects its own allocator when all
 * three callbacks are null. There is no allocator state to initialize.
 */
void Init(void) {}
void *GetAllocateFunctionPointer(void) { return NULL; }
void *GetReallocateFunctionPointer(void) { return NULL; }
void *GetReleaseFunctionPointer(void) { return NULL; }
