// The speech models: FluidAudio's Core ML builds of Silero (finds speech), Parakeet, Bark or
// SenseVoice (speech to text), and pyannote + WeSpeaker (who spoke when, and voice fingerprints).
// They run on the Mac, mostly on the Neural Engine, and download from Hugging Face on first use:
// nothing else goes over the network.

import FluidAudio
import Foundation

public enum SpeechModels {
    /// What decodes the speech: a Parakeet-family model (Parakeet itself, or Bark, a retraining of
    /// it), which gives each word's time, or SenseVoice, which gives the text alone.
    enum Decoder: Sendable, Equatable {
        case parakeet(AsrModelVersion)
        case senseVoice
    }

    public struct AsrChoice: Sendable {
        public let key: String
        public let title: String
        public let detail: String
        let decoder: Decoder
    }

    /// The transcription models Settings offers.
    public static let asr: [AsrChoice] = [
        AsrChoice(key: "parakeet-en", title: "Parakeet English", detail: "English only. The most accurate for English calls.",
                  decoder: .parakeet(.v2)),
        AsrChoice(key: "bark-en", title: "Bark English",
                  detail: "English only. A retraining of Parakeet for conversation that leaves out “um”, false starts and repeated words. About 420 MB more to download.",
                  decoder: .parakeet(.bark3Clean)),
        AsrChoice(key: "parakeet-multilingual", title: "Parakeet — 25 European languages",
                  detail: "Detects the language of each call.", decoder: .parakeet(.ultra)),
        AsrChoice(key: "sensevoice", title: "SenseVoice — Chinese, Cantonese, Japanese, Korean and English",
                  detail: "Detects the language of each line. Each stretch of speech goes to one voice, so a quick back-and-forth is split less finely. About 460 MB more to download.",
                  decoder: .senseVoice),
    ]
    public static let defaultAsr = "parakeet-en"

    /// A config value, including the Electron version's names for the same choices. One it doesn't
    /// know (from a newer version, say) is the default.
    public static func asrChoice(_ key: String) -> AsrChoice {
        let key = key == "parakeet-tdt-v3" ? "parakeet-multilingual" : key
        return asr.first { $0.key == key } ?? asr[0]
    }

    static let root = Paths.models.appendingPathComponent("FluidAudio", isDirectory: true)
    static func asrDirectory(_ version: AsrModelVersion) -> URL {
        root.appendingPathComponent(AsrModels.defaultCacheDirectory(for: version).lastPathComponent, isDirectory: true)
    }
    /// SenseVoice's files, in Oatcake's models folder rather than FluidAudio's own.
    static let senseVoiceDirectory = root.appendingPathComponent(Repo.senseVoiceSmall.folderName, isDirectory: true)
    static let diarizerDirectory = root.appendingPathComponent("speaker-diarization-coreml", isDirectory: true)

    /// Whether anything still has to be downloaded for this transcription model.
    static func needsDownload(_ key: String) -> Bool {
        let speech = switch asrChoice(key).decoder {
        case .parakeet(let version): AsrModels.modelsExist(at: asrDirectory(version), version: version)
        case .senseVoice: SenseVoiceModels.modelsExist(at: senseVoiceDirectory)
        }
        return !speech
            || !FileManager.default.exists(root.appendingPathComponent("Models/silero-vad"))
            || !FileManager.default.exists(diarizerDirectory)
    }

    /**
     * The model files come from these exact Hugging Face commits, so a change to a model repo can't
     * change what Oatcake runs. FluidAudio pins the diarisation models itself. Moving to a newer
     * model means updating a commit here (and checking the results), like updating a dependency.
     */
    static let pinnedRevisions = [
        "FluidInference/parakeet-tdt-0.6b-v2-coreml": "ee09c569f73759e6d44c9bd16766f477b2b36d39",
        "FluidInference/parakeet-ultra-coreml": "95eaa59a39d4394f047a4dc5cce480388a60d1b6",
        "FluidInference/bark-3.0-coreml": "73b0c0da665d29ea0332e9f0d32da8e26a4cdb38",
        "FluidInference/sensevoice-small-coreml": "74bdbe74b2258f25b5400db72f6cbfbef7c74ded",
        "FluidInference/silero-vad-coreml": "b419383c55c110e2c9271fa6ee0ea83d03c70d96",
    ]

    static func loadTranscriber(_ key: String) async throws -> Transcriber {
        ModelRegistry.revisionOverrides = pinnedRevisions
        let vad = try await VadManager(config: .default, modelDirectory: root)
        switch asrChoice(key).decoder {
        case .parakeet(let version):
            let models = try await AsrModels.downloadAndLoad(to: asrDirectory(version), version: version)
            let asr = AsrManager(config: .default)
            try await asr.loadModels(models)
            return Transcriber(vad: vad, decoder: .parakeet(asr))
        case .senseVoice:
            // The fp16 encoder, on the Neural Engine (FluidAudio's default). Downloaded the way its
            // own loader does it, but into Oatcake's folder.
            let directory = senseVoiceDirectory
            let models = try await ModelHub.loadWithRecovery(
                .senseVoiceSmall, directory: root,
                requiredFiles: [ModelNames.SenseVoice.preprocessorFile, ModelNames.SenseVoice.encoderFile, ModelNames.SenseVoice.vocabularyFile],
                variant: SenseVoiceEncoderPrecision.fp16.rawValue
            ) { try SenseVoiceModels.load(from: directory) }
            // "withitn": punctuation, and numbers written as numbers. FluidAudio's default leaves both out.
            return Transcriber(vad: vad, decoder: .senseVoice(SenseVoiceManager(models: models, textNorm: 14)))
        }
    }

    /// `live`: for fingerprints of the live transcript's lines, a line or two at a time. A batch of one
    /// keeps the memory they take while it works down to a few MB, where the default 32 at a time
    /// went up by hundreds.
    static func loadDiarizer(live: Bool = false) async throws -> OfflineDiarizerManager {
        var config = OfflineDiarizerConfig()
        // One speaker at a time, so every word of the transcript gets exactly one.
        config.postProcessing.exclusiveSegments = true
        if live {
            config.embedding.batchSize = 1
            config.segmentation.batchSize = 1
        }
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels(directory: diarizerDirectory)
        return manager
    }

    /// The Electron version's sherpa-onnx models (about 700 MB), which nothing uses any more.
    public static func removeOldModels() {
        let old = [
            "sherpa-onnx-nemo-parakeet-unified-en-0.6b-int8-non-streaming",
            "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
            "silero_vad.onnx",
            "sherpa-onnx-pyannote-segmentation-3-0",
            "3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx",
        ]
        for name in old { try? FileManager.default.removeItem(at: Paths.models.appendingPathComponent(name)) }
        for name in (try? FileManager.default.contentsOfDirectory(atPath: Paths.models.path)) ?? [] where name.hasSuffix(".part") {
            try? FileManager.default.removeItem(at: Paths.models.appendingPathComponent(name))
        }
    }
}

public struct Word: Sendable {
    public var text: String
    /// Seconds from the start of the track.
    public var start: Double
    public var end: Double
}

public struct Utterance: Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var words: [Word]
}

/// Silero finds the stretches of speech (up to 14 s each), and the speech model decodes each one.
final class Transcriber {
    enum Decoder {
        case parakeet(AsrManager)
        case senseVoice(SenseVoiceManager)
    }

    private let vad: VadManager
    private let decoder: Decoder

    init(vad: VadManager, decoder: Decoder) {
        self.vad = vad
        self.decoder = decoder
    }

    /// Speech is cut into stretches at pauses, 14 s at most.
    private var segmentation: VadSegmentationConfig {
        var config = VadSegmentationConfig.default
        config.minSpeechDuration = 0.25
        config.minSilenceDuration = 0.4
        config.maxSpeechDuration = 14
        return config
    }

    /// Decodes the speech between two times in `samples`; nil when the model hears no words in it.
    private func decode(_ samples: [Float], from start: Double, to end: Double) async throws -> Utterance? {
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: sampleRate)
        var chunk = Array(slice(samples, start, end))
        // Very short stretches are padded with silence up to the model's minimum.
        if chunk.count < minimum { chunk += [Float](repeating: 0, count: minimum - chunk.count) }
        let asr: AsrManager
        switch decoder {
        case .parakeet(let manager): asr = manager
        case .senseVoice(let manager):
            // Text alone, without each word's time: the stretch goes to one voice whole.
            let text = try await senseVoice(manager, chunk)
            return text.isEmpty ? nil : Utterance(start: start, end: end, text: text, words: [])
        }
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(chunk, decoderState: &state)
        let text = result.text.trimmed
        guard !text.isEmpty else { return nil }
        let words = buildWordTimings(from: result.tokenTimings ?? []).map {
            Word(text: $0.word, start: start + $0.startTime, end: start + $0.endTime)
        }
        return Utterance(start: start, end: end, text: text, words: words)
    }

    /**
     * SenseVoice's text for a stretch of speech. Now and then it returns nothing for one, not even
     * the language it heard (a Japanese test sentence did, read by one voice of three), which is the
     * model failing rather than silence: the two halves are tried on their own, once.
     */
    private func senseVoice(_ manager: SenseVoiceManager, _ chunk: [Float], halved: Bool = false) async throws -> String {
        let result = try await manager.transcribeDetailed(audio: chunk)
        guard result.text.trimmed.isEmpty, result.language == nil, !halved, chunk.count >= 2 * sampleRate else { return result.text.trimmed }
        let half = chunk.count / 2
        let first = try await senseVoice(manager, Array(chunk[..<half]), halved: true)
        let second = try await senseVoice(manager, Array(chunk[half...]), halved: true)
        return [first, second].filter { !$0.isEmpty }.joined(separator: " ")
    }

    func transcribe(_ samples: [Float], progress: (Double) -> Void) async throws -> [Utterance] {
        guard !samples.isEmpty else { return [] }
        let segments = try await vad.segmentSpeech(samples, config: segmentation)
        var utterances: [Utterance] = []
        for (i, segment) in segments.enumerated() {
            if let utterance = try await decode(samples, from: segment.startTime, to: segment.endTime) { utterances.append(utterance) }
            if i % 10 == 0 { progress(Double(i) / Double(segments.count)) }
        }
        progress(1)
        return utterances
    }

    /**
     * For audio still being recorded: decodes the stretches of speech that have finished (a pause
     * follows them) and says how many of the samples are dealt with. Speech still going at the end
     * is left for the next call, when more of it has arrived.
     */
    func transcribeFinished(_ samples: [Float], last: Bool = false) async throws -> (utterances: [Utterance], consumed: Int) {
        let segments = try await vad.segmentSpeech(samples, config: segmentation)
        let (finished, consumed) = finishedSpeech(segments.map { ($0.startTime, $0.endTime) }, samples: samples.count, last: last)
        var utterances: [Utterance] = []
        for segment in segments.prefix(finished) {
            if let utterance = try await decode(samples, from: segment.startTime, to: segment.endTime) { utterances.append(utterance) }
        }
        return (utterances, consumed)
    }
}

/// A stretch of speech still going this close to the end of the audio so far may not be over.
private let stillSpeaking = 0.6

/**
 * Of the stretches of speech found in audio that's still being recorded: how many are finished (a
 * pause follows them), and how many of the samples are dealt with. A stretch still going at the end
 * is left for next time, with a quarter of a second before it so its beginning is heard whole; in
 * silence, all but the last second is done with. On the `last` pass the recording is over, so
 * everything is finished: otherwise the call's final sentence would never be shown.
 */
func finishedSpeech(_ segments: [(start: Double, end: Double)], samples: Int, last: Bool) -> (finished: Int, consumed: Int) {
    if last { return (segments.count, samples) }
    let duration = Double(samples) / Double(sampleRate)
    var consumed = 0
    for (i, segment) in segments.enumerated() {
        if segment.end > duration - stillSpeaking {
            return (i, max(consumed, Int(segment.start * Double(sampleRate)) - sampleRate / 4))
        }
        consumed = min(samples, Int((segment.end * Double(sampleRate)).rounded(.up)))
    }
    return (segments.count, max(consumed, samples - sampleRate))
}
