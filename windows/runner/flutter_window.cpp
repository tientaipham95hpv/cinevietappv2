#include "flutter_window.h"

#include <endpointvolume.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <mmdeviceapi.h>
#include <optional>
#include <variant>

#include "flutter/generated_plugin_registrant.h"

namespace {

double ClampLevel(double value) {
  if (value < 0.0) return 0.0;
  if (value > 1.0) return 1.0;
  return value;
}

double ReadDoubleArg(const flutter::EncodableMap& args, const char* key,
                     double fallback) {
  const auto it = args.find(flutter::EncodableValue(key));
  if (it == args.end()) return fallback;
  if (std::holds_alternative<double>(it->second)) {
    return std::get<double>(it->second);
  }
  if (std::holds_alternative<int>(it->second)) {
    return static_cast<double>(std::get<int>(it->second));
  }
  return fallback;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  RegisterPlayerControlChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::RegisterPlayerControlChannel() {
  player_control_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "live.cineviet/brightness",
          &flutter::StandardMethodCodec::GetInstance());

  player_control_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (call.method_name() == "get") {
          result->Success(flutter::EncodableValue(brightness_level_));
          return;
        }
        if (call.method_name() == "set") {
          brightness_level_ =
              ClampLevel(args ? ReadDoubleArg(*args, "value", brightness_level_)
                              : brightness_level_);
          result->Success(flutter::EncodableValue(brightness_level_));
          return;
        }
        if (call.method_name() == "reset") {
          brightness_level_ = 1.0;
          result->Success(flutter::EncodableValue(brightness_level_));
          return;
        }
        if (call.method_name() == "getVolume") {
          result->Success(flutter::EncodableValue(GetSystemVolume()));
          return;
        }
        if (call.method_name() == "setVolume") {
          const double next =
              ClampLevel(args ? ReadDoubleArg(*args, "value", 1.0) : 1.0);
          result->Success(flutter::EncodableValue(SetSystemVolume(next)));
          return;
        }
        if (call.method_name() == "setKeepScreenOn") {
          result->Success();
          return;
        }
        result->NotImplemented();
      });
}

double FlutterWindow::GetSystemVolume() {
  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* device = nullptr;
  IAudioEndpointVolume* endpoint = nullptr;
  float level = 1.0f;

  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(&enumerator));
  if (SUCCEEDED(hr) && enumerator != nullptr) {
    hr = enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &device);
  }
  if (SUCCEEDED(hr) && device != nullptr) {
    hr = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(&endpoint));
  }
  if (SUCCEEDED(hr) && endpoint != nullptr) {
    endpoint->GetMasterVolumeLevelScalar(&level);
  }

  if (endpoint != nullptr) endpoint->Release();
  if (device != nullptr) device->Release();
  if (enumerator != nullptr) enumerator->Release();
  return ClampLevel(static_cast<double>(level));
}

double FlutterWindow::SetSystemVolume(double value) {
  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* device = nullptr;
  IAudioEndpointVolume* endpoint = nullptr;
  const double clamped = ClampLevel(value);

  HRESULT hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                                __uuidof(IMMDeviceEnumerator),
                                reinterpret_cast<void**>(&enumerator));
  if (SUCCEEDED(hr) && enumerator != nullptr) {
    hr = enumerator->GetDefaultAudioEndpoint(eRender, eMultimedia, &device);
  }
  if (SUCCEEDED(hr) && device != nullptr) {
    hr = device->Activate(__uuidof(IAudioEndpointVolume), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(&endpoint));
  }
  if (SUCCEEDED(hr) && endpoint != nullptr) {
    endpoint->SetMasterVolumeLevelScalar(static_cast<float>(clamped), nullptr);
  }

  if (endpoint != nullptr) endpoint->Release();
  if (device != nullptr) device->Release();
  if (enumerator != nullptr) enumerator->Release();
  return GetSystemVolume();
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
