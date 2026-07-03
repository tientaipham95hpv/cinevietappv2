import AVFoundation
import AVKit
import Flutter
import MediaPlayer
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, AVPictureInPictureControllerDelegate {
  private lazy var volumeView: MPVolumeView = {
    let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    view.showsRouteButton = false
    view.showsVolumeSlider = true
    view.alpha = 0.001
    view.isUserInteractionEnabled = false
    return view
  }()
  private weak var volumeSlider: UISlider?
  private var pipPlayer: AVPlayer?
  private var pipPlayerLayer: AVPlayerLayer?
  private var pipController: AVPictureInPictureController?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    let ok = super.application(application, didFinishLaunchingWithOptions: launchOptions)

    DispatchQueue.main.async { [weak self] in
      self?.setupPlayerControlChannel()
    }

    return ok
  }

  private func setupPlayerControlChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }

    let pipChannel = FlutterMethodChannel(
      name: "live.cineviet/pip",
      binaryMessenger: controller.binaryMessenger
    )
    pipChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "isSupported":
        if #available(iOS 14.0, *) {
          result(AVPictureInPictureController.isPictureInPictureSupported())
        } else {
          result(false)
        }
      case "enter":
        result(self.startPictureInPicture(arguments: call.arguments))
      default:
        result(FlutterMethodNotImplemented)
      }
    }

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
          UIScreen.main.brightness = CGFloat(max(0.0, min(1.0, value)))
          result(Double(UIScreen.main.brightness))
        case "reset":
          // iOS has no per-window brightness override, so return the current system brightness.
          result(Double(UIScreen.main.brightness))
        case "getVolume":
          result(Double(AVAudioSession.sharedInstance().outputVolume))
        case "setVolume":
          let value = self?.doubleArg(call.arguments, key: "value", fallback: 1.0) ?? 1.0
          self?.setSystemVolume(value)
          result(Double(AVAudioSession.sharedInstance().outputVolume))
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }


  private func startPictureInPicture(arguments: Any?) -> Bool {
    guard #available(iOS 14.0, *) else { return false }
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return false }
    guard let args = arguments as? [String: Any],
          let rawUrl = args["url"] as? String,
          let url = URL(string: rawUrl),
          let controller = window?.rootViewController as? FlutterViewController else { return false }

    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      return false
    }

    let player = AVPlayer(url: url)
    if let positionMs = args["positionMs"] as? NSNumber, positionMs.int64Value > 0 {
      let seconds = Double(positionMs.int64Value) / 1000.0
      player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    let layer = AVPlayerLayer(player: player)
    layer.videoGravity = .resizeAspect
    layer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    layer.opacity = 0.01
    controller.view.layer.addSublayer(layer)

    guard let pip = AVPictureInPictureController(playerLayer: layer) else {
      layer.removeFromSuperlayer()
      return false
    }
    pip.delegate = self
    if #available(iOS 14.2, *) {
      pip.canStartPictureInPictureAutomaticallyFromInline = true
    }

    pipPlayer = player
    pipPlayerLayer?.removeFromSuperlayer()
    pipPlayerLayer = layer
    pipController = pip
    player.play()
    pip.startPictureInPicture()
    return true
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    pipPlayer?.pause()
    pipPlayer = nil
    pipController = nil
    pipPlayerLayer?.removeFromSuperlayer()
    pipPlayerLayer = nil
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
    guard let slider = volumeSlider else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
        self?.setSystemVolume(value)
      }
      return
    }
    slider.setValue(clamped, animated: false)
    slider.sendActions(for: .valueChanged)
  }

  private func ensureVolumeControlReady() {
    guard let controller = window?.rootViewController as? FlutterViewController else { return }

    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      // Không để audio-session lỗi làm crash app.
    }

    if volumeView.superview == nil {
      controller.view.addSubview(volumeView)
      volumeSlider = volumeView.subviews.compactMap { $0 as? UISlider }.first
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
        self?.volumeSlider = self?.volumeView.subviews.compactMap { $0 as? UISlider }.first
      }
    }
  }
}
