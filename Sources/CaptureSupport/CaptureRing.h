#ifndef MEETINGTAPE_CAPTURE_RING_H
#define MEETINGTAPE_CAPTURE_RING_H

#include "include/CaptureSupport.h"
#include <CoreAudio/CoreAudioTypes.h>
#include <stdatomic.h>

typedef struct {
    MTChunkInfo info;
    uint64_t firstFrame;
} MTQueuedChunk;

typedef struct {
    float *samples;
    MTQueuedChunk *chunks;
    uint32_t capacity;
    uint32_t channels;
    bool interleaved;
    double sampleRate;
    uint64_t generation;
    uint64_t previousHostTime;
    _Atomic(uint64_t) writtenFrames;
    _Atomic(uint64_t) readFrames;
    _Atomic(uint64_t) writtenChunks;
    _Atomic(uint64_t) readChunks;
    _Atomic(uint64_t) lastHostTime;
    _Atomic(int) fatalError;
    _Atomic(bool) accepting;
    _Atomic(bool) configurationChanged;
    atomic_flag producing;
} MTCaptureRing;

bool MTRingInitialize(MTCaptureRing *ring, const AudioStreamBasicDescription *format, uint64_t generation);
void MTRingDestroy(MTCaptureRing *ring);
void MTRingPush(MTCaptureRing *ring, const AudioBufferList *buffers, uint32_t frames, uint64_t hostTime, bool validHostTime);
bool MTRingPeek(MTCaptureRing *ring, MTChunkInfo *info);
bool MTRingRead(MTCaptureRing *ring, float *samples, uint32_t sampleCapacity, MTChunkInfo *info);

#endif
