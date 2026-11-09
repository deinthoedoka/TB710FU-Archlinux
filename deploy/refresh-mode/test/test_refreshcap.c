#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    int64_t global_frame_counter;
    int64_t view_frame_counter;
    int64_t presentation_time;
    float refresh_rate;
    int flags;
    unsigned int sequence;
    int64_t kms_ready_time_us;
} ClutterFrameInfo;

extern float stub_seen(void);

int main(int argc, char **argv)
{
    const char *name = argc > 1 ? argv[1] : "frame";
    void (*notify)(void *, ClutterFrameInfo *);
    ClutterFrameInfo info = {0};

    if (strcmp(name, "stage") == 0)
        notify = (void (*)(void *, ClutterFrameInfo *))dlsym(
            RTLD_DEFAULT, "clutter_stage_view_notify_presented");
    else
        notify = (void (*)(void *, ClutterFrameInfo *))dlsym(
            RTLD_DEFAULT, "clutter_frame_clock_notify_presented");
    if (!notify) {
        puts("symbol-not-found");
        return 2;
    }
    info.refresh_rate = 120.0f;
    notify(NULL, &info);
    printf("path=%s stub_seen=%.2f\n", name, stub_seen());
    return 0;
}
