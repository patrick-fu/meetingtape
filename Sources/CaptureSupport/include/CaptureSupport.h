#ifndef MEETINGTAPE_CAPTURE_SUPPORT_H
#define MEETINGTAPE_CAPTURE_SUPPORT_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct MTStreamOpaque *MTStreamRef;

typedef enum {
    MTCaptureSystem = 0,
    MTCaptureMicrophone = 1
} MTCaptureSource;

typedef enum {
    MTCaptureNoError = 0,
    MTCaptureOverflow = 1,
    MTCaptureInvalidLayout = 2,
    MTCaptureInvalidTimestamp = 3,
    MTCaptureNonfiniteSample = 4,
    MTCaptureConcurrentCallback = 5
} MTCaptureCallbackError;

typedef struct {
    uint64_t hostTime;
    uint64_t generation;
    double sampleRate;
    uint32_t frames;
    uint32_t channels;
} MTChunkInfo;

typedef struct {
    MTCaptureCallbackError callbackError;
    double secondsSinceCallback;
    bool receivedAudio;
    bool configurationChanged;
} MTStreamStatus;

MTStreamRef MTStreamCreate(MTCaptureSource source, uint64_t generation, bool *cleanupFailed, char *error, size_t errorCapacity);
bool MTStreamPeek(MTStreamRef stream, MTChunkInfo *info);
bool MTStreamRead(MTStreamRef stream, float *samples, uint32_t sampleCapacity, MTChunkInfo *info);
MTStreamStatus MTStreamPoll(MTStreamRef stream);
bool MTStreamNeedsRefresh(MTStreamRef stream);
void MTStreamQuiesce(MTStreamRef stream);
bool MTStreamStop(MTStreamRef stream, char *error, size_t errorCapacity);
void MTStreamDestroy(MTStreamRef stream);

#endif
