import AVFoundation
import Flutter
import MediaPlayer
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private lazy var volumeView = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
  private weak var volumeSlider: UISlider?
  private var originalBrightness: CGFloat?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    DispatchQueue.main.async { [weak self] in
      self?.setupPlayerControlChannel()
    }
    return ok
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

  private func setupPlayerControlChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    let channel = FlutterMethodChannel(
      name: "live.cineviet/brightness",
      binaryMessenger: controller.binaryMessenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      DispatchQueue.main.async {
        switch call.method {
        case "get":
          result(Double(UIScreen.main.brightness))
        case "set":
          let value = self?.doubleArg(call.arguments, key: "value", fallback: Double(UIScreen.main.brightness)) ?? Double(UIScreen.main.brightness)
          if self?.originalBrightness == nil {
            self?.originalBrightness = UIScreen.main.brightness
          }
          UIScreen.main.brightness = CGFloat(max(0.0, min(1.0, value)))
          result(Double(UIScreen.main.brightness))
        case "reset":
          if let original = self?.originalBrightness {
            UIScreen.main.brightness = original
            self?.originalBrightness = nil
          }
          result(Double(UIScreen.main.brightness))
        case "getVolume":
          result(Double(AVAudioSession.sharedInstance().outputVolume))
        case "setVolume":
          let value = self?.doubleArg(call.arguments, key: "value", fallback: 1.0) ?? 1.0
          let clamped = min(max(value, 0.0), 1.0)
          self?.setSystemVolume(clamped)
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            result(Double(AVAudioSession.sharedInstance().outputVolume))
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  private func doubleArg(_ arguments: Any?, key: String, fallback: Double) -> Double {
    guard let args = arguments as? [String: Any] else { return fallback }
    if let value = args[key] as? Double { return value }
    if let value = args[key] as? NSNumber { return value.doubleValue }
    return fallback
  }

  private func setSystemVolume(_ value: Double) {
    ensureVolumeControlReady()
    let clamped = Float(min(max(value, 0.0), 1.0))
    if volumeSlider == nil {
      volumeSlider = volumeView.subviews.compactMap { $0 as? UISlider }.first
    }
    if volumeSlider == nil {
      volumeView.layoutIfNeeded()
      volumeSlider = volumeView.subviews.compactMap { $0 as? UISlider }.first
    }
    volumeSlider?.value = clamped
    volumeSlider?.sendActions(for: .valueChanged)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      self?.volumeSlider?.value = clamped
      self?.volumeSlider?.sendActions(for: .valueChanged)
    }
  }

  private func ensureVolumeControlReady() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
    }
    if volumeView.superview == nil {
      volumeView.alpha = 0.001
      volumeView.isUserInteractionEnabled = true
      volumeView.showsVolumeSlider = true
      controller.view.addSubview(volumeView)
      controller.view.sendSubviewToBack(volumeView)
      volumeSlider = volumeView.subviews.compactMap { $0 as? UISlider }.first
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        self?.volumeSlider = self?.volumeView.subviews.compactMap { $0 as? UISlider }.first
      }
    }
  }
}
