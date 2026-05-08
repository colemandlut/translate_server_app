import AVFoundation
import Flutter
import UIKit

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
      let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "AudioFileWriter")!
      AudioFileWriter.register(with: registrar)
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
