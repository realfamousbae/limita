//! The few window behaviours Tauri does not cover, per platform.

use tauri::WebviewWindow;

/// Shows the panel. Only a dashboard opened from the tray takes focus (it closes on
/// blur); the pill and a dashboard grown from it must not steal the keyboard from the
/// app the user is typing in.
#[cfg(windows)]
pub fn show(window: &WebviewWindow, takes_focus: bool) {
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        SetWindowPos, ShowWindow, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SW_SHOWNOACTIVATE,
    };
    let _ = window.set_focusable(takes_focus);
    if takes_focus {
        let _ = window.show();
        let _ = window.set_focus();
        return;
    }
    match window.hwnd() {
        Ok(hwnd) => unsafe {
            let hwnd = hwnd.0 as _;
            ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        },
        Err(_) => {
            let _ = window.show();
        }
    }
}

#[cfg(not(windows))]
pub fn show(window: &WebviewWindow, takes_focus: bool) {
    let _ = window.show();
    if takes_focus {
        let _ = window.set_focus();
    }
}

/// A full-screen app (a game, a video, a presentation) owns the screen: no pill there.
#[cfg(windows)]
pub fn foreground_is_fullscreen(screen: crate::placement::Area) -> bool {
    use windows_sys::Win32::Foundation::RECT;
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        GetClassNameW, GetDesktopWindow, GetForegroundWindow, GetShellWindow, GetWindowRect,
    };
    unsafe {
        let hwnd = GetForegroundWindow();
        if hwnd.is_null() || hwnd == GetDesktopWindow() || hwnd == GetShellWindow() {
            return false;
        }
        let mut class = [0u16; 64];
        let length = GetClassNameW(hwnd, class.as_mut_ptr(), class.len() as i32);
        let class = String::from_utf16_lossy(&class[..length.max(0) as usize]);
        // The desktop behind the icons.
        if class == "WorkerW" || class == "Progman" {
            return false;
        }
        let mut rect = RECT { left: 0, top: 0, right: 0, bottom: 0 };
        if GetWindowRect(hwnd, &mut rect) == 0 {
            return false;
        }
        rect.left as f64 <= screen.x
            && rect.top as f64 <= screen.y
            && rect.right as f64 >= screen.right()
            && rect.bottom as f64 >= screen.bottom()
    }
}

#[cfg(not(windows))]
pub fn foreground_is_fullscreen(_: crate::placement::Area) -> bool {
    false
}

/// Whether a mouse button is down, or was pressed since the last poll.
#[cfg(windows)]
pub fn mouse_button_down() -> bool {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON, VK_RBUTTON};
    let pressed = |key: u16| unsafe { GetAsyncKeyState(key as i32) as u16 & 0x8001 != 0 };
    pressed(VK_LBUTTON) || pressed(VK_RBUTTON)
}

/// macOS (development only) closes the dashboard on blur.
#[cfg(not(windows))]
pub fn mouse_button_down() -> bool {
    false
}
