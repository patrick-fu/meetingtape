#include "CaptureRing.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "Capture requires lock-free 64-bit atomics");

static void MTRingFail(MTCaptureRing *ring, MTCaptureCallbackError error) {
    int expected = MTCaptureNoError;
    atomic_compare_exchange_strong_explicit(&ring->fatalError, &expected, error, memory_order_release, memory_order_relaxed);
}

bool MTRingInitialize(MTCaptureRing *ring, const AudioStreamBasicDescription *format, uint64_t generation) {
    memset(ring, 0, sizeof(*ring));
    bool interleaved = (format->mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0;
    if (format->mFormatID != kAudioFormatLinearPCM ||
        !(format->mFormatFlags & kAudioFormatFlagIsFloat) ||
        !(format->mFormatFlags & kAudioFormatFlagIsPacked) ||
        (format->mFormatFlags & kAudioFormatFlagIsBigEndian) ||
        format->mBitsPerChannel != 32 || format->mFramesPerPacket != 1 ||
        format->mChannelsPerFrame < 1 || format->mChannelsPerFrame > 2 ||
        format->mBytesPerFrame != sizeof(float) * (interleaved ? format->mChannelsPerFrame : 1) ||
        !isfinite(format->mSampleRate) || format->mSampleRate < 8000 || format->mSampleRate > 192000) {
        return false;
    }
    ring->capacity = (uint32_t)floor(format->mSampleRate);
    ring->channels = format->mChannelsPerFrame;
    ring->interleaved = interleaved;
    ring->sampleRate = format->mSampleRate;
    ring->generation = generation;
    ring->samples = calloc((size_t)ring->capacity * ring->channels, sizeof(float));
    ring->chunks = calloc(ring->capacity, sizeof(MTQueuedChunk));
    atomic_init(&ring->writtenFrames, 0);
    atomic_init(&ring->readFrames, 0);
    atomic_init(&ring->writtenChunks, 0);
    atomic_init(&ring->readChunks, 0);
    atomic_init(&ring->lastHostTime, 0);
    atomic_init(&ring->fatalError, MTCaptureNoError);
    atomic_init(&ring->accepting, false);
    atomic_init(&ring->configurationChanged, false);
    atomic_flag_clear(&ring->producing);
    if (!ring->samples || !ring->chunks) {
        MTRingDestroy(ring);
        return false;
    }
    return true;
}

void MTRingDestroy(MTCaptureRing *ring) {
    free(ring->samples);
    free(ring->chunks);
    ring->samples = NULL;
    ring->chunks = NULL;
}

void MTRingPush(MTCaptureRing *ring, const AudioBufferList *buffers, uint32_t frames, uint64_t hostTime, bool validHostTime) {
    if (!atomic_load_explicit(&ring->accepting, memory_order_acquire) ||
        atomic_load_explicit(&ring->configurationChanged, memory_order_acquire)) {
        return;
    }
    if (atomic_flag_test_and_set_explicit(&ring->producing, memory_order_acquire)) {
        MTRingFail(ring, MTCaptureConcurrentCallback);
        return;
    }
    if (atomic_load_explicit(&ring->fatalError, memory_order_relaxed) != MTCaptureNoError) {
        goto done;
    }
    if (!validHostTime || !hostTime || hostTime <= ring->previousHostTime) {
        MTRingFail(ring, MTCaptureInvalidTimestamp);
        goto done;
    }
    if (!buffers || buffers->mNumberBuffers != (ring->interleaved ? 1 : ring->channels)) {
        MTRingFail(ring, MTCaptureInvalidLayout);
        goto done;
    }
    if (frames == 0) {
        goto done;
    }
    for (uint32_t i = 0; i < buffers->mNumberBuffers; ++i) {
        uint32_t channels = ring->interleaved ? ring->channels : 1;
        if (!buffers->mBuffers[i].mData || buffers->mBuffers[i].mNumberChannels != channels ||
            buffers->mBuffers[i].mDataByteSize != (uint64_t)frames * channels * sizeof(float)) {
            MTRingFail(ring, MTCaptureInvalidLayout);
            goto done;
        }
    }
    uint64_t writtenFrames = atomic_load_explicit(&ring->writtenFrames, memory_order_relaxed);
    uint64_t readFrames = atomic_load_explicit(&ring->readFrames, memory_order_acquire);
    uint64_t writtenChunks = atomic_load_explicit(&ring->writtenChunks, memory_order_relaxed);
    uint64_t readChunks = atomic_load_explicit(&ring->readChunks, memory_order_acquire);
    if (frames > ring->capacity || writtenFrames - readFrames > ring->capacity - frames ||
        writtenChunks - readChunks >= ring->capacity) {
        MTRingFail(ring, MTCaptureOverflow);
        goto done;
    }
    for (uint32_t frame = 0; frame < frames; ++frame) {
        uint64_t destination = ((writtenFrames + frame) % ring->capacity) * ring->channels;
        for (uint32_t channel = 0; channel < ring->channels; ++channel) {
            const float *input = buffers->mBuffers[ring->interleaved ? 0 : channel].mData;
            float sample = input[ring->interleaved ? (size_t)frame * ring->channels + channel : frame];
            if (!isfinite(sample)) {
                MTRingFail(ring, MTCaptureNonfiniteSample);
                goto done;
            }
            ring->samples[destination + channel] = sample;
        }
    }
    MTQueuedChunk *chunk = &ring->chunks[writtenChunks % ring->capacity];
    chunk->firstFrame = writtenFrames;
    chunk->info = (MTChunkInfo){hostTime, ring->generation, ring->sampleRate, frames, ring->channels};
    ring->previousHostTime = hostTime;
    atomic_store_explicit(&ring->writtenFrames, writtenFrames + frames, memory_order_relaxed);
    atomic_store_explicit(&ring->lastHostTime, hostTime, memory_order_release);
    atomic_store_explicit(&ring->writtenChunks, writtenChunks + 1, memory_order_release);
done:
    atomic_flag_clear_explicit(&ring->producing, memory_order_release);
}

bool MTRingPeek(MTCaptureRing *ring, MTChunkInfo *info) {
    uint64_t read = atomic_load_explicit(&ring->readChunks, memory_order_relaxed);
    if (read == atomic_load_explicit(&ring->writtenChunks, memory_order_acquire)) {
        return false;
    }
    *info = ring->chunks[read % ring->capacity].info;
    return true;
}

bool MTRingRead(MTCaptureRing *ring, float *samples, uint32_t sampleCapacity, MTChunkInfo *info) {
    if (!MTRingPeek(ring, info) || sampleCapacity < (uint64_t)info->frames * info->channels) {
        return false;
    }
    uint64_t read = atomic_load_explicit(&ring->readChunks, memory_order_relaxed);
    MTQueuedChunk *chunk = &ring->chunks[read % ring->capacity];
    uint32_t first = (uint32_t)(chunk->firstFrame % ring->capacity);
    uint32_t count = info->frames < ring->capacity - first ? info->frames : ring->capacity - first;
    memcpy(samples, ring->samples + (size_t)first * ring->channels, (size_t)count * ring->channels * sizeof(float));
    memcpy(samples + (size_t)count * ring->channels, ring->samples, (size_t)(info->frames - count) * ring->channels * sizeof(float));
    atomic_store_explicit(&ring->readFrames, chunk->firstFrame + info->frames, memory_order_release);
    atomic_store_explicit(&ring->readChunks, read + 1, memory_order_release);
    return true;
}
