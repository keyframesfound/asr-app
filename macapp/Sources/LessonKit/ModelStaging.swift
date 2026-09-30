import Foundation
import FluidAudio

/// Stages FluidAudio speech-model artifacts into a directory that
/// Scripts/build_app.sh bundles as Contents/Resources/FluidAudio, so release
/// builds load the models straight from the app instead of downloading them
/// from HuggingFace on first use. `ltctl fetch-models <out-dir>` wraps this.
///
/// Sources, in order: any complete local cache (the pinned FluidAudio folder
/// name or the legacy pre-rename one an older pin may have downloaded), else a
/// download through FluidAudio itself.
public enum ModelStaging {

    /// Copy the SenseVoice artifacts for `precision` plus the Silero VAD model
    /// into `<out>/Models/`. Idempotent: complete destinations are skipped
    /// unless `force`.
    public static func stage(
        to outRoot: URL, precision: EncoderPrecision, force: Bool
    ) async throws {
        let coreMLPrecision: SenseVoiceEncoderPrecision = precision == .int8 ? .int8 : .fp16

        // SenseVoice: fp32 preprocessor (CPU) + one encoder variant + vocab.
        let encoderName = precision == .int8
            ? ModelNames.SenseVoice.encoderInt8
            : ModelNames.SenseVoice.encoder
        let voiceDest = outRoot
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("sensevoice-small-coreml", isDirectory: true)
        if !force && SenseVoiceModels.modelsExist(at: voiceDest, precision: coreMLPrecision) {
            print("==> sensevoice (\(encoderName)) already staged")
        } else {
            let source = try await senseVoiceSource(precision: coreMLPrecision)
            try FileManager.default.createDirectory(at: voiceDest, withIntermediateDirectories: true)
            for name in [
                ModelNames.SenseVoice.preprocessorFile,
                encoderName + ".mlmodelc",
                ModelNames.SenseVoice.vocabularyFile,
            ] {
                try replaceCopy(
                    from: source.appendingPathComponent(name),
                    to: voiceDest.appendingPathComponent(name))
            }
            print("==> staged sensevoice (\(encoderName) + preprocessor + vocab)")
        }

        // Silero VAD (~1 MB): bundling it keeps the first run fully offline.
        let vadFile = ModelNames.VAD.sileroVadFile
        let vadDest = outRoot
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("silero-vad-coreml", isDirectory: true)
        if !force && FileManager.default.fileExists(atPath: vadDest.appendingPathComponent(vadFile).path) {
            print("==> silero-vad already staged")
        } else {
            let source = try await vadSource()
            try FileManager.default.createDirectory(at: vadDest, withIntermediateDirectories: true)
            try replaceCopy(
                from: source.appendingPathComponent(vadFile),
                to: vadDest.appendingPathComponent(vadFile))
            print("==> staged silero-vad")
        }
    }

    private static func senseVoiceSource(
        precision: SenseVoiceEncoderPrecision
    ) async throws -> URL {
        if let found = cachedModel(
            named: ["sensevoice-small-coreml", "sensevoice-small"],
            check: { SenseVoiceModels.modelsExist(at: $0, precision: precision) }) {
            return found
        }
        print("==> no complete local cache; downloading SenseVoice via FluidAudio…")
        return try await SenseVoiceModels.download(precision: precision)
    }

    private static func vadSource() async throws -> URL {
        let vadFile = ModelNames.VAD.sileroVadFile
        if let found = cachedModel(
            named: ["silero-vad-coreml", "silero-vad"],
            check: { FileManager.default.fileExists(atPath: $0.appendingPathComponent(vadFile).path) }) {
            return found
        }
        print("==> no local VAD cache; downloading via FluidAudio…")
        try await ModelHub.download(.vad, to: modelsRoot())
        return modelsRoot().appendingPathComponent("silero-vad-coreml", isDirectory: true)
    }

    /// First cache folder under the FluidAudio models root whose contents
    /// satisfy `check` — tries the pinned FluidAudio's folder name first, then
    /// the legacy one (this machine's cache predates a FluidAudio rename).
    private static func cachedModel(
        named names: [String], check: (URL) -> Bool
    ) -> URL? {
        let fm = FileManager.default
        for name in names {
            let url = modelsRoot().appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue, check(url) else { continue }
            return url
        }
        return nil
    }

    private static func modelsRoot() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return base
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    private static func replaceCopy(from source: URL, to dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: source, to: dest)
    }
}
