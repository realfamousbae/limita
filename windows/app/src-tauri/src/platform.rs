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
/// That is exclusive full screen, which Windows reports itself, and a window without a
/// title bar covering the whole monitor, which is how borderless games run. A maximized
/// window keeps its title bar, so it never counts, even over an auto-hidden taskbar.
#[cfg(windows)]
pub fn foreground_is_fullscreen(screen: crate::placement::Area) -> bool {
    use windows_sys::Win32::Foundation::RECT;
    use windows_sys::Win32::UI::Shell::{
        SHQueryUserNotificationState, QUNS_BUSY, QUNS_PRESENTATION_MODE, QUNS_RUNNING_D3D_FULL_SCREEN,
    };
    use windows_sys::Win32::UI::WindowsAndMessaging::{
        GetClassNameW, GetDesktopWindow, GetForegroundWindow, GetShellWindow, GetWindowLongW, GetWindowRect, IsZoomed,
        GWL_STYLE, WS_CAPTION,
    };
    unsafe {
        let mut state = 0;
        if SHQueryUserNotificationState(&mut state) == 0
            && matches!(state, QUNS_BUSY | QUNS_RUNNING_D3D_FULL_SCREEN | QUNS_PRESENTATION_MODE)
        {
            return true;
        }
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
        if IsZoomed(hwnd) != 0 || GetWindowLongW(hwnd, GWL_STYLE) as u32 & WS_CAPTION == WS_CAPTION {
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

/// A system-wide Ctrl+Alt+<letter> shortcut and what it does.
#[cfg_attr(not(windows), allow(dead_code))]
pub struct HotKey {
    pub letter: u8,
    pub on_press: Box<dyn Fn() + Send>,
}

/// Registers Ctrl+Alt shortcuts that work from any app: L shows or hides the dashboard,
/// H turns the hover pill on or off. One thread waits in the message loop and uses no CPU
/// between presses. Returns, per shortcut, whether it was registered; one another app
/// holds is skipped quietly.
#[cfg(windows)]
pub fn register_hotkeys(hotkeys: Vec<HotKey>) -> Vec<bool> {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{RegisterHotKey, MOD_ALT, MOD_CONTROL, MOD_NOREPEAT};
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetMessageW, MSG, WM_HOTKEY};
    let count = hotkeys.len();
    let (sender, registered) = std::sync::mpsc::channel();
    // A hot key belongs to the thread that registers it, so the loop runs there too.
    let spawned = std::thread::Builder::new().name("limita-hotkey".into()).spawn(move || unsafe {
        let ok: Vec<bool> = hotkeys
            .iter()
            .enumerate()
            .map(|(id, key)| RegisterHotKey(std::ptr::null_mut(), id as i32 + 1, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, u32::from(key.letter)) != 0)
            .collect();
        let _ = sender.send(ok.clone());
        if !ok.contains(&true) {
            return;
        }
        let mut message: MSG = std::mem::zeroed();
        while GetMessageW(&mut message, std::ptr::null_mut(), 0, 0) > 0 {
            if message.message == WM_HOTKEY {
                if let Some(key) = hotkeys.get((message.wParam as usize).wrapping_sub(1)) {
                    (key.on_press)();
                }
            }
        }
    });
    match spawned {
        Ok(_) => registered.recv().unwrap_or_else(|_| vec![false; count]),
        Err(_) => vec![false; count],
    }
}

#[cfg(not(windows))]
pub fn register_hotkeys(hotkeys: Vec<HotKey>) -> Vec<bool> {
    vec![false; hotkeys.len()]
}

/// Opens an `https://` link in the default browser. Only links Rust chose are opened
/// (see `open_reset`), never one the webview names.
#[cfg(windows)]
pub fn open_url(url: &str) {
    use windows_sys::Win32::UI::Shell::ShellExecuteW;
    use windows_sys::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
    if !url.starts_with("https://") {
        return;
    }
    let wide = |text: &str| text.encode_utf16().chain(Some(0)).collect::<Vec<u16>>();
    let (verb, target) = (wide("open"), wide(url));
    unsafe {
        ShellExecuteW(std::ptr::null_mut(), verb.as_ptr(), target.as_ptr(), std::ptr::null(), std::ptr::null(), SW_SHOWNORMAL);
    }
}

/// macOS, for development.
#[cfg(not(windows))]
pub fn open_url(url: &str) {
    if url.starts_with("https://") {
        let _ = std::process::Command::new("open").arg(url).spawn();
    }
}
