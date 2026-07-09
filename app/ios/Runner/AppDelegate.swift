import AVFoundation
import Flutter
import Speech
import SwiftUI
import UIKit
#if canImport(Translation)
import Translation
#endif

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if #available(iOS 13.0, *) {
      let writerRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "AudioFileWriter")!
      AudioFileWriter.register(with: writerRegistrar)
      let translatorRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppleTranslator")!
      AppleTranslator.register(with: translatorRegistrar)
      let fileAsrRegistrar = engineBridge.pluginRegistry.registrar(forPlugin: "AppleFileRecognizer")!
      AppleFileRecognizer.register(with: fileAsrRegistrar)
    }
  }
}

/// Bridges raw 16kHz mono Int16 LE PCM from Dart to an on-disk m4a/AAC file
/// via AVAudioFile. Used for the in-app recording archive: each ASR mode's
/// PCM stream is mirrored here while ASR runs in parallel, so we end up with
/// a playable .m4a per Start/Stop session.
///
/// Inlined into AppDelegate.swift (rather than a separate file) so we don't
/// have to touch the Xcode pbxproj file list to add it to the Runner target.
@available(iOS 13.0, *)
public class AudioFileWriter: NSObject, FlutterPlugin {
  static let channelName = "app.translate/audio_writer"

  private var file: AVAudioFile?
  private let pcmFormat: AVAudioFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true
  )!
  private let lock = NSLock()
  private static var heldChannel: FlutterMethodChannel?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: channelName, binaryMessenger: registrar.messenger())
    let instance = AudioFileWriter()
    channel.setMethodCallHandler { [weak instance] call, result in
      instance?.handle(call, result: result)
    }
    // Hold strong refs so ARC doesn't reap the channel/handler at end of
    // register(with:). Same trick as the speech_to_text fork.
    heldChannel = channel
    registrar.publish(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
        result(FlutterError(code: "bad_args", message: "path required", details: nil))
        return
      }
      do {
        try start(at: path)
        result(true)
      } catch {
        result(FlutterError(code: "start_failed", message: error.localizedDescription, details: nil))
      }
    case "write":
      guard let data = (call.arguments as? [String: Any])?["data"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "bad_args", message: "data required", details: nil))
        return
      }
      write(data.data)
      result(nil)
    case "stop":
      stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func start(at path: String) throws {
    lock.lock()
    defer { lock.unlock() }
    if file != nil { stopLocked() }
    let url = URL(fileURLWithPath: path)
    // Encoder writes m4a with AAC at 32kbps mono 16kHz. AVAudioFile internally
    // converts the incoming int16 PCM buffers to the encoder format.
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 16000,
      AVNumberOfChannelsKey: 1,
      AVEncoderBitRateKey: 32000,
    ]
    file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
  }

  private func write(_ data: Data) {
    lock.lock()
    defer { lock.unlock() }
    guard let file = file else { return }
    let sampleCount = AVAudioFrameCount(data.count / 2)
    if sampleCount == 0 { return }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: sampleCount) else { return }
    buffer.frameLength = sampleCount
    guard let dst = buffer.int16ChannelData?.pointee else { return }
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      guard let src = raw.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
      memcpy(dst, src, Int(sampleCount) * 2)
    }
    do {
      try file.write(from: buffer)
    } catch {
      NSLog("[AudioFileWriter] write failed: %@", error.localizedDescription)
    }
  }

  private func stop() {
    lock.lock()
    defer { lock.unlock() }
    stopLocked()
  }

  private func stopLocked() {
    // AVAudioFile flushes and closes when its `file` ivar is released. Drop
    // our ref so the encoder can finalize the m4a moov atom.
    file = nil
  }
}

/// Bridges Dart calls to Apple's Translation framework so the
/// "Apple ASR + Apple Translation" engine can run fully on-device with no
/// network round-trip. iOS 18.0+ only — older OSes return an `unavailable`
/// PlatformException so Dart can show a friendly message.
///
/// Inlined here (same pattern as AudioFileWriter) so we don't have to touch
/// the Runner pbxproj when adding the file.
@available(iOS 13.0, *)
public class AppleTranslator: NSObject, FlutterPlugin {
  static let channelName = "app.translate/apple_translation"
  private static var heldChannel: FlutterMethodChannel?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let instance = AppleTranslator()
    channel.setMethodCallHandler { [weak instance] call, result in
      instance?.handle(call, result: result)
    }
    heldChannel = channel
    registrar.publish(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "translate":
      handleTranslate(call, result: result)
    case "prepare":
      handlePrepare(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func handleTranslate(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let text = args["text"] as? String, !text.isEmpty,
          let source = args["source"] as? String,
          let target = args["target"] as? String else {
      result(FlutterError(code: "bad_args",
                          message: "text/source/target required",
                          details: nil))
      return
    }
    #if canImport(Translation)
    if #available(iOS 18.0, *) {
      AppleTranslatorRunner.run(mode: .translate(text),
                                source: source, target: target) { res in
        DispatchQueue.main.async {
          switch res {
          case .success(let translated):
            result(translated)
          case .failure(let err):
            result(FlutterError(code: "translate_failed",
                                message: err.localizedDescription,
                                details: nil))
          }
        }
      }
      return
    }
    #endif
    result(FlutterError(code: "unavailable",
                        message: "Apple Translation requires iOS 18.0+",
                        details: nil))
  }

  private func handlePrepare(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let source = args["source"] as? String,
          let target = args["target"] as? String else {
      result(FlutterError(code: "bad_args",
                          message: "source/target required", details: nil))
      return
    }
    #if canImport(Translation)
    if #available(iOS 18.0, *) {
      AppleTranslatorRunner.run(mode: .prepare,
                                source: source, target: target) { res in
        DispatchQueue.main.async {
          switch res {
          case .success:
            result(nil)
          case .failure(let err):
            result(FlutterError(code: "prepare_failed",
                                message: err.localizedDescription,
                                details: nil))
          }
        }
      }
      return
    }
    #endif
    // Silently no-op on older iOS — the caller handles unavailable case when
    // the actual translate() call comes through.
    result(nil)
  }
}

#if canImport(Translation)

@available(iOS 18.0, *)
fileprivate final class AppleTranslatorRunnerHolder {
  weak var host: UIViewController?
}

@available(iOS 18.0, *)
fileprivate enum AppleTranslatorMode {
  case translate(String)
  case prepare
}

@available(iOS 18.0, *)
fileprivate enum AppleTranslatorRunner {
  // Strong refs so the holder + host controller stay alive until
  // .translationTask fires. Cleared in the completion path.
  private static var pending: [AppleTranslatorRunnerHolder] = []

  static func run(mode: AppleTranslatorMode, source: String, target: String,
                  completion: @escaping (Result<String, Error>) -> Void) {
    DispatchQueue.main.async {
      guard let rootVC = activeRootViewController() else {
        completion(.failure(NSError(
          domain: "AppleTranslator", code: -1,
          userInfo: [NSLocalizedDescriptionKey: "No root view controller available"])))
        return
      }
      let holder = AppleTranslatorRunnerHolder()
      pending.append(holder)
      let view = TranslateRunnerView(
        mode: mode, source: source, target: target
      ) { res in
        completion(res)
        DispatchQueue.main.async {
          holder.host?.willMove(toParent: nil)
          holder.host?.view.removeFromSuperview()
          holder.host?.removeFromParent()
          pending.removeAll { $0 === holder }
        }
      }
      let host = UIHostingController(rootView: view)
      host.view.translatesAutoresizingMaskIntoConstraints = false
      host.view.isUserInteractionEnabled = false
      host.view.alpha = 0
      holder.host = host
      rootVC.addChild(host)
      rootVC.view.addSubview(host.view)
      NSLayoutConstraint.activate([
        host.view.widthAnchor.constraint(equalToConstant: 1),
        host.view.heightAnchor.constraint(equalToConstant: 1),
        host.view.topAnchor.constraint(equalTo: rootVC.view.topAnchor),
        host.view.leadingAnchor.constraint(equalTo: rootVC.view.leadingAnchor),
      ])
      host.didMove(toParent: rootVC)
    }
  }

  private static func activeRootViewController() -> UIViewController? {
    for scene in UIApplication.shared.connectedScenes {
      guard let windowScene = scene as? UIWindowScene else { continue }
      let window =
        windowScene.windows.first(where: { $0.isKeyWindow })
        ?? windowScene.windows.first
      if let root = window?.rootViewController {
        return root.presentedViewController ?? root
      }
    }
    return nil
  }
}

@available(iOS 18.0, *)
fileprivate struct TranslateRunnerView: View {
  let mode: AppleTranslatorMode
  let source: String
  let target: String
  let onResult: (Result<String, Error>) -> Void
  @State private var fired = false

  var body: some View {
    Color.clear
      .translationTask(
        TranslationSession.Configuration(
          source: Locale.Language(identifier: source),
          target: Locale.Language(identifier: target))
      ) { session in
        guard !fired else { return }
        fired = true
        do {
          switch mode {
          case .translate(let text):
            let response = try await session.translate(text)
            onResult(.success(response.targetText))
          case .prepare:
            // Triggers the iOS "Download language" prompt if the pair isn't
            // already installed; returns once the pair is ready.
            try await session.prepareTranslation()
            onResult(.success(""))
          }
        } catch {
          onResult(.failure(error))
        }
      }
  }
}

#endif

/// On-device full-file speech recognition + language probing, bridged to
/// Dart over `app.translate/apple_file_asr`. Powers the fully-local
/// "整段重识别" path:
///   detect    — trim the head of the file (~10s) and run it through an
///               on-device recognizer per candidate locale; the locale whose
///               final transcription has the highest duration-weighted
///               confidence wins.
///   recognize — run the whole file through the winning locale, returning
///               word-level timestamps so Dart can rebuild subtitle cards.
///
/// Inlined here (same pattern as AudioFileWriter / AppleTranslator) so we
/// don't have to touch the Runner pbxproj.
@available(iOS 13.0, *)
public class AppleFileRecognizer: NSObject, FlutterPlugin {
  static let channelName = "app.translate/apple_file_asr"
  private static var heldChannel: FlutterMethodChannel?

  // Strong refs while recognition runs; SFSpeechRecognizer must outlive its
  // task or the task silently dies.
  private var activeRecognizers: [UUID: SFSpeechRecognizer] = [:]
  private var activeTasks: [UUID: SFSpeechRecognitionTask] = [:]

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName, binaryMessenger: registrar.messenger())
    let instance = AppleFileRecognizer()
    channel.setMethodCallHandler { [weak instance] call, result in
      instance?.handle(call, result: result)
    }
    heldChannel = channel
    registrar.publish(instance)
    instance.runDebugSelfTestIfRequested()
  }

  // Headless debug hook: drop Documents/debug_reasr.json
  //   {"file": "recordings/sess_xxx.m4a", "locale": "ja-JP"}
  // into the app container (e.g. via devicectl copy) and launch the app —
  // recognition runs automatically and NSLogs everything, no UI taps needed.
  // The trigger file is deleted so it fires once.
  private func runDebugSelfTestIfRequested() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
      guard let self = self,
            let docs = FileManager.default.urls(
              for: .documentDirectory, in: .userDomainMask).first else { return }
      let cfg = docs.appendingPathComponent("debug_reasr.json")
      guard let data = try? Data(contentsOf: cfg),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rel = obj["file"] as? String else { return }
      try? FileManager.default.removeItem(at: cfg)
      let audio = docs.appendingPathComponent(rel)
      let locale = obj["locale"] as? String ?? "ja-JP"
      NSLog("[FileASR-SelfTest] file=%@ locale=%@", audio.path, locale)
      SFSpeechRecognizer.requestAuthorization { st in
        guard st == .authorized else {
          NSLog("[FileASR-SelfTest] speech permission missing")
          return
        }
        self.recognizeFile(audio, locale: locale, startSeconds: 0,
                           maxSeconds: nil, timeout: 120) { res in
          switch res {
          case .success(let ws):
            NSLog("[FileASR-SelfTest] SUCCESS %d words", ws.count)
            for w in ws.prefix(100) {
              NSLog("[FileASR-SelfTest] %.2f-%.2f %@", w.begin, w.end, w.text)
            }
          case .failure(let e):
            NSLog("[FileASR-SelfTest] FAIL %@", e.localizedDescription)
          }
        }
      }
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "detect":
      handleDetect(call, result: result)
    case "recognize":
      handleRecognize(call, result: result)
    case "availability":
      handleAvailability(call, result: result)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // Per-locale on-device readiness, so Dart can prompt the user to download
  // the dictation language pack BEFORE running a recognition that would
  // silently score zero. Values: ok / no_ondevice / unavailable / no_recognizer.
  private func handleAvailability(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let candidates = args["candidates"] as? [String] else {
      result(FlutterError(code: "bad_args", message: "candidates required", details: nil))
      return
    }
    var out: [String: String] = [:]
    for loc in candidates {
      guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: loc)) else {
        out[loc] = "no_recognizer"
        continue
      }
      if !recognizer.isAvailable {
        out[loc] = "unavailable"
      } else if !recognizer.supportsOnDeviceRecognition {
        out[loc] = "no_ondevice"
      } else {
        out[loc] = "ok"
      }
    }
    result(out)
  }

  private func handleDetect(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String,
          let candidates = args["candidates"] as? [String], !candidates.isEmpty else {
      result(FlutterError(code: "bad_args", message: "path/candidates required", details: nil))
      return
    }
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      guard let self = self else { return }
      guard status == .authorized else {
        DispatchQueue.main.async {
          result(FlutterError(code: "no_permission",
                              message: "Speech recognition not authorized", details: nil))
        }
        return
      }
      let srcURL = URL(fileURLWithPath: path)
      // Skip leading silence, probe up to 10s of actual speech straight from
      // the file (buffer-fed — no temp clip export needed).
      let onset = self.findSpeechOnset(in: srcURL)
      let total = Self.audioDuration(of: srcURL)
      let probeSeconds = min(10.0, max(1.0, total - onset))
      var scores: [String: Double] = [:]
      var errors: [String: String] = [:]
      func reply() {
        let best = scores.max { $0.value < $1.value }
        // All-zero scores mean no candidate produced anything usable —
        // return "" instead of an arbitrary dictionary winner and let Dart
        // surface the per-locale errors.
        let locale = (best != nil && best!.value > 0) ? best!.key : ""
        DispatchQueue.main.async {
          result(["locale": locale, "scores": scores, "errors": errors])
        }
      }
      func probe(_ idx: Int) {
        if idx >= candidates.count { reply(); return }
        let loc = candidates[idx]
        self.recognizeFile(srcURL, locale: loc, startSeconds: onset,
                           maxSeconds: 10.0, timeout: 30) { res in
          switch res {
          case .success(let ws):
            // Coverage-first score: how much of the probe window did this
            // recognizer turn into words? A wrong-language recognizer
            // "hears" few/no words, the right one covers most of it.
            // Confidence only modulates (0.35 base weight) because on-device
            // results routinely report confidence == 0 for every segment.
            var num = 0.0
            for w in ws {
              num += (w.end - w.begin) * (0.35 + 0.65 * w.confidence)
            }
            scores[loc] = num / probeSeconds
          case .failure(let err):
            scores[loc] = 0
            errors[loc] = err.localizedDescription
          }
          probe(idx + 1)
        }
      }
      probe(0)
    }
  }

  private func handleRecognize(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let path = args["path"] as? String,
          let locale = args["locale"] as? String else {
      result(FlutterError(code: "bad_args", message: "path/locale required", details: nil))
      return
    }
    SFSpeechRecognizer.requestAuthorization { [weak self] status in
      guard let self = self else { return }
      guard status == .authorized else {
        DispatchQueue.main.async {
          result(FlutterError(code: "no_permission",
                              message: "Speech recognition not authorized", details: nil))
        }
        return
      }
      self.recognizeFile(URL(fileURLWithPath: path), locale: locale,
                         startSeconds: 0, maxSeconds: nil, timeout: 600) { res in
        DispatchQueue.main.async {
          switch res {
          case .success(let ws):
            var words: [[String: Any]] = []
            for w in ws {
              words.append([
                "beginMs": Int(w.begin * 1000),
                "endMs": Int(w.end * 1000),
                "text": w.text,
              ])
            }
            result([
              "text": ws.map { $0.text }.joined(separator: " "),
              "words": words,
            ])
          case .failure(let err):
            result(FlutterError(code: "recognize_failed",
                                message: err.localizedDescription, details: nil))
          }
        }
      }
    }
  }

  // Run one on-device recognition over a file region by decoding it with
  // AVAudioFile and feeding buffers to SFSpeechAudioBufferRecognitionRequest —
  // the same pipeline the (working) live mic path uses. The URL-request API
  // (SFSpeechURLRecognitionRequest) silently returned empty results in
  // requiresOnDeviceRecognition mode, which broke both language probing and
  // full-file recognition.
  //
  // Segment timestamps are relative to the fed region, so callers that need
  // file-relative times must pass startSeconds = 0.
  private func recognizeFile(
    _ url: URL, locale: String, startSeconds: Double, maxSeconds: Double?,
    timeout: TimeInterval,
    completion: @escaping (Result<[FileASRWord], Error>) -> Void
  ) {
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)),
          recognizer.isAvailable else {
      completion(.failure(Self.err("recognizer unavailable for \(locale)")))
      return
    }
    guard recognizer.supportsOnDeviceRecognition else {
      completion(.failure(Self.err(
        "on-device recognition unsupported for \(locale) — download the keyboard dictation language in iOS Settings")))
      return
    }
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    request.taskHint = .dictation
    if #available(iOS 16.0, *) {
      request.addsPunctuation = true
    }
    let id = UUID()
    // On-device dictation restarts its transcription at every internal
    // utterance boundary (pause): bestTranscription RESETS instead of
    // growing, and the isFinal callback only carries the LAST utterance —
    // usually the trailing silence, i.e. empty. So we accumulate: when a
    // callback's transcription no longer starts where the previous one did,
    // the previous utterance is done — commit its segments and keep going.
    // The final transcript = committed segments + the last in-flight ones.
    var committed: [FileASRWord] = []
    var current: SFTranscription?
    func words(of t: SFTranscription) -> [FileASRWord] {
      t.segments.compactMap { seg in
        let txt = seg.substring.trimmingCharacters(in: .whitespaces)
        if txt.isEmpty { return nil }
        return FileASRWord(
          begin: seg.timestamp, end: seg.timestamp + seg.duration,
          confidence: Double(seg.confidence), text: txt)
      }
    }
    func collectAll() -> [FileASRWord] {
      committed + (current.map(words(of:)) ?? [])
    }
    // finish() may fire from the recognizer's queue or the timeout timer;
    // serialize through main so the guard flag isn't racy.
    var finished = false
    let finish: (Result<[FileASRWord], Error>) -> Void = { [weak self] r in
      DispatchQueue.main.async {
        if finished { return }
        finished = true
        self?.activeTasks[id]?.cancel()
        self?.activeTasks.removeValue(forKey: id)
        self?.activeRecognizers.removeValue(forKey: id)
        completion(r)
      }
    }
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.activeRecognizers[id] = recognizer
      NSLog("[FileASR] start locale=%@ start=%.1fs max=%@", locale, startSeconds,
            maxSeconds.map { String($0) } ?? "all")
      let task = recognizer.recognitionTask(with: request) { res, err in
        if let res = res {
          let t = res.bestTranscription
          let firstTs = t.segments.first?.timestamp ?? -1
          // Observed callback pattern per utterance:
          //   1. growing partials, timestamps PROVISIONAL (t0 ≈ 0)
          //   2. one RE-TIMED result: same text, timestamps corrected to
          //      absolute stream positions (t0 jumps)
          //   3. next utterance's partials start over with short text
          // So: same-ish text + t0 jump ⇒ commit the RE-TIMED version (the
          // one with correct absolute times) and clear; text collapse ⇒ new
          // utterance began without a re-time event — commit the provisional
          // current as fallback.
          if let cur = current, let curFirst = cur.segments.first {
            let curLen = cur.formattedString.count
            let newLen = t.formattedString.count
            let t0Changed = abs(firstTs - curFirst.timestamp) > 0.01
            if t0Changed && !t.segments.isEmpty
                && newLen >= max(1, (curLen * 8) / 10) {
              committed += words(of: t)
              current = nil
            } else if t.segments.isEmpty || newLen < max(2, curLen / 2) {
              committed += words(of: cur)
              current = t.segments.isEmpty ? nil : t
            } else {
              current = t
            }
          } else {
            current = t.segments.isEmpty ? nil : t
          }
          if res.isFinal {
            finish(.success(collectAll()))
            return
          }
        }
        if let err = err {
          NSLog("[FileASR] %@ error: %@", locale, err.localizedDescription)
          let all = collectAll()
          if all.isEmpty {
            finish(.failure(err))
          } else {
            finish(.success(all))
          }
        }
      }
      self.activeTasks[id] = task

      // Decode + feed off the main thread. Throttled to ~20× realtime: the
      // on-device recognizer has been seen dropping ALL audio when a file is
      // blasted in one burst followed by an immediate endAudio.
      DispatchQueue.global(qos: .userInitiated).async {
        var fedFrames: Int64 = 0
        do {
          let file = try AVAudioFile(forReading: url)
          let fmt = file.processingFormat
          let sr = fmt.sampleRate
          if startSeconds > 0 {
            file.framePosition = AVAudioFramePosition(startSeconds * sr)
          }
          var remaining = maxSeconds.map { AVAudioFramePosition($0 * sr) }
            ?? AVAudioFramePosition.max
          let chunkFrames = AVAudioFrameCount(sr * 0.5)
          while remaining > 0 {
            // Bound by the file's own length so we stop cleanly at EOF
            // instead of tripping AVAudioFile's read-past-end exception.
            let left = file.length - file.framePosition
            if left <= 0 { break }
            let toRead = AVAudioFrameCount(
              min(AVAudioFramePosition(chunkFrames), min(remaining, left)))
            guard let buf = AVAudioPCMBuffer(
              pcmFormat: fmt, frameCapacity: toRead) else { break }
            try file.read(into: buf, frameCount: toRead)
            if buf.frameLength == 0 { break }
            request.append(buf)
            fedFrames += Int64(buf.frameLength)
            remaining -= AVAudioFramePosition(buf.frameLength)
            // 0.5s of audio per 25ms wall clock ≈ 20× realtime.
            usleep(25_000)
          }
          NSLog("[FileASR] %@ fed %.1fs, endAudio", locale,
                Double(fedFrames) / sr)
        } catch {
          NSLog("[FileASR] %@ feed error after %lld frames: %@", locale,
                fedFrames, error.localizedDescription)
        }
        request.endAudio()
      }

      DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
        let all = collectAll()
        if all.isEmpty {
          finish(.failure(Self.err("recognition timed out after \(Int(timeout))s")))
        } else {
          finish(.success(all))
        }
      }
    }
  }

  // One recognized word/token with file-region-relative timing.
  struct FileASRWord {
    let begin: Double
    let end: Double
    let confidence: Double
    let text: String
  }

  // Decoded length of an audio file in seconds (0 on failure).
  private static func audioDuration(of url: URL) -> Double {
    guard let file = try? AVAudioFile(forReading: url) else { return 0 }
    let sr = file.processingFormat.sampleRate
    guard sr > 0 else { return 0 }
    return Double(file.length) / sr
  }

  // Energy-based VAD: find where speech starts so the language probe doesn't
  // burn its window on leading silence. Scans 100ms RMS hops with an adaptive
  // noise floor; "speech" = 3 consecutive hops above threshold. Returns the
  // onset in seconds (backed off 0.25s), or 0 on any failure.
  private func findSpeechOnset(in url: URL) -> Double {
    guard let file = try? AVAudioFile(forReading: url) else { return 0 }
    let fmt = file.processingFormat
    let hop = AVAudioFrameCount(fmt.sampleRate * 0.1)
    guard hop > 0,
          let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: hop) else {
      return 0
    }
    var noiseFloor = Double.greatestFiniteMagnitude
    var run = 0
    var idx = 0
    // Cap the scan at 10 minutes so a pathological file can't stall detect.
    while idx < 6000 {
      buf.frameLength = 0
      do { try file.read(into: buf, frameCount: hop) } catch { break }
      let n = Int(buf.frameLength)
      if n == 0 { break }
      guard let ch = buf.floatChannelData?[0] else { break }
      var sum = 0.0
      for i in 0..<n {
        let v = Double(ch[i])
        sum += v * v
      }
      let rms = (sum / Double(n)).squareRoot()
      noiseFloor = min(noiseFloor, max(rms, 0.0005))
      let threshold = max(noiseFloor * 4, 0.01)
      if rms > threshold {
        run += 1
        if run >= 3 {
          return max(0, Double(idx - run + 1) * 0.1 - 0.25)
        }
      } else {
        run = 0
      }
      idx += 1
    }
    return 0
  }

  private static func err(_ msg: String) -> NSError {
    return NSError(
      domain: "AppleFileRecognizer", code: -1,
      userInfo: [NSLocalizedDescriptionKey: msg])
  }
}
