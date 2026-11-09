#include <stdint.h>

typedef struct {
    int64_t global_frame_counter;
    int64_t view_frame_counter;
    int64_t presentation_time;
    float refresh_rate;
    int flags;
    unsigned int sequence;
    int64_t kms_ready_time_us;
} ClutterFrameInfo;

static float seen;

void clutter_stage_view_notify_presented(void *view, ClutterFrameInfo *info)
{
    (void)view;
    seen = info->refresh_rate;
}

void clutter_frame_clock_notify_presented(void *clock, ClutterFrameInfo *info)
{
    (void)clock;
    seen = info->refresh_rate;
}

float stub_seen(void)
{
    return seen;
}
