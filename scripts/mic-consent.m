// Built into the macOS player. No callback retains a Recorder or invokes managed code.
#include <stdint.h>
#include <stdatomic.h>
#include <stdbool.h>

enum Permission { Blocked = -1, Pending = 0, Authorized = 1 };
static atomic_int completion = ATOMIC_VAR_INIT(Pending);
static atomic_bool requesting = ATOMIC_VAR_INIT(false);

static void completed(bool granted) {
    atomic_store_explicit(&completion, granted ? Authorized : Blocked, memory_order_release);
    atomic_store_explicit(&requesting, false, memory_order_release);
}

#ifdef PEAK_MIC_FIXTURE
// The fixture supplies the same three AVFoundation states without changing TCC.
static int fixture_permission;
static int fixture_requests;
static int authorization(void) { return fixture_permission; }
static void request_async(void) { ++fixture_requests; }
void test_state(int value) { fixture_permission = value; }
void test_complete(int granted) { fixture_permission = granted ? Authorized : Blocked; completed(granted != 0); }
int test_requests(void) { return fixture_requests; }
#else
#import <AVFoundation/AVFoundation.h>
#import <dispatch/dispatch.h>

static int authorization(void) {
    switch ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]) {
        case AVAuthorizationStatusAuthorized: return Authorized;
        case AVAuthorizationStatusNotDetermined: return Pending;
        default: return Blocked;
    }
}

static void request_async(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
            completed(granted);
        }];
    });
}
#endif

int peak_mic_may_start(int32_t source_type, int32_t *waiting) {
    // Photon 3.1 InputSourceType.Microphone == 0. Clips and factories need no permission.
    *waiting = 0;
    if (source_type != 0) return 1;
    int status = authorization();
    if (status != Pending) return status == Authorized;

    *waiting = 1;
    bool expected = false;
    if (atomic_compare_exchange_strong_explicit(&requesting, &expected, true,
                                                memory_order_acq_rel, memory_order_acquire)) {
        atomic_store_explicit(&completion, Pending, memory_order_release);
        request_async();
    }
    return 0;
}

int peak_mic_take_grant(int32_t *waiting) {
    int status = atomic_load_explicit(&completion, memory_order_acquire);
    if (status == Pending) return 0;
    *waiting = 0;
    return status == Authorized;
}
