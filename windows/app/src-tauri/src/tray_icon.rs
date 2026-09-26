//! The tray glyph with a traffic-light dot, drawn at runtime.
//!
//! The macOS glyph is a black template image; Windows does not recolour tray icons, so it
//! is tinted to contrast with the taskbar, and the dot is cut into its lower-right corner.

use limita_core::LimitLevel;

const GLYPH_PNG: &[u8] = include_bytes!("../assets/status.png");
pub const SIZE: u32 = 32;

/// RGBA pixels of a `SIZE`×`SIZE` tray icon.
pub fn render(level: Option<LimitLevel>, stale: bool, light_taskbar: bool) -> Vec<u8> {
    let glyph = tauri::image::Image::from_bytes(GLYPH_PNG).expect("bundled glyph is a PNG");
    let mut pixels = downscale(glyph.rgba(), glyph.width(), glyph.height(), SIZE);
    let ink = if light_taskbar { [0, 0, 0] } else { [255, 255, 255] };
    for pixel in pixels.chunks_exact_mut(4) {
        pixel[..3].copy_from_slice(&ink);
    }
    if let Some(level) = level {
        draw_dot(&mut pixels, colour(level), if stale { 0.45 } else { 1.0 });
    }
    pixels
}

/// The dashboard's traffic-light colours.
fn colour(level: LimitLevel) -> [u8; 3] {
    match level {
        LimitLevel::Normal => [82, 235, 148],
        LimitLevel::Warning => [255, 214, 10],
        LimitLevel::Critical => [255, 69, 58],
    }
}

/// A dot in the lower-right corner with a transparent ring cut around it, so it reads
/// against the glyph at 16 px.
fn draw_dot(pixels: &mut [u8], rgb: [u8; 3], opacity: f64) {
    let size = SIZE as f64;
    let radius = size * 0.22;
    let ring = size * 0.07;
    let centre = size - radius - 0.5;
    for y in 0..SIZE {
        for x in 0..SIZE {
            let dx = x as f64 + 0.5 - centre;
            let dy = y as f64 + 0.5 - centre;
            let distance = (dx * dx + dy * dy).sqrt();
            let index = ((y * SIZE + x) * 4) as usize;
            // Antialiased coverage of the ring cut and of the dot.
            let cut = (radius + ring + 0.5 - distance).clamp(0.0, 1.0);
            let dot = (radius + 0.5 - distance).clamp(0.0, 1.0);
            let alpha = pixels[index + 3] as f64 * (1.0 - cut);
            if dot > 0.0 {
                let dot_alpha = 255.0 * dot * opacity;
                let total = dot_alpha + alpha * (1.0 - dot * opacity);
                for channel in 0..3 {
                    let under = pixels[index + channel] as f64;
                    let blended = if total > 0.0 {
                        (rgb[channel] as f64 * dot_alpha + under * alpha * (1.0 - dot * opacity)) / total
                    } else {
                        0.0
                    };
                    pixels[index + channel] = blended.round() as u8;
                }
                pixels[index + 3] = total.round().min(255.0) as u8;
            } else {
                pixels[index + 3] = alpha.round() as u8;
            }
        }
    }
}

/// Area-averaging downscale of RGBA `source` to `target`×`target`, weighting colour by
/// alpha so transparent pixels do not darken the edges.
fn downscale(source: &[u8], width: u32, height: u32, target: u32) -> Vec<u8> {
    let mut out = vec![0u8; (target * target * 4) as usize];
    let sx = width as f64 / target as f64;
    let sy = height as f64 / target as f64;
    for ty in 0..target {
        for tx in 0..target {
            let (x0, x1) = (tx as f64 * sx, (tx + 1) as f64 * sx);
            let (y0, y1) = (ty as f64 * sy, (ty + 1) as f64 * sy);
            let mut sum = [0.0f64; 4];
            let mut area = 0.0;
            let mut y = y0.floor() as u32;
            while (y as f64) < y1 && y < height {
                let wy = ((y + 1) as f64).min(y1) - (y as f64).max(y0);
                let mut x = x0.floor() as u32;
                while (x as f64) < x1 && x < width {
                    let wx = ((x + 1) as f64).min(x1) - (x as f64).max(x0);
                    let weight = wx * wy;
                    let index = ((y * width + x) * 4) as usize;
                    let alpha = source[index + 3] as f64;
                    for channel in 0..3 {
                        sum[channel] += source[index + channel] as f64 * alpha * weight;
                    }
                    sum[3] += alpha * weight;
                    area += weight;
                    x += 1;
                }
                y += 1;
            }
            let index = ((ty * target + tx) * 4) as usize;
            if sum[3] > 0.0 {
                for channel in 0..3 {
                    out[index + channel] = (sum[channel] / sum[3]).round() as u8;
                }
                out[index + 3] = (sum[3] / area).round() as u8;
            }
        }
    }
    out
}

/// Whether the Windows taskbar uses the light theme, where a white glyph would vanish.
#[cfg(windows)]
pub fn light_taskbar() -> bool {
    use windows_sys::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD};
    let key: Vec<u16> = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize\0".encode_utf16().collect();
    let value: Vec<u16> = "SystemUsesLightTheme\0".encode_utf16().collect();
    let mut data: u32 = 0;
    let mut size = std::mem::size_of::<u32>() as u32;
    let status = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            key.as_ptr(),
            value.as_ptr(),
            RRF_RT_REG_DWORD,
            std::ptr::null_mut(),
            &mut data as *mut u32 as *mut _,
            &mut size,
        )
    };
    status == 0 && data == 1
}

/// macOS (development only): the menu bar is usually light-on-dark or tinted; black ink
/// with the dot is close enough to judge the icon.
#[cfg(not(windows))]
pub fn light_taskbar() -> bool {
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_glyph_and_dot() {
        let pixels = render(Some(LimitLevel::Critical), false, false);
        assert_eq!(pixels.len(), (SIZE * SIZE * 4) as usize);
        let at = |x: u32, y: u32| {
            let i = ((y * SIZE + x) * 4) as usize;
            [pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]]
        };
        let c = SIZE - (SIZE as f64 * 0.22) as u32 - 1;
        assert_eq!(at(c, c), [255, 69, 58, 255], "solid red dot");
        assert!(pixels.chunks_exact(4).any(|p| p == [255, 255, 255, 255]), "white glyph on a dark taskbar");
        let plain = render(None, false, true);
        assert!(plain.chunks_exact(4).all(|p| p[3] == 0 || p[..3] == [0, 0, 0]), "black glyph, no dot");
    }
}
