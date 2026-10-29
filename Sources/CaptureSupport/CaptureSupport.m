#import "CaptureRing.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <unistd.h>

@interface MTNativeStream : NSObject {
@public
    MTCaptureRing ring;
    BOOL ringInitialized;
    MTCaptureSource source;
    AudioObjectID tap;
    AudioObjectID aggregate;
    AudioDeviceIOProcID ioProc;
    CFTypeRef callbackAnchor;
    CFTypeRef retirementAnchor;
    AVAudioEngine *engine;
    id configurationObserver;
    AudioDeviceID inputDevice;
    BOOL tapInstalled;
    BOOL deviceStarted;
    BOOL stopScheduled;
    dispatch_group_t teardown;
    _Atomic(int) teardownStatus;
    _Atomic(uint32_t) callbacks;
    uint64_t startedAt;
    double secondsPerTick;
    AudioStreamBasicDescription captureFormat;
}
- (BOOL)startSystem:(uint64_t)generation error:(NSString **)error;
- (BOOL)startMicrophone:(uint64_t)generation error:(NSString **)error;
- (void)retire;
@end

static NSString *MTStatus(NSString *operation, OSStatus status) {
    return [NSString stringWithFormat:@"%@ failed (%d)", operation, (int)status];
}

static void MTWriteError(char *destination, size_t capacity, NSString *message) {
    if (destination && capacity) {
        snprintf(destination, capacity, "%s", message.UTF8String ?: "audio capture failed");
    }
}

static AudioDeviceID MTDefaultInput(void) {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) != noErr) {
        return kAudioObjectUnknown;
    }
    return device;
}

static OSStatus MTSystemCallback(AudioObjectID device, const AudioTimeStamp *now,
                                 const AudioBufferList *input, const AudioTimeStamp *inputTime,
                                 AudioBufferList *output, const AudioTimeStamp *outputTime, void *clientData) {
    __unsafe_unretained MTNativeStream *stream = (__bridge MTNativeStream *)clientData;
    atomic_fetch_add_explicit(&stream->callbacks, 1, memory_order_acquire);
    MTCaptureRing *ring = &stream->ring;
    uint32_t divisor = sizeof(float) * (ring->interleaved ? ring->channels : 1);
    uint32_t frames = input && input->mNumberBuffers ? input->mBuffers[0].mDataByteSize / divisor : 0;
    bool validTime = inputTime && (inputTime->mFlags & kAudioTimeStampHostTimeValid);
    MTRingPush(ring, input, frames, inputTime ? inputTime->mHostTime : 0, validTime);
    atomic_fetch_sub_explicit(&stream->callbacks, 1, memory_order_release);
    return noErr;
}

@implementation MTNativeStream

- (instancetype)init {
    self = [super init];
    if (self) {
        teardown = dispatch_group_create();
        atomic_init(&teardownStatus, noErr);
        atomic_init(&callbacks, 0);
        mach_timebase_info_data_t timebase;
        mach_timebase_info(&timebase);
        secondsPerTick = (double)timebase.numer / timebase.denom / 1e9;
        startedAt = mach_absolute_time();
    }
    return self;
}

- (BOOL)startSystem:(uint64_t)generation error:(NSString **)error {
    CATapDescription *description = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
    description.name = @"MeetingTape system audio";
    description.privateTap = YES;
    description.muteBehavior = CATapUnmuted;
    OSStatus status = AudioHardwareCreateProcessTap(description, &tap);
    if (status != noErr) {
        *error = MTStatus(@"Create global system tap", status);
        return NO;
    }
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    AudioObjectPropertyAddress address = {kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    status = AudioObjectGetPropertyData(tap, &address, 0, NULL, &size, &format);
    if (status != noErr) {
        *error = MTStatus(@"Read system tap format", status);
        return NO;
    }
    if (format.mChannelsPerFrame != 2 || !MTRingInitialize(&ring, &format, generation)) {
        *error = @"System tap requires native float32 stereo PCM between 8 and 192 kHz";
        return NO;
    }
    ringInitialized = YES;
    captureFormat = format;
    NSDictionary *settings = @{
        @kAudioAggregateDeviceNameKey: @"MeetingTape system capture",
        @kAudioAggregateDeviceUIDKey: NSUUID.UUID.UUIDString,
        @kAudioAggregateDeviceIsPrivateKey: @YES,
        @kAudioAggregateDeviceTapAutoStartKey: @NO,
        @kAudioAggregateDeviceTapListKey: @[@{
            @kAudioSubTapUIDKey: description.UUID.UUIDString,
            @kAudioSubTapDriftCompensationKey: @YES,
        }],
    };
    status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)settings, &aggregate);
    if (status != noErr) {
        *error = MTStatus(@"Create system tap aggregate", status);
        return NO;
    }
    Float64 rate = format.mSampleRate;
    AudioObjectPropertyAddress rateAddress = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    status = AudioObjectSetPropertyData(aggregate, &rateAddress, 0, NULL, sizeof(rate), &rate);
    if (status != noErr) {
        *error = MTStatus(@"Configure system capture sample rate", status);
        return NO;
    }
    UInt32 frames = (UInt32)(rate / 100);
    AudioObjectPropertyAddress bufferAddress = {kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    status = AudioObjectSetPropertyData(aggregate, &bufferAddress, 0, NULL, sizeof(frames), &frames);
    if (status != noErr) {
        *error = MTStatus(@"Configure system capture buffer size", status);
        return NO;
    }
    callbackAnchor = CFBridgingRetain(self);
    status = AudioDeviceCreateIOProcID(aggregate, MTSystemCallback, (__bridge void *)self, &ioProc);
    if (status != noErr) {
        CFRelease(callbackAnchor);
        callbackAnchor = NULL;
        *error = MTStatus(@"Create system tap callback", status);
        return NO;
    }
    atomic_store_explicit(&ring.accepting, true, memory_order_release);
    status = AudioDeviceStart(aggregate, ioProc);
    if (status != noErr) {
        *error = MTStatus(@"Start system tap", status);
        return NO;
    }
    deviceStarted = YES;
    return YES;
}

- (BOOL)startMicrophone:(uint64_t)generation error:(NSString **)error {
    inputDevice = MTDefaultInput();
    if (inputDevice == kAudioObjectUnknown) {
        *error = @"No default microphone is available";
        return NO;
    }
    engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = engine.inputNode;
    AVAudioFormat *format = [input outputFormatForBus:0];
    if (!MTRingInitialize(&ring, format.streamDescription, generation)) {
        *error = @"Default microphone requires native float32 mono or stereo PCM between 8 and 192 kHz";
        return NO;
    }
    ringInitialized = YES;
    captureFormat = *format.streamDescription;
    MTNativeStream *stream = self;
    configurationObserver = [NSNotificationCenter.defaultCenter addObserverForName:AVAudioEngineConfigurationChangeNotification
                                                                          object:engine queue:nil usingBlock:^(NSNotification *notification) {
        atomic_store_explicit(&stream->ring.configurationChanged, true, memory_order_release);
    }];
    [input installTapOnBus:0 bufferSize:1024 format:format block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        MTRingPush(&stream->ring, buffer.audioBufferList, buffer.frameLength, when.hostTime, when.isHostTimeValid);
    }];
    tapInstalled = YES;
    [engine prepare];
    NSError *startError;
    atomic_store_explicit(&ring.accepting, true, memory_order_release);
    if (![engine startAndReturnError:&startError]) {
        *error = startError.localizedDescription ?: @"Start default microphone failed";
        return NO;
    }
    if (MTDefaultInput() != inputDevice) {
        *error = @"Default microphone changed while capture was starting";
        return NO;
    }
    return YES;
}

- (void)retire {
    OSStatus result = noErr;
    @try {
        if (configurationObserver) {
            [NSNotificationCenter.defaultCenter removeObserver:configurationObserver];
            configurationObserver = nil;
        }
        if (engine) {
            [engine stop];
            if (tapInstalled) {
                [engine.inputNode removeTapOnBus:0];
                tapInstalled = NO;
            }
            engine = nil;
        }
        if (ioProc) {
            if (deviceStarted) {
                result = AudioDeviceStop(aggregate, ioProc);
            }
            OSStatus destroyStatus = AudioDeviceDestroyIOProcID(aggregate, ioProc);
            if (destroyStatus != noErr) {
                atomic_store_explicit(&teardownStatus, destroyStatus, memory_order_release);
                return;
            }
            ioProc = NULL;
            for (int attempt = 0; atomic_load_explicit(&callbacks, memory_order_acquire) != 0 && attempt < 100; ++attempt) {
                usleep(1000);
            }
            if (atomic_load_explicit(&callbacks, memory_order_acquire) != 0) {
                atomic_store_explicit(&teardownStatus, kAudioHardwareIllegalOperationError, memory_order_release);
                return;
            }
            if (callbackAnchor) {
                CFRelease(callbackAnchor);
                callbackAnchor = NULL;
            }
        }
        if (aggregate) {
            OSStatus status = AudioHardwareDestroyAggregateDevice(aggregate);
            if (result == noErr) result = status;
            aggregate = kAudioObjectUnknown;
        }
        if (tap) {
            OSStatus status = AudioHardwareDestroyProcessTap(tap);
            if (result == noErr) result = status;
            tap = kAudioObjectUnknown;
        }
    } @catch (NSException *exception) {
        result = kAudioHardwareUnspecifiedError;
    }
    atomic_store_explicit(&teardownStatus, result, memory_order_release);
}

- (void)dealloc {
    if (ringInitialized) {
        MTRingDestroy(&ring);
    }
}
@end

MTStreamRef MTStreamCreate(MTCaptureSource source, uint64_t generation, bool *cleanupFailed, char *error, size_t errorCapacity) {
    @autoreleasepool {
        *cleanupFailed = false;
        MTNativeStream *stream = [[MTNativeStream alloc] init];
        stream->source = source;
        NSString *reason;
        BOOL started = NO;
        @try {
            started = source == MTCaptureSystem ? [stream startSystem:generation error:&reason] : [stream startMicrophone:generation error:&reason];
        } @catch (NSException *exception) {
            reason = [NSString stringWithFormat:@"Audio capture setup failed: %@", exception.reason];
        }
        MTStreamRef reference = (MTStreamRef)CFBridgingRetain(stream);
        if (!started) {
            char cleanupError[256] = {0};
            if (!MTStreamStop(reference, cleanupError, sizeof(cleanupError))) {
                *cleanupFailed = true;
                reason = [NSString stringWithFormat:@"%@; %s", reason, cleanupError];
            }
            MTWriteError(error, errorCapacity, reason);
            MTStreamDestroy(reference);
            return NULL;
        }
        return reference;
    }
}

bool MTStreamPeek(MTStreamRef reference, MTChunkInfo *info) {
    MTNativeStream *stream = (__bridge MTNativeStream *)reference;
    return MTRingPeek(&stream->ring, info);
}

bool MTStreamRead(MTStreamRef reference, float *samples, uint32_t sampleCapacity, MTChunkInfo *info) {
    MTNativeStream *stream = (__bridge MTNativeStream *)reference;
    return MTRingRead(&stream->ring, samples, sampleCapacity, info);
}

MTStreamStatus MTStreamPoll(MTStreamRef reference) {
    MTNativeStream *stream = (__bridge MTNativeStream *)reference;
    uint64_t last = atomic_load_explicit(&stream->ring.lastHostTime, memory_order_acquire);
    uint64_t now = mach_absolute_time();
    uint64_t anchor = last ? last : stream->startedAt;
    return (MTStreamStatus){
        atomic_load_explicit(&stream->ring.fatalError, memory_order_acquire),
        now >= anchor ? (now - anchor) * stream->secondsPerTick : 0,
        last != 0,
        atomic_load_explicit(&stream->ring.configurationChanged, memory_order_acquire),
    };
}

bool MTStreamNeedsRefresh(MTStreamRef reference) {
    MTNativeStream *stream = (__bridge MTNativeStream *)reference;
    if (atomic_load_explicit(&stream->ring.configurationChanged, memory_order_acquire)) {
        return true;
    }
    if (stream->source == MTCaptureMicrophone) {
        return MTDefaultInput() != stream->inputDevice;
    }
    UInt32 alive = 0;
    UInt32 aliveSize = sizeof(alive);
    AudioObjectPropertyAddress aliveAddress = {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(stream->aggregate, &aliveAddress, 0, NULL, &aliveSize, &alive) != noErr || !alive) {
        return true;
    }
    AudioStreamBasicDescription format = {0};
    UInt32 size = sizeof(format);
    AudioObjectPropertyAddress address = {kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    OSStatus status = AudioObjectGetPropertyData(stream->tap, &address, 0, NULL, &size, &format);
    return status != noErr || memcmp(&format, &stream->captureFormat, sizeof(format)) != 0;
}

bool MTStreamStop(MTStreamRef reference, char *error, size_t errorCapacity) {
    MTNativeStream *stream = (__bridge MTNativeStream *)reference;
    MTStreamQuiesce(reference);
    if (!stream->stopScheduled) {
        stream->stopScheduled = YES;
        // Failed teardown retains callback-owned state, and the Swift owner stops retrying.
        stream->retirementAnchor = CFBridgingRetain(stream);
        dispatch_group_enter(stream->teardown);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            @autoreleasepool {
                [stream retire];
                if (atomic_load_explicit(&stream->teardownStatus, memory_order_acquire) == noErr) {
                    CFRelease(stream->retirementAnchor);
                    stream->retirementAnchor = NULL;
                }
                dispatch_group_leave(stream->teardown);
            }
        });
    }
    if (dispatch_group_wait(stream->teardown, dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC)) != 0) {
        MTWriteError(error, errorCapacity, @"Audio capture teardown exceeded 500 ms; callback context remains retained");
        return false;
    }
    OSStatus status = atomic_load_explicit(&stream->teardownStatus, memory_order_acquire);
    if (status != noErr) {
        MTWriteError(error, errorCapacity, MTStatus(@"Audio capture teardown", status));
        return false;
    }
    return true;
}

void MTStreamQuiesce(MTStreamRef reference) {
    MTNativeStream *stream = (__bridge MTNativeStream *)reference;
    if (stream->ringInitialized) {
        atomic_store_explicit(&stream->ring.accepting, false, memory_order_release);
    }
}

void MTStreamDestroy(MTStreamRef reference) {
    if (reference) {
        CFBridgingRelease(reference);
    }
}
