## Plan: on-demand model loading (v1.1.3)

The transcription path already loads the model on demand — `TranscriptionEngine.transcribe()` calls `loadModels()` internally (TranscriptionEngine.swift:272) and joins any in-flight load, showing "Loading speech model…" progress on the job. So the work is purely *removing* the idle-unload machinery and the launch prewarm.

### Code changes

**macapp/Sources/LessonTranscriber/AppState.swift**
- Delete `modelUnloadTask` and `modelIdleUnloadInterval` (lines ~82–87) and the `scheduleModelUnload()` function (lines ~129–138).
- Delete the cancel of `modelUnloadTask` in `startTranscription` (lines ~161–164) and the `scheduleModelUnload()` call in the task's `defer` (line ~186), cleaning up the surrounding comments.
- Delete `prewarmModel()` (lines ~112–127) and the `@Published var modelWarmupStage` property (line ~78).

**macapp/Sources/LessonKit/TranscriptionEngine.swift**
- Delete `unloadModels()` (lines ~89–99) — its only caller was the idle timer.

**macapp/Sources/LessonTranscriber/Views/RootView.swift**
- Remove the `.task { state.prewarmModel() }` hook (line ~91).
- Simplify `versionFooter` (lines ~109–151): drop the mini `ProgressView` + warm-up stage text, keep the version label.

No other state tracks model residency, and no UserDefaults keys are involved, so nothing else changes. Behavior after this: model loads lazily on the first transcription (~0.3 s warm; the one-time ~145 s ANE compile per app version happens during that first transcription, with visible progress on the job card) and stays resident for the session.

### Verify
- Build with `DEVELOPER_DIR=/Applications/Xcode.app` (swift build / build_app.sh) to confirm it compiles clean.

### Release v1.1.3
- Use the release-macapp skill: bump version, build + notarize + staple, publish DMG (humans) + zip (updater payload) to GitHub Releases on keyframesfound/asr-app, then update the project memory to reflect that idle-unload is gone and loading is on-demand.