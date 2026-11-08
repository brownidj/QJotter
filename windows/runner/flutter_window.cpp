#include "flutter_window.h"

#include <optional>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

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
  settings_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "notefile/settings",
      &flutter::StandardMethodCodec::GetInstance());
  settings_channel_->SetMethodCallHandler([](const auto& call, auto result) {
    const wchar_t* key_path = L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
    const wchar_t* value_name = L"Notefile";
    if (call.method_name() != "getStartupStatus" && call.method_name() != "setStartupEnabled") {
      result->NotImplemented();
      return;
    }
    if (call.method_name() == "setStartupEnabled") {
      const auto* enabled = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!enabled) { result->Error("invalid_setting", "A startup setting is required."); return; }
      HKEY key;
      auto status = RegCreateKeyExW(HKEY_CURRENT_USER, key_path, 0, nullptr, 0,
                                  KEY_SET_VALUE, nullptr, &key, nullptr);
      if (status == ERROR_SUCCESS) {
        if (*enabled) {
          wchar_t executable[32768];
          DWORD length = GetModuleFileNameW(nullptr, executable, 32768);
          if (length == 0 || length >= 32768) status = ERROR_BAD_PATHNAME;
          else {
            std::wstring command = L"\"" + std::wstring(executable, length) + L"\" --autostart";
            status = RegSetValueExW(key, value_name, 0, REG_SZ,
                reinterpret_cast<const BYTE*>(command.c_str()),
                static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
          }
        } else {
          status = RegDeleteValueW(key, value_name);
          if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
        }
        RegCloseKey(key);
      }
      if (status != ERROR_SUCCESS) {
        result->Error("startup_unavailable", "Could not change Windows startup registration.");
        return;
      }
    }
    DWORD type = 0, size = 0;
    auto status = RegGetValueW(HKEY_CURRENT_USER, key_path, value_name,
                              RRF_RT_REG_SZ, &type, nullptr, &size);
    result->Success(flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("supported"), flutter::EncodableValue(true)},
      {flutter::EncodableValue("enabled"), flutter::EncodableValue(status == ERROR_SUCCESS)},
      {flutter::EncodableValue("requiresApproval"), flutter::EncodableValue(false)}}));
  });
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

void FlutterWindow::OnDestroy() {
  settings_channel_ = nullptr;
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
