#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shlobj.h>
#include <windows.h>
#include <fstream>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

bool IsOAuthCallbackArgument(const std::string& argument) {
  return argument.rfind("cineviet://auth/callback", 0) == 0;
}

bool HasOAuthCallbackArgument(const std::vector<std::string>& arguments) {
  for (const auto& argument : arguments) {
    if (IsOAuthCallbackArgument(argument)) {
      return true;
    }
  }
  return false;
}

std::string GetOAuthCallbackArgument(const std::vector<std::string>& arguments) {
  for (const auto& argument : arguments) {
    if (IsOAuthCallbackArgument(argument)) {
      return argument;
    }
  }
  return "";
}

std::wstring GetCallbackBridgePath() {
  wchar_t temp_path[MAX_PATH] = {0};
  if (::GetTempPathW(MAX_PATH, temp_path) == 0) {
    return L"";
  }
  return std::wstring(temp_path) + L"cineviet_oauth_callback.txt";
}

void WriteCallbackBridgeFile(const std::string& callback_url) {
  const std::wstring path = GetCallbackBridgePath();
  if (path.empty()) {
    return;
  }
  std::ofstream file(path, std::ios::out | std::ios::trunc);
  file << callback_url;
}

bool BringExistingCineVietWindowToFront() {
  HWND existing_window = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"CineViet");
  if (existing_window == nullptr) {
    existing_window = ::FindWindowW(nullptr, L"CineViet");
  }
  if (existing_window == nullptr) {
    return false;
  }
  if (::IsIconic(existing_window)) {
    ::ShowWindow(existing_window, SW_RESTORE);
  }
  ::SetForegroundWindow(existing_window);
  return true;
}

void RegisterCineVietUrlProtocol() {
  wchar_t exe_path[MAX_PATH] = {0};
  if (::GetModuleFileNameW(nullptr, exe_path, MAX_PATH) == 0) {
    return;
  }

  const std::wstring key_path = L"Software\\Classes\\cineviet";
  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, key_path.c_str(), 0, nullptr, 0,
                        KEY_SET_VALUE | KEY_CREATE_SUB_KEY, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
    return;
  }

  const wchar_t description[] = L"URL:CineViet Protocol";
  ::RegSetValueExW(key, nullptr, 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(description),
                   sizeof(description));
  const wchar_t empty[] = L"";
  ::RegSetValueExW(key, L"URL Protocol", 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(empty), sizeof(empty));
  ::RegCloseKey(key);

  HKEY command_key = nullptr;
  if (::RegCreateKeyExW(
          HKEY_CURRENT_USER,
          L"Software\\Classes\\cineviet\\shell\\open\\command", 0, nullptr,
          0, KEY_SET_VALUE, nullptr, &command_key,
          nullptr) != ERROR_SUCCESS) {
    return;
  }
  const std::wstring command = L"\"" + std::wstring(exe_path) + L"\" \"%1\"";
  ::RegSetValueExW(command_key, nullptr, 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(command.c_str()),
                   static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  ::RegCloseKey(command_key);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  RegisterCineVietUrlProtocol();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  if (HasOAuthCallbackArgument(command_line_arguments)) {
    WriteCallbackBridgeFile(GetOAuthCallbackArgument(command_line_arguments));
    if (BringExistingCineVietWindowToFront()) {
      ::CoUninitialize();
      return EXIT_SUCCESS;
    }
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"CineViet", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
