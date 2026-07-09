import Speech
import CwlCatchException
import os.log

#if os(OSX)
  import FlutterMacOS
  import Cocoa
  import AVFoundation
#else
  import Flutter
  import UIKit
#endif

public enum SwiftSpeechToTextMethods: String {
  case has_permission
  case initialize
  case listen
  case stop
  case cancel
  case locales
  case unknown  // just for testing
}

public enum SwiftSpeechToTextCallbackMethods: String {
  case textRecognition
  case notifyStatus
  case notifyError
  case soundLevelChange
}

public enum SpeechToTextStatus: String {
  case listening
  case notListening
  case unavailable
  case available
  case done
  case doneNoResult
}

public enum SpeechToTextErrors: String {
  case onDeviceError
  case noRecognizerError
  case listenFailedError
  case missingOrInvalidArg
}

public enum ListenMode: Int {
  case deviceDefault = 0
  case dictation = 1
  case search = 2
  case confirmation = 3
}

struct SpeechRecognitionWords: Codable {
  let recognizedWords: String
  let recognizedPhrases: [String]?
  let confidence: Decimal
}

struct SpeechRecognitionResult: Codable {
  let alternates: [SpeechRecognitionWords]
  let finalResult: Bool
}

struct SpeechRecognitionError: Codable {
  let errorMsg: String
  let permanent: Bool
}

enum SpeechToTextError: Error {
  case runtimeError(String)
}

@available(iOS 10.0, macOS 10.15, *)
public class SpeechToTextPlugin: NSObject, FlutterPlugin {
  private var channel: FlutterMethodChannel
  private var registrar: FlutterPluginRegistrar
  private var recognizer: SFSpeechRecognizer?
  private var currentRequest: SFSpeechAudioBufferRecognitionRequest?
  private var currentTask: SFSpeechRecognitionTask?
  private var listeningSound: AVAudioPlayer?
  private var successSound: AVAudioPlayer?
  private var cancelSound: AVAudioPlayer?

  #if os(iOS)
    private var rememberedAudioCategory: AVAudioSession.Category?
    private var rememberedAudioCategoryOptions: AVAudioSession.CategoryOptions?
    private let audioSession = AVAudioSession.sharedInstance()
  #endif

  private var previousLocale: Locale?
  private var onPlayEnd: (() -> Void)?
  private var returnPartialResults: Bool = true
  private var failedListen: Bool = false
  private var onDeviceStatus: Bool = false
  private var listening = false
  private var stopping = false
  private var audioEngine: AVAudioEngine?
  private var inputNode: AVAudioInputNode?
  private var aggregateResults: SpeechResultAggregator = SpeechResultAggregator()
  private let jsonEncoder = JSONEncoder()
  private let busForNodeTap = 0
  private let speechBufferSize: AVAudioFrameCount = 1024
  private static var subsystem = Bundle.main.bundleIdentifier!
  private let pluginLog = OSLog(subsystem: "com.csdcorp.speechToText", category: "plugin")

  // Side-channel that emits one (post-gain) 16kHz mono Int16 LE PCM blob per
  // SFSpeech final, so the app can run cloud secondary recognition without
  // opening a second AVAudioSession. We accumulate per-utterance and flush
  // immediately before invokeFlutter(textRecognition) so the audio buffer event
  // is guaranteed to reach Dart before the matching final result.
  // Dedicated channel for shipping post-gain 16kHz mono Int16 LE PCM blobs to
  // Dart, one blob per SFSpeech final. Using a MethodChannel (not EventChannel)
  // because EventChannel's listen handshake is async and we'd lose the first
  // utterance; with MethodChannel we just invoke whenever we have data.
  private var audioMethodChannel: FlutterMethodChannel?
  private var pcmAccumulator = Data()
  private let pcmAccumulatorLock = NSLock()
  // Plugin-owned m4a/AAC writer for the Apple recording archive. Going
  // through Dart via method channel (per-buffer or batched) crashed; writing
  // directly from the audio tap avoids any cross-thread dispatch overhead.
  // The file is opened lazily on the first buffer so we can match the input
  // format exactly — that way AAC encoder doesn't have to resample, which
  // was the source of remaining buffer-boundary clicks.
  private var recordingFile: AVAudioFile?
  private var recordingFilePendingPath: String?
  private let recordingFileLock = NSLock()
  // Cached AVAudioConverter for the 48kHz→16kHz downsample. Building a fresh
  // one per audio tap buffer (we used to) gives the resampling filter no
  // cross-buffer context, so 3:1 decimation produces a phase discontinuity
  // at every buffer boundary — audible as crackle. Cached converters keep
  // their internal state across calls. Reset whenever a fresh AVAudioEngine
  // is initialized (input format may change).
  private var cachedDownsampleConverter: AVAudioConverter?
  private var cachedDownsampleInputFormat: AVAudioFormat?
  // When true, `stop` only finalizes the current SFSpeech task and leaves the
  // AVAudioEngine + tap running so the next `listen` can re-attach to a still-
  // open audio stream. Used by clients (Apple-mode recording) that want a
  // continuous file across silence-induced auto-restart cycles. The Dart side
  // must call `fullStop` when the user actually stops, to tear the engine
  // down and release the audio session.
  private var keepAudioEngineAlive = false
  private static let audioBufferTargetFormat: AVAudioFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 16000.0, channels: 1, interleaved: true
  )!

  public static func register(with registrar: FlutterPluginRegistrar) {

    var channel: FlutterMethodChannel
    var audioChannel: FlutterMethodChannel
    #if os(OSX)
      channel = FlutterMethodChannel(
        name: "plugin.csdcorp.com/speech_to_text", binaryMessenger: registrar.messenger)
      audioChannel = FlutterMethodChannel(
        name: "plugin.csdcorp.com/speech_to_text/audio_buffer", binaryMessenger: registrar.messenger)
    #else
      channel = FlutterMethodChannel(
        name: "plugin.csdcorp.com/speech_to_text", binaryMessenger: registrar.messenger())
      audioChannel = FlutterMethodChannel(
        name: "plugin.csdcorp.com/speech_to_text/audio_buffer", binaryMessenger: registrar.messenger())

    #endif

    let instance = SpeechToTextPlugin(channel, registrar: registrar)
    registrar.addMethodCallDelegate(instance, channel: channel)
    instance.audioMethodChannel = audioChannel
  }

  init(_ channel: FlutterMethodChannel, registrar: FlutterPluginRegistrar) {
    self.channel = channel
    self.registrar = registrar
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case SwiftSpeechToTextMethods.has_permission.rawValue:
      hasPermission(result)
    case SwiftSpeechToTextMethods.initialize.rawValue:
        if #available(iOS 13.0, *) {
            Task {
                initialize(result)
            }
        } else {
            initialize(result)
        }
    case SwiftSpeechToTextMethods.listen.rawValue:
      guard let argsArr = call.arguments as? [String: AnyObject],
        let partialResults = argsArr["partialResults"] as? Bool,
        let onDevice = argsArr["onDevice"] as? Bool,
        let listenModeIndex = argsArr["listenMode"] as? Int,
        let sampleRate = argsArr["sampleRate"] as? Int,
        let autoPunctuation = argsArr["autoPunctuation"] as? Bool,
        let enableHaptics = argsArr["enableHaptics"] as? Bool
      else {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: SpeechToTextErrors.missingOrInvalidArg.rawValue,
              message:
                "Missing arg partialResults, onDevice, listenMode, autoPunctuatio, enableHaptics and sampleRate are required",
              details: nil))
        }
        return
      }
      var localeStr: String? = nil
      if let localeParam = argsArr["localeId"] as? String {
        localeStr = localeParam
      }
      guard let listenMode = ListenMode(rawValue: listenModeIndex) else {
        DispatchQueue.main.async {
          result(
            FlutterError(
              code: SpeechToTextErrors.missingOrInvalidArg.rawValue,
              message: "invalid value for listenMode, must be 0-2, was \(listenModeIndex)",
              details: nil))
        }
        return
      }
        if #available(iOS 13.0, *) {
            Task {
                listenForSpeech(
                    result, localeStr: localeStr, partialResults: partialResults, onDevice: onDevice,
                    listenMode: listenMode, sampleRate: sampleRate, autoPunctuation: autoPunctuation,
                    enableHaptics: enableHaptics)
            }
        } else {
            listenForSpeech(
                result, localeStr: localeStr, partialResults: partialResults, onDevice: onDevice,
                listenMode: listenMode, sampleRate: sampleRate, autoPunctuation: autoPunctuation,
                enableHaptics: enableHaptics)
        }
    case SwiftSpeechToTextMethods.stop.rawValue:
        if #available(iOS 13.0, *) {
            Task {
                stopSpeech(result)
            }
        } else {
            stopSpeech(result)
        }
    case SwiftSpeechToTextMethods.cancel.rawValue:
        if #available(iOS 13.0, *) {
            Task {
                cancelSpeech(result)
            }
        } else {
            cancelSpeech(result)
        }
    case SwiftSpeechToTextMethods.locales.rawValue:
        if #available(iOS 13.0, *) {
            Task {
                locales(result)
            }
        } else {
            locales(result)
        }
    case "setKeepAudioEngineAlive":
        if let v = call.arguments as? Bool {
            self.keepAudioEngineAlive = v
            NSLog("[stt-fork] keepAudioEngineAlive=%@", v ? "true" : "false")
        }
        result(true)
    case "fullStop":
        // Tear the audio engine + tap down. Used by clients that asked for
        // keepAudioEngineAlive — without this, the engine would stay running
        // forever after the user stops listening.
        fullStop(result)
    case "openRecordingFile":
        guard let path = (call.arguments as? [String: Any])?["path"] as? String else {
          result(FlutterError(code: "bad_args", message: "path required", details: nil))
          return
        }
        openRecordingFile(at: path, result: result)
    case "closeRecordingFile":
        closeRecordingFile()
        result(true)
    default:
      os_log("Unrecognized method: %{PUBLIC}@", log: pluginLog, type: .error, call.method)
      DispatchQueue.main.async {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func hasPermission(_ result: @escaping FlutterResult) {
    var has =
      SFSpeechRecognizer.authorizationStatus() == SFSpeechRecognizerAuthorizationStatus.authorized
    #if os(iOS)
      has = has && self.audioSession.recordPermission == AVAudioSession.RecordPermission.granted
    #else
      has = has && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    #endif

    DispatchQueue.main.async {
      result(has)
    }
  }

  private func initialize(_ result: @escaping FlutterResult) {
    var success = false
    let status = SFSpeechRecognizer.authorizationStatus()
    switch status {
    case SFSpeechRecognizerAuthorizationStatus.notDetermined:
      SFSpeechRecognizer.requestAuthorization({ (status) -> Void in
        success = status == SFSpeechRecognizerAuthorizationStatus.authorized
        if success {

          #if os(iOS)

            self.audioSession.requestRecordPermission({ (granted: Bool) -> Void in
              if granted {
                self.setupSpeechRecognition(result)
              } else {
                self.sendBoolResult(false, result)
                os_log("User denied permission", log: self.pluginLog, type: .info)
              }
            })

          #else
            self.requestMacOSMicrophonePermission { success in
              if success {
                self.setupSpeechRecognition(result)
              } else {
                self.sendBoolResult(false, result)
                os_log("User denied permission", log: self.pluginLog, type: .info)
              }
            }
          #endif
        } else {
          self.sendBoolResult(false, result)
        }
      })
    case SFSpeechRecognizerAuthorizationStatus.denied:
      os_log("Permission permanently denied", log: self.pluginLog, type: .info)
      sendBoolResult(false, result)
    case SFSpeechRecognizerAuthorizationStatus.restricted:
      os_log("Device restriction prevented initialize", log: self.pluginLog, type: .info)
      sendBoolResult(false, result)
    default:
      os_log("Has permissions continuing with setup", log: self.pluginLog, type: .debug)
      setupSpeechRecognition(result)
    }
  }

  fileprivate func sendBoolResult(_ value: Bool, _ result: @escaping FlutterResult) {
    DispatchQueue.main.async {
      result(value)
    }
  }

  fileprivate func setupListeningSound() {
    listeningSound = loadSound("assets/sounds/speech_to_text_listening.m4r")
    successSound = loadSound("assets/sounds/speech_to_text_stop.m4r")
    cancelSound = loadSound("assets/sounds/speech_to_text_cancel.m4r")
  }

  fileprivate func loadSound(_ assetPath: String) -> AVAudioPlayer? {
    var player: AVAudioPlayer? = nil
    let soundKey = registrar.lookupKey(forAsset: assetPath)
    guard !soundKey.isEmpty else {
      return player
    }
    
    if let soundPath = Bundle.main.path(forResource: soundKey, ofType: nil) {
      let soundUrl = URL(fileURLWithPath: soundPath)
      do {
        player = try AVAudioPlayer(contentsOf: soundUrl)
        player?.delegate = self
      } catch {
        // no audio
      }
    }
    return player
  }

  private func requestMacOSMicrophonePermission(completion: @escaping (Bool) -> Void) {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
      completion(true)

    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .audio) { granted in
        if granted {
          completion(granted)
        } else {
          completion(granted)
        }
      }

    case .denied, .restricted:
      completion(false)

    @unknown default:
      completion(false)
    }
  }

  private func setupSpeechRecognition(_ result: @escaping FlutterResult) {
    setupRecognizerForLocale(locale: Locale.current)
    guard recognizer != nil else {
      sendBoolResult(false, result)
      return
    }
    if #available(iOS 13.0, *), let localRecognizer = recognizer {
      onDeviceStatus = localRecognizer.supportsOnDeviceRecognition
    }
    recognizer?.delegate = self
    setupListeningSound()

    sendBoolResult(true, result)
  }

  private func initAudioEngine(_ result: @escaping FlutterResult) -> Bool {
    audioEngine = AVAudioEngine()
    inputNode = audioEngine?.inputNode
    if inputNode == nil {
      os_log("Error no input node", log: pluginLog, type: .error)
      sendBoolResult(false, result)
    }
    return inputNode != nil
  }

  private func setupRecognizerForLocale(locale: Locale) {
    if previousLocale == locale {
      return
    }
    previousLocale = locale
    recognizer = SFSpeechRecognizer(locale: locale)
  }

  private func getLocale(_ localeStr: String?) -> Locale {
    guard let aLocaleStr = localeStr else {
      return Locale.current
    }
    let locale = Locale(identifier: aLocaleStr)
    return locale
  }

  private func stopSpeech(_ result: @escaping FlutterResult) {
    if !listening {
      sendBoolResult(false, result)
      return
    }
    stopping = true
    stopAllPlayers()
    self.currentTask?.finish()
    if keepAudioEngineAlive {
      // Leave audio engine + tap running; next listen() will reattach. Drop
      // listening/currentTask state so listenForSpeech's reentry guard
      // passes. KEEP stopping=true: didFinishSuccessfully fires async after
      // task.finish() and would otherwise call stopCurrentListen() (tearing
      // the engine down) when it sees stopping=false. listenForSpeech's
      // entry resets stopping=false naturally when reusing the engine.
      self.currentTask = nil
      self.listening = false
      invokeFlutter(
        SwiftSpeechToTextCallbackMethods.notifyStatus,
        arguments: SpeechToTextStatus.done.rawValue)
      sendBoolResult(true, result)
      return
    }
    if let sound = successSound {
      onPlayEnd = { () -> Void in
        self.stopCurrentListen()
        self.sendBoolResult(true, result)
        return
      }
      sound.play()
    } else {
      stopCurrentListen()
      sendBoolResult(true, result)
    }
  }

  private func fullStop(_ result: @escaping FlutterResult) {
    stopping = true
    stopAllPlayers()
    self.currentTask?.finish()
    closeRecordingFile()
    stopCurrentListen()
    sendBoolResult(true, result)
  }

  private func cancelSpeech(_ result: @escaping FlutterResult) {
    if !listening {
      sendBoolResult(false, result)
      return
    }
    stopping = true
    stopAllPlayers()
    self.currentTask?.cancel()
    if let sound = cancelSound {
      onPlayEnd = { () -> Void in
        self.stopCurrentListen()
        self.sendBoolResult(true, result)
        return
      }
      sound.play()
    } else {
      stopCurrentListen()
      sendBoolResult(true, result)
    }
  }

  private func stopAllPlayers() {
    cancelSound?.stop()
    successSound?.stop()
    listeningSound?.stop()
  }

  private func stopCurrentListen() {
    self.currentRequest?.endAudio()
    stopAllPlayers()
    do {
      try catchExceptionAsError {
        self.audioEngine?.stop()
      }
    } catch {
      os_log(
        "Error stopping engine: %{PUBLIC}@", log: pluginLog, type: .error,
        error.localizedDescription)
    }
    do {
      try catchExceptionAsError {
        self.inputNode?.removeTap(onBus: self.busForNodeTap)
      }
    } catch {
      os_log(
        "Error removing trap: %{PUBLIC}@", log: pluginLog, type: .error, error.localizedDescription)
    }
    #if os(iOS)
      do {
        if let rememberedAudioCategory = rememberedAudioCategory,
          let rememberedAudioCategoryOptions = rememberedAudioCategoryOptions
        {
          try self.audioSession.setCategory(
            rememberedAudioCategory, options: rememberedAudioCategoryOptions)
        }
      } catch {
        os_log(
          "Error stopping listen: %{PUBLIC}@", log: pluginLog, type: .error,
          error.localizedDescription)
      }
      do {
        try self.audioSession.setActive(false, options: .notifyOthersOnDeactivation)
      } catch {
        os_log(
          "Error deactivation: %{PUBLIC}@", log: pluginLog, type: .info, error.localizedDescription)
      }

    #endif
    self.invokeFlutter(
      SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: SpeechToTextStatus.done.rawValue)

    currentRequest = nil
    currentTask = nil
    onPlayEnd = nil
    listening = false
    stopping = false
  }

  private func listenForSpeech(
    _ result: @escaping FlutterResult, localeStr: String?, partialResults: Bool,
    onDevice: Bool, listenMode: ListenMode, sampleRate: Int, autoPunctuation: Bool,
    enableHaptics: Bool
  ) {
    if nil != currentTask || listening {
      sendBoolResult(false, result)
      return
    }
    // Reuse the audio engine + tap if a previous listen() finished its task
    // but kept the engine alive (keepAudioEngineAlive mode). Keeps the audio
    // stream continuous across silence-induced auto-restart cycles, which is
    // what the in-app recording archive needs.
    let reuseAudioEngine = keepAudioEngineAlive
      && (self.audioEngine?.isRunning ?? false)
      && self.inputNode != nil
    do {
      //    let inErrorTest = true
      failedListen = false
      stopping = false
      returnPartialResults = partialResults
      aggregateResults = SpeechResultAggregator()
      setupRecognizerForLocale(locale: getLocale(localeStr))
      guard let localRecognizer = recognizer else {
        result(
          FlutterError(
            code: SpeechToTextErrors.noRecognizerError.rawValue,
            message: "Failed to create speech recognizer",
            details: nil))
        return
      }
      if onDevice {
        if #available(iOS 13.0, *), !localRecognizer.supportsOnDeviceRecognition {
          result(
            FlutterError(
              code: SpeechToTextErrors.onDeviceError.rawValue,
              message: "on device recognition is not supported on this device",
              details: nil))
        }
      }

      if !reuseAudioEngine {
        #if os(iOS)
          rememberedAudioCategory = self.audioSession.category
          rememberedAudioCategoryOptions = self.audioSession.categoryOptions
          try self.audioSession.setCategory(
            AVAudioSession.Category.playAndRecord,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP, .mixWithOthers])
          //            try self.audioSession.setMode(AVAudioSession.Mode.measurement)
          if sampleRate > 0 {
            try self.audioSession.setPreferredSampleRate(Double(sampleRate))
          }
          try self.audioSession.setMode(AVAudioSession.Mode.default)
          try self.audioSession.setActive(true, options: .notifyOthersOnDeactivation)
          if #available(iOS 13.0, *) {
            try self.audioSession.setAllowHapticsAndSystemSoundsDuringRecording(enableHaptics)
          }
        #endif
        if let sound = listeningSound {
          self.onPlayEnd = { () -> Void in
            if !self.failedListen {
              self.listening = true
              self.invokeFlutter(
                SwiftSpeechToTextCallbackMethods.notifyStatus,
                arguments: SpeechToTextStatus.listening.rawValue)

            }
          }
          sound.play()
        }
        if !initAudioEngine(result) {
          return
        }
        if inputNode?.inputFormat(forBus: 0).channelCount == 0 {
          throw SpeechToTextError.runtimeError("Not enough available inputs.")
        }
        pcmAccumulatorLock.lock()
        pcmAccumulator.removeAll(keepingCapacity: true)
        pcmAccumulatorLock.unlock()
        // Drop the cached resampling converter — input format may differ
        // from the previous engine and stale state would corrupt the first
        // few buffers.
        cachedDownsampleConverter = nil
        cachedDownsampleInputFormat = nil
        NSLog("[stt-fork] listen: cleared accumulator, starting fresh tap")
      } else {
        NSLog("[stt-fork] listen: reusing live audio engine + tap")
        // Engine + tap already running. Only the per-utterance accumulator
        // resets so secondary recognize sees just this utterance's audio.
        pcmAccumulatorLock.lock()
        pcmAccumulator.removeAll(keepingCapacity: true)
        pcmAccumulatorLock.unlock()
      }
      self.currentRequest = SFSpeechAudioBufferRecognitionRequest()
      guard let currentRequest = self.currentRequest else {
        sendBoolResult(false, result)
        return
      }
      currentRequest.shouldReportPartialResults = true
      if #available(iOS 13.0, *), onDevice {
        currentRequest.requiresOnDeviceRecognition = true
      }
      switch listenMode {
      case ListenMode.dictation:
        currentRequest.taskHint = SFSpeechRecognitionTaskHint.dictation
        break
      case ListenMode.search:
        currentRequest.taskHint = SFSpeechRecognitionTaskHint.search
        break
      case ListenMode.confirmation:
        currentRequest.taskHint = SFSpeechRecognitionTaskHint.confirmation
        break
      default:
        break
      }
      if #available(iOS 16.0, macOS 13, *) {
        currentRequest.addsPunctuation = autoPunctuation
      }
      self.currentTask = self.recognizer?.recognitionTask(with: currentRequest, delegate: self)
      if !reuseAudioEngine {
        let recordingFormat = inputNode?.outputFormat(forBus: self.busForNodeTap)
        var fmt: AVAudioFormat!
        #if os(iOS)

          let theSampleRate = audioSession.sampleRate

          fmt = AVAudioFormat(
            commonFormat: recordingFormat!.commonFormat, sampleRate: theSampleRate,
            channels: recordingFormat!.channelCount, interleaved: recordingFormat!.isInterleaved)

        #else
          let bus = 0
          fmt = self.inputNode?.inputFormat(forBus: bus)

        #endif
        try catchExceptionAsError {
          self.inputNode?.installTap(
            onBus: self.busForNodeTap, bufferSize: self.speechBufferSize, format: fmt
          ) { [weak self] (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
            // Read currentRequest dynamically (not via closure capture) so the
            // tap stays valid across keepAudioEngineAlive listen cycles. Each
            // listen() swaps in a new SFSpeechAudioBufferRecognitionRequest;
            // the tap just appends to whichever one is current.
            guard let self = self else { return }
            SpeechToTextPlugin.applyInputGain(buffer: buffer)
            self.currentRequest?.append(buffer)
            self.updateSoundLevel(buffer: buffer)
            self.broadcastResampledPCM(buffer: buffer)
            self.writeRecordingBuffer(buffer)
          }
        }
        //    if ( inErrorTest ){
        //        throw SpeechToTextError.runtimeError("for testing only")
        //    }
        self.audioEngine?.prepare()
        try self.audioEngine?.start()
      }
      if nil == listeningSound {
        listening = true
        self.invokeFlutter(
          SwiftSpeechToTextCallbackMethods.notifyStatus,
          arguments: SpeechToTextStatus.listening.rawValue)
      }
      sendBoolResult(true, result)
    } catch {
      failedListen = true
      os_log(
        "Error starting listen: %{PUBLIC}@", log: pluginLog, type: .error,
        error.localizedDescription)
      self.invokeFlutter(
        SwiftSpeechToTextCallbackMethods.notifyStatus,
        arguments: SpeechToTextStatus.notListening.rawValue)
      stopCurrentListen()
      sendBoolResult(false, result)
      // ensure the not listening signal is sent in the error case
      let speechError = SpeechRecognitionError(errorMsg: "error_listen_failed", permanent: true)
      do {
        let errorResult = try jsonEncoder.encode(speechError)
        invokeFlutter(
          SwiftSpeechToTextCallbackMethods.notifyError,
          arguments: String(data: errorResult, encoding: .utf8))
        invokeFlutter(
          SwiftSpeechToTextCallbackMethods.notifyStatus,
          arguments: SpeechToTextStatus.doneNoResult.rawValue)
      } catch {
        os_log("Could not encode JSON", log: pluginLog, type: .error)
      }
    }
  }

  // Adaptive software gain (simple AGC) applied to mic buffers before
  // SFSpeechRecognizer sees them. The old fixed ×2.0 wasn't enough for
  // far-field speech: distant voices stayed under Apple's internal VAD
  // threshold and got dropped. We track a slow-decaying running peak and
  // steer the gain so speech peaks land near agcTargetPeak — quiet/distant
  // input gets boosted by up to maxInputGain (+18dB), loud close-mic input
  // backs the gain off so it doesn't clip.
  static let maxInputGain: Float = 8.0
  static let minInputGain: Float = 1.0
  static let agcTargetPeak: Float = 0.7
  // Halves in ~2s of quiet at ~47 buffers/s so gain recovers after a loud
  // burst without pumping on every pause.
  static let agcPeakDecay: Float = 0.993
  private static var agcRunningPeak: Float = 0.1
  private static var agcGain: Float = 2.0

  static func applyInputGain(buffer: AVAudioPCMBuffer) {
    guard let channelData = buffer.floatChannelData else { return }
    let channelCount = Int(buffer.format.channelCount)
    let frameLength = Int(buffer.frameLength)
    if frameLength == 0 { return }

    var peak: Float = 0
    for ch in 0..<channelCount {
      let samples = channelData[ch]
      for i in 0..<frameLength {
        peak = max(peak, abs(samples[i]))
      }
    }
    // Rise instantly on loud input (prevents clipping), decay slowly.
    agcRunningPeak = max(peak, agcRunningPeak * agcPeakDecay)

    let desired = min(
      maxInputGain, max(minInputGain, agcTargetPeak / max(agcRunningPeak, 0.001)))
    // Smooth per-buffer so gain changes don't produce audible steps.
    agcGain += (desired - agcGain) * 0.2

    for ch in 0..<channelCount {
      let samples = channelData[ch]
      for i in 0..<frameLength {
        let amplified = samples[i] * agcGain
        samples[i] = max(-1.0, min(1.0, amplified))
      }
    }
  }

  private func broadcastResampledPCM(buffer: AVAudioPCMBuffer) {
    let inFmt = buffer.format
    // Reuse a cached converter so the resampling filter keeps its history
    // across buffers — building a fresh one per call introduced audible
    // boundary clicks (3:1 decimation needs streaming context). Reset is
    // handled by listenForSpeech when a new AVAudioEngine spins up.
    if cachedDownsampleConverter == nil
      || cachedDownsampleInputFormat?.sampleRate != inFmt.sampleRate
      || cachedDownsampleInputFormat?.channelCount != inFmt.channelCount {
      cachedDownsampleConverter = AVAudioConverter(
        from: inFmt, to: SpeechToTextPlugin.audioBufferTargetFormat)
      cachedDownsampleInputFormat = inFmt
    }
    guard let converter = cachedDownsampleConverter else { return }

    let outCapacity =
      AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / inFmt.sampleRate) + 64
    guard let outBuffer = AVAudioPCMBuffer(
      pcmFormat: SpeechToTextPlugin.audioBufferTargetFormat, frameCapacity: outCapacity)
    else { return }

    var error: NSError?
    var consumed = false
    let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
      if consumed {
        // .noDataNow keeps the converter alive across buffers; .endOfStream
        // would lock it into a finished state and silently drop every
        // subsequent buffer (manifests as ~100ms accumulator only).
        outStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      outStatus.pointee = .haveData
      return buffer
    }
    if error != nil { return }
    if status == .error { return }

    let frameCount = Int(outBuffer.frameLength)
    if frameCount == 0 { return }
    guard let int16Ptr = outBuffer.int16ChannelData?.pointee else { return }
    let bufferPtr = UnsafeBufferPointer(start: int16Ptr, count: frameCount)
    let chunk = Data(buffer: bufferPtr)

    // Append synchronously under a lock so flushPcmAccumulator (called on main
    // from the SFSpeech final delegate) sees everything that the audio tap
    // produced — main-async dispatching here would lose chunks that are still
    // queued behind the delegate's main-thread work.
    pcmAccumulatorLock.lock()
    pcmAccumulator.append(chunk)
    pcmAccumulatorLock.unlock()
    // Recording file is fed from the audio tap closure with the raw native
    // buffer (no resampling), so we don't write outBuffer here.
  }

  /// Write the audio tap buffer (in its native input format) to the recording
  /// file, lazily opening the file on the first buffer to lock its sample
  /// rate / channel count to whatever the audio engine is producing. This
  /// avoids any AAC-side resampling, which is what was causing residual
  /// clicks at audio buffer boundaries.
  private func writeRecordingBuffer(_ buffer: AVAudioPCMBuffer) {
    recordingFileLock.lock()
    defer { recordingFileLock.unlock() }
    if recordingFile == nil && recordingFilePendingPath != nil {
      openRecordingFileLockedIfNeeded(matching: buffer)
    }
    guard let file = recordingFile else { return }
    do {
      try file.write(from: buffer)
    } catch {
      NSLog("[stt-fork] recording write failed: %@", error.localizedDescription)
    }
  }

  private func openRecordingFile(at path: String, result: @escaping FlutterResult) {
    recordingFileLock.lock()
    defer { recordingFileLock.unlock() }
    // Defer the actual AVAudioFile open until we see the first audio tap
    // buffer — that way we use buffer's native format (commonly 48kHz Float32
    // mono) for both `commonFormat` and the file's `AVSampleRateKey`, so AAC
    // encoder doesn't have to resample. Resampling at the buffer boundary
    // produced audible clicks even with a cached AVAudioConverter.
    recordingFilePendingPath = path
    recordingFile = nil
    result(true)
  }

  /// Lazily opens the recording AVAudioFile using the buffer's native format.
  /// Caller already holds recordingFileLock.
  private func openRecordingFileLockedIfNeeded(matching buffer: AVAudioPCMBuffer) {
    guard let path = recordingFilePendingPath, recordingFile == nil else { return }
    let inFmt = buffer.format
    do {
      let url = URL(fileURLWithPath: path)
      let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: Int(inFmt.sampleRate),
        AVNumberOfChannelsKey: Int(inFmt.channelCount),
        AVEncoderBitRateKey: 64000,
      ]
      recordingFile = try AVAudioFile(
        forWriting: url, settings: settings,
        commonFormat: inFmt.commonFormat, interleaved: inFmt.isInterleaved)
      recordingFilePendingPath = nil
    } catch {
      NSLog("[stt-fork] lazy openRecordingFile failed: %@", error.localizedDescription)
      recordingFilePendingPath = nil
    }
  }

  private func closeRecordingFile() {
    recordingFileLock.lock()
    // Releasing AVAudioFile flushes and finalizes the m4a's moov atom.
    recordingFile = nil
    recordingFilePendingPath = nil
    recordingFileLock.unlock()
  }

  // Called on main from handleResult, immediately before
  // invokeFlutter(textRecognition) for a final/maybeFinal result. Sends the
  // per-utterance PCM as one MethodChannel call then resets.
  private func flushPcmAccumulator() {
    pcmAccumulatorLock.lock()
    let snapshotLen = pcmAccumulator.count
    if pcmAccumulator.isEmpty {
      pcmAccumulatorLock.unlock()
      NSLog("[stt-fork] flush: accumulator empty, no send")
      return
    }
    let payload = pcmAccumulator
    pcmAccumulator.removeAll(keepingCapacity: true)
    pcmAccumulatorLock.unlock()
    guard let audioChannel = self.audioMethodChannel else {
      NSLog("[stt-fork] flush: audioMethodChannel nil, dropped %d bytes", snapshotLen)
      return
    }
    NSLog("[stt-fork] flush: dispatching %d bytes to dart", snapshotLen)
    DispatchQueue.main.async {
      audioChannel.invokeMethod("buffer", arguments: FlutterStandardTypedData(bytes: payload))
    }
  }

  private func updateSoundLevel(buffer: AVAudioPCMBuffer) {
    guard
      let channelData = buffer.floatChannelData
    else {
      return
    }

    let channelDataValue = channelData.pointee
    let channelDataValueArray = stride(
      from: 0,
      to: Int(buffer.frameLength),
      by: buffer.stride
    ).map { channelDataValue[$0] }
    let frameLength = Float(buffer.frameLength)
    let rms = sqrt(channelDataValueArray.map { $0 * $0 }.reduce(0, +) / frameLength)
    let avgPower = 20 * log10(rms)
    self.invokeFlutter(SwiftSpeechToTextCallbackMethods.soundLevelChange, arguments: avgPower)
  }

  /// Build a list of localId:name with the current locale first
  private func locales(_ result: @escaping FlutterResult) {
    var localeNames = [String]()
    let locales = SFSpeechRecognizer.supportedLocales()
    var currentLocaleId = Locale.current.identifier
    if Locale.preferredLanguages.count > 0 {
      currentLocaleId = Locale.preferredLanguages[0]
    }
    if let idName = buildIdNameForLocale(forIdentifier: currentLocaleId) {
      localeNames.append(idName)
    }
    for locale in locales {
      if locale.identifier == currentLocaleId {
        continue
      }
      if let idName = buildIdNameForLocale(forIdentifier: locale.identifier) {
        localeNames.append(idName)
      }
    }
    DispatchQueue.main.async {
      result(localeNames)
    }
  }

  private func buildIdNameForLocale(forIdentifier: String) -> String? {
    var idName: String?
    if let name = Locale.current.localizedString(forIdentifier: forIdentifier) {
      let sanitizedName = name.replacingOccurrences(of: ":", with: " ")
      idName = "\(forIdentifier):\(sanitizedName)"
    }
    return idName
  }

    private func handleResult(_ transcriptions: [SFTranscription], isFinal: Bool, maybeFinal: Bool) {
    if !isFinal && !returnPartialResults {
      return
    }
    aggregateResults = aggregateResults.addResult(transcriptions, isFinal: isFinal, maybeFinal: maybeFinal)
    let speechInfo = aggregateResults.results
    do {
      let speechMsg = try jsonEncoder.encode(speechInfo)
      if let speechStr = String(data: speechMsg, encoding: .utf8) {
        os_log("Encoded JSON result: %{PUBLIC}@", log: pluginLog, type: .debug, speechStr)
        if isFinal {
          NSLog("[stt-fork] handleResult: isFinal=true, flushing")
          flushPcmAccumulator()
        } else {
          NSLog("[stt-fork] handleResult: isFinal=false maybeFinal=%@ (no flush)", maybeFinal ? "true" : "false")
        }
        invokeFlutter(SwiftSpeechToTextCallbackMethods.textRecognition, arguments: speechStr)
      }
    } catch {
      os_log("Could not encode JSON", log: pluginLog, type: .error)
    }
  }

  private func confidenceIn(_ transcription: SFTranscription) -> Decimal {
    guard transcription.segments.count > 0 else {
      return 0
    }
    var totalConfidence: Float = 0.0
    for segment in transcription.segments {
      totalConfidence += segment.confidence
    }
    let avgConfidence: Float = totalConfidence / Float(transcription.segments.count)
    let confidence: Float = (avgConfidence * 1000).rounded() / 1000
    return Decimal(string: String(describing: confidence))!
  }

  private func invokeFlutter(_ method: SwiftSpeechToTextCallbackMethods, arguments: Any?) {
    if method != SwiftSpeechToTextCallbackMethods.soundLevelChange {
      os_log("invokeFlutter %{PUBLIC}@", log: pluginLog, type: .debug, method.rawValue)
    }
    DispatchQueue.main.async {
      self.channel.invokeMethod(method.rawValue, arguments: arguments)
    }
  }

}

@available(iOS 10.0, macOS 10.15, *)
@available(iOS 10.0, macOS 10.15, *)
extension SpeechToTextPlugin: SFSpeechRecognizerDelegate {
  public func speechRecognizer(
    _ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool
  ) {
    let availability =
      available ? SpeechToTextStatus.available.rawValue : SpeechToTextStatus.unavailable.rawValue
    os_log("Availability changed: %{PUBLIC}@", log: pluginLog, type: .debug, availability)
    invokeFlutter(SwiftSpeechToTextCallbackMethods.notifyStatus, arguments: availability)
  }
}

@available(iOS 10.0, macOS 10.15, *)
extension SpeechToTextPlugin: SFSpeechRecognitionTaskDelegate {
  public func speechRecognitionDidDetectSpeech(_ task: SFSpeechRecognitionTask) {
    // Do nothing for now
  }

  public func speechRecognitionTaskFinishedReadingAudio(_ task: SFSpeechRecognitionTask) {
    reportError(source: "FinishedReadingAudio", error: task.error)
    os_log("Finished reading audio", log: pluginLog, type: .debug)
    invokeFlutter(
      SwiftSpeechToTextCallbackMethods.notifyStatus,
      arguments: SpeechToTextStatus.notListening.rawValue)
  }

  public func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask) {
    reportError(source: "TaskWasCancelled", error: task.error)
    os_log("Canceled reading audio", log: pluginLog, type: .debug)
    invokeFlutter(
      SwiftSpeechToTextCallbackMethods.notifyStatus,
      arguments: SpeechToTextStatus.notListening.rawValue)
  }

  public func speechRecognitionTask(
    _ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool
  ) {
    reportError(source: "FinishSuccessfully", error: task.error)
    os_log("FinishSuccessfully", log: pluginLog, type: .debug)
    if !successfully {
      invokeFlutter(
        SwiftSpeechToTextCallbackMethods.notifyStatus,
        arguments: SpeechToTextStatus.doneNoResult.rawValue)
      if let err = task.error as NSError? {
        var errorMsg: String
        switch err.code {
        case 102:
          errorMsg = "error_assets_not_installed"
        case 201:
          errorMsg = "error_speech_recognizer_disabled"
        case 203:
          errorMsg = "error_retry"
        case 301:
          errorMsg = "error_request_cancelled"
        case 1100:
          errorMsg = "error_speech_recognizer_already_active"
        case 1101:
          errorMsg = "error_speech_recognizer_connection_invalidated"
        case 1107:
          errorMsg = "error_speech_recognizer_connection_interrupted"
        case 1110:
          errorMsg = "error_no_match"
        case 1700:
          errorMsg = "error_speech_recognizer_request_not_authorized"
        default:
          errorMsg = "error_unknown (\(err.code))"
        }
        let speechError = SpeechRecognitionError(errorMsg: errorMsg, permanent: true)
        do {
          let errorResult = try jsonEncoder.encode(speechError)
          invokeFlutter(
            SwiftSpeechToTextCallbackMethods.notifyError,
            arguments: String(data: errorResult, encoding: .utf8))
        } catch {
          os_log("Could not encode JSON", log: pluginLog, type: .error)
        }
      }
    }
    if !stopping {
      if let sound = successfully ? successSound : cancelSound {
        onPlayEnd = { () -> Void in
          self.stopCurrentListen()
        }
        sound.play()
      } else {
        stopCurrentListen()
      }
    }
  }

  public func speechRecognitionTask(
    _ task: SFSpeechRecognitionTask, didHypothesizeTranscription transcription: SFTranscription
  ) {
    os_log("HypothesizeTranscription", log: pluginLog, type: .debug)
    reportError(source: "HypothesizeTranscription", error: task.error)
      handleResult([transcription], isFinal: false, maybeFinal: false)
  }

  public func speechRecognitionTask(
    _ task: SFSpeechRecognitionTask,
    didFinishRecognition recognitionResult: SFSpeechRecognitionResult
  ) {
    reportError(source: "FinishRecognition", error: task.error)
    os_log(
      "FinishRecognition %{PUBLIC}@", log: pluginLog, type: .debug,
      recognitionResult.isFinal.description)
    var pseudoFinal = false
      if #available(iOS 14.0, macOS 13.0, *) {
          pseudoFinal = recognitionResult.speechRecognitionMetadata != nil
      }
    let isFinal = recognitionResult.isFinal
      handleResult(recognitionResult.transcriptions, isFinal: isFinal, maybeFinal: pseudoFinal )
  }

  private func reportError(source: String, error: Error?) {
    if nil != error {
      os_log(
        "%{PUBLIC}@ with error: %{PUBLIC}@", log: pluginLog, type: .debug, source,
        error.debugDescription)
    }
  }
}

@available(iOS 10.0, macOS 10.15, *)
extension SpeechToTextPlugin: AVAudioPlayerDelegate {

  public func audioPlayerDidFinishPlaying(
    _ player: AVAudioPlayer,
    successfully flag: Bool
  ) {
    if let playEnd = self.onPlayEnd {
      playEnd()
    }
  }
}

private class SpeechResultAggregator {
    private var speechTranscriptions: [SFTranscription]
    private var previousTranscriptions: [[SFTranscription]]
    private let isFinal: Bool
    private let interimFinal: Bool
    
    init() {
        speechTranscriptions = []
        previousTranscriptions = []
        isFinal = false
        interimFinal = false
    }
    
    init( withTranscriptions: [SFTranscription], final: Bool, maybeFinal: Bool) {
        speechTranscriptions = []
        speechTranscriptions.append( contentsOf: withTranscriptions)
        previousTranscriptions = []
        isFinal = final
        interimFinal = maybeFinal
    }
    
    init( withTranscriptions: [SFTranscription], existingTranscriptions: [[SFTranscription]], final: Bool, maybeFinal: Bool) {
        speechTranscriptions = []
        speechTranscriptions.append( contentsOf: withTranscriptions)
        previousTranscriptions = []
        previousTranscriptions.append(contentsOf: existingTranscriptions)
        isFinal = final
        interimFinal = maybeFinal
    }
    
    /// returns a new SpeechResultAggregator.
    /// If the existing aggregator has no content then return a new aggregator with just the
    /// new content. If the existing is not empty and keepPrevious is true then append the
    /// current transcription to the previous transcriptions and then return a new aggregator
    /// with that set of transcriptions and the new content.
    public func addResult( _ newResult: [SFTranscription], isFinal: Bool, maybeFinal: Bool ) -> SpeechResultAggregator {
        if isEmpty {
            return SpeechResultAggregator(withTranscriptions: newResult, final: isFinal, maybeFinal:  interimFinal)
        }
        if !maybeFinal && interimFinal {
            previousTranscriptions.append(speechTranscriptions)
        }
        return SpeechResultAggregator(withTranscriptions: newResult, existingTranscriptions: previousTranscriptions, final: isFinal, maybeFinal: maybeFinal)
    }
    
    public var isEmpty: Bool {
        get {
            speechTranscriptions.isEmpty
        }
    }
    
    public var hasPreviousTranscriptions: Bool {
        get {
            return !previousTranscriptions.isEmpty
        }
    }
    
    /// If there are previous transcriptions then generate a new transcription and insert it as
    /// the first entry in the returned results.
    /// This behaviour was created to handle an apparent bug in the iOS speech
    /// recognition API. When the speaker pauses for a few seconds the recognition
    /// engine discards the previous transcriptions and returns a transcription
    /// with just the words after the pause. This is a change in behaviour that
    /// happened some time in iOS 17 or 18. This class tries to simulate the previous
    /// behaviour of returning the complete transcription including the words before
    /// and after the pause.
    public var results: SpeechRecognitionResult {
        var speechWords: [SpeechRecognitionWords] = []
        if hasPreviousTranscriptions {
            var lowestConfidence: Decimal = 1.0
            var aggregatePhrase = ""
            var recognizedPhrases: [String] = []
            for previousTranscription in previousTranscriptions {
                if let transcription = previousTranscription.first {
                    recognizedPhrases.append(transcription.formattedString)
                    lowestConfidence = min( lowestConfidence, confidenceIn(transcription))
                    if aggregatePhrase.count > 0 && aggregatePhrase.last != " " {
                        aggregatePhrase += " "
                    }
                    aggregatePhrase += transcription.formattedString
                }
            }
            if let transcription = speechTranscriptions.first {
                recognizedPhrases.append(transcription.formattedString)
                lowestConfidence = min( lowestConfidence, confidenceIn(transcription))
                if aggregatePhrase.count > 0 && aggregatePhrase.last != " " {
                    aggregatePhrase += " "
                }
                aggregatePhrase += transcription.formattedString
            }
            speechWords.append(SpeechRecognitionWords(recognizedWords: aggregatePhrase, recognizedPhrases: recognizedPhrases, confidence: lowestConfidence))
        }
        for transcription in speechTranscriptions {
            let words: SpeechRecognitionWords = SpeechRecognitionWords(
                recognizedWords: transcription.formattedString, recognizedPhrases: nil, confidence: confidenceIn(transcription))
            speechWords.append(words)
        }
        return SpeechRecognitionResult(alternates: speechWords, finalResult: isFinal )

    }
    
    private func confidenceIn(_ transcription: SFTranscription) -> Decimal {
      guard transcription.segments.count > 0 else {
        return 0
      }
      var totalConfidence: Float = 0.0
      for segment in transcription.segments {
        totalConfidence += segment.confidence
      }
      let avgConfidence: Float = totalConfidence / Float(transcription.segments.count)
      let confidence: Float = (avgConfidence * 1000).rounded() / 1000
      return Decimal(string: String(describing: confidence))!
    }
}
