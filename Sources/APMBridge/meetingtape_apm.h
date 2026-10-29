#ifndef MEETINGTAPE_APM_H
#define MEETINGTAPE_APM_H

#define MEETINGTAPE_APM_SAMPLE_RATE 48000
#define MEETINGTAPE_APM_FRAME_COUNT 480

#ifdef __cplusplus
extern "C" {
#endif

typedef struct meetingtape_apm meetingtape_apm;

meetingtape_apm *_Nullable meetingtape_apm_create(void);
void meetingtape_apm_destroy(meetingtape_apm *_Nullable processor);
int meetingtape_apm_digital_3a_enabled(const meetingtape_apm *_Nonnull processor);
int meetingtape_apm_process(
    meetingtape_apm *_Nonnull processor,
    const float *_Nonnull microphone,
    const float *_Nonnull reference_left,
    const float *_Nonnull reference_right,
    int frame_count,
    int delay_milliseconds,
    float *_Nonnull output);

#ifdef __cplusplus
}
#endif

#endif
