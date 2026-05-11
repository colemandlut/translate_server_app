import AVFoundation
import Flutter
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
