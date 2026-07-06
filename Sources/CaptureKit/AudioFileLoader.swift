import AVFoundation

public enum AudioFileError: Error { case unreadable, emptyFile }

/// Loads any AVAudioFile-readable file into canonical AudioData (fixtures, CLI).
public enum AudioFileLoader {
    public static func load(url: URL) throws -> AudioData {
        let file = try AVAudioFile(forReading: url)
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames)
        else { throw AudioFileError.emptyFile }
        try file.read(into: buffer)
        let samples = AudioResampler.convertAll(buffer)
        guard !samples.isEmpty else { throw AudioFileError.unreadable }
        return AudioData(samples: samples)
    }
}
