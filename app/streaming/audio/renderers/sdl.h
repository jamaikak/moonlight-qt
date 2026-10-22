#pragma once

#include "renderer.h"
#include "SDL_compat.h"

#include <QString>

class SdlAudioRenderer : public IAudioRenderer
{
public:
    // If displayName is provided, we will try to play audio on the output
    // device that belongs to that display (HDMI, DisplayPort, AirPlay, etc.)
    explicit SdlAudioRenderer(const QString& displayName = QString());

    virtual ~SdlAudioRenderer();

    virtual bool prepareForPlayback(const OPUS_MULTISTREAM_CONFIGURATION* opusConfig);

    virtual void* getAudioBuffer(int* size);

    virtual bool submitAudio(int bytesWritten);

    virtual AudioFormat getAudioBufferFormat();

private:
    QString findDisplayAudioDevice();

    QString m_DisplayName;
    SDL_AudioDeviceID m_AudioDevice;
    void* m_AudioBuffer;
    Uint32 m_FrameSize;
    Uint32 m_FrameDurationMs;
};
