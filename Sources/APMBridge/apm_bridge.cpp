#include "meetingtape_apm.h"

#include <array>
#include <cmath>
#include <new>

#include "api/audio/audio_processing.h"

namespace {

enum Code {
    kOk = 0,
    kNull = 1,
    kFrameCount = 2,
    kNonFiniteInput = 3,
    kReverse = 4,
    kDelay = 5,
    kCapture = 6,
    kNonFiniteOutput = 7,
};

bool digital_3a_enabled(const webrtc::AudioProcessing::Config &config) {
    return config.echo_canceller.enabled && config.noise_suppression.enabled &&
           !config.gain_controller1.enabled && config.gain_controller2.enabled &&
           config.gain_controller2.adaptive_digital.enabled &&
           !config.gain_controller2.input_volume_controller.enabled;
}

}

struct meetingtape_apm {
    rtc::scoped_refptr<webrtc::AudioProcessing> processor;
};

extern "C" meetingtape_apm *meetingtape_apm_create(void) {
    try {
        auto created = webrtc::AudioProcessingBuilder().Create();
        if (!created) {
            return nullptr;
        }
        webrtc::AudioProcessing::Config config;
        config.echo_canceller.enabled = true;
        config.noise_suppression.enabled = true;
        config.gain_controller1.enabled = false;
        config.gain_controller2.enabled = true;
        config.gain_controller2.adaptive_digital.enabled = true;
        config.gain_controller2.input_volume_controller.enabled = false;
        created->ApplyConfig(config);
        if (!digital_3a_enabled(created->GetConfig())) {
            return nullptr;
        }
        auto *processor = new meetingtape_apm;
        processor->processor = created;
        return processor;
    } catch (...) {
        return nullptr;
    }
}

extern "C" void meetingtape_apm_destroy(meetingtape_apm *processor) {
    delete processor;
}

extern "C" int meetingtape_apm_digital_3a_enabled(const meetingtape_apm *processor) {
    if (processor == nullptr || !processor->processor) {
        return 0;
    }
    return digital_3a_enabled(processor->processor->GetConfig()) ? 1 : 0;
}

extern "C" int meetingtape_apm_process(
    meetingtape_apm *processor,
    const float *microphone,
    const float *reference_left,
    const float *reference_right,
    int frame_count,
    int delay_milliseconds,
    float *output) {
    if (processor == nullptr || !processor->processor || microphone == nullptr ||
        reference_left == nullptr || reference_right == nullptr || output == nullptr) {
        return kNull;
    }
    const webrtc::StreamConfig capture(MEETINGTAPE_APM_SAMPLE_RATE, 1);
    const webrtc::StreamConfig render(MEETINGTAPE_APM_SAMPLE_RATE, 2);
    if (frame_count != MEETINGTAPE_APM_FRAME_COUNT ||
        capture.num_frames() != static_cast<size_t>(MEETINGTAPE_APM_FRAME_COUNT) ||
        render.num_frames() != static_cast<size_t>(MEETINGTAPE_APM_FRAME_COUNT)) {
        return kFrameCount;
    }

    std::array<float, MEETINGTAPE_APM_FRAME_COUNT> mic{};
    std::array<float, MEETINGTAPE_APM_FRAME_COUNT> left{};
    std::array<float, MEETINGTAPE_APM_FRAME_COUNT> right{};
    std::array<float, MEETINGTAPE_APM_FRAME_COUNT> reverse_left{};
    std::array<float, MEETINGTAPE_APM_FRAME_COUNT> reverse_right{};
    std::array<float, MEETINGTAPE_APM_FRAME_COUNT> processed{};
    for (int index = 0; index < frame_count; ++index) {
        mic[static_cast<size_t>(index)] = microphone[index];
        left[static_cast<size_t>(index)] = reference_left[index];
        right[static_cast<size_t>(index)] = reference_right[index];
        if (!std::isfinite(mic[static_cast<size_t>(index)]) ||
            !std::isfinite(left[static_cast<size_t>(index)]) ||
            !std::isfinite(right[static_cast<size_t>(index)])) {
            return kNonFiniteInput;
        }
    }

    const float *reverse_input[] = {left.data(), right.data()};
    float *reverse_output[] = {reverse_left.data(), reverse_right.data()};
    const float *capture_input[] = {mic.data()};
    float *capture_output[] = {processed.data()};
    if (processor->processor->ProcessReverseStream(reverse_input, render, render, reverse_output) != 0) {
        return kReverse;
    }
    if (processor->processor->set_stream_delay_ms(delay_milliseconds) != 0) {
        return kDelay;
    }
    if (processor->processor->ProcessStream(capture_input, capture, capture, capture_output) != 0) {
        return kCapture;
    }
    for (int index = 0; index < frame_count; ++index) {
        const float sample = processed[static_cast<size_t>(index)];
        if (!std::isfinite(sample)) {
            return kNonFiniteOutput;
        }
        output[index] = sample;
    }
    return kOk;
}
