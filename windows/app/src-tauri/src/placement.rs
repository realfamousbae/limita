//! Pure geometry for the panel, in physical pixels. Port of `PanelLayout.swift`,
//! without the notch and with a tray that can sit on any screen edge.

/// A rectangle in physical pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Area {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

impl Area {
    pub fn new(x: f64, y: f64, width: f64, height: f64) -> Self {
        Self { x, y, width, height }
    }

    pub fn right(&self) -> f64 {
        self.x + self.width
    }

    pub fn bottom(&self) -> f64 {
        self.y + self.height
    }

    pub fn contains(&self, px: f64, py: f64) -> bool {
        px >= self.x && px <= self.right() && py >= self.y && py <= self.bottom()
    }

    pub fn inflated(&self, by: f64) -> Area {
        Area::new(self.x - by, self.y - by, self.width + 2.0 * by, self.height + 2.0 * by)
    }

    pub fn union(&self, other: &Area) -> Area {
        let x = self.x.min(other.x);
        let y = self.y.min(other.y);
        Area::new(x, y, self.right().max(other.right()) - x, self.bottom().max(other.bottom()) - y)
    }
}

/// One monitor: its full bounds, the part not covered by the taskbar, and its scale.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Screen {
    pub frame: Area,
    pub work: Area,
    pub scale: f64,
}

/// Logical-pixel constants, multiplied by the monitor's scale.
pub const SCREEN_INSET: f64 = 8.0;
pub const GAP: f64 = 6.0;
pub const HOVER_SLOP: f64 = 20.0;

/// The part of the top edge that shows the pill, as fractions of the screen width. The
/// corners are left alone: menus sit on the left, window buttons on the right.
pub const TRIGGER_FROM: f64 = 0.28;
pub const TRIGGER_TO: f64 = 0.75;

impl Screen {
    /// The cursor touches the top edge of this screen, away from its corners.
    pub fn is_trigger(&self, px: f64, py: f64) -> bool {
        py >= self.frame.y
            && py < self.frame.y + 1.0
            && px >= self.frame.x + self.frame.width * TRIGGER_FROM
            && px <= self.frame.x + self.frame.width * TRIGGER_TO
    }

    /// A frame of `size` hanging from the top of the work area, centred on `anchor_x` as
    /// far as the screen edges allow.
    pub fn below_top(&self, size: (f64, f64), anchor_x: f64) -> Area {
        let x = self.clamp_x(anchor_x - size.0 / 2.0, size.0);
        Area::new(x, self.work.y + GAP * self.scale, size.0, size.1)
    }

    /// A frame of `size` next to the tray icon at `tray`: above it when the taskbar is at
    /// the bottom (the usual Windows layout), below it when it is at the top (macOS, or a
    /// top taskbar), beside it when the taskbar is on a side.
    pub fn beside_tray(&self, size: (f64, f64), tray: Area) -> Area {
        let (width, height) = size;
        let gap = GAP * self.scale;
        let centre_x = tray.x + tray.width / 2.0;
        let centre_y = tray.y + tray.height / 2.0;
        let taskbar_left = self.work.x > self.frame.x && centre_x < self.work.x;
        let taskbar_right = self.work.right() < self.frame.right() && centre_x > self.work.right();
        if taskbar_left || taskbar_right {
            let x = if taskbar_left { self.work.x + gap } else { self.work.right() - gap - width };
            let y = (centre_y - height / 2.0).clamp(self.work.y + gap, (self.work.bottom() - gap - height).max(self.work.y));
            return Area::new(x, y, width, height);
        }
        let x = (centre_x - width / 2.0).clamp(self.work.x + gap, (self.work.right() - gap - width).max(self.work.x));
        let upper_half = centre_y < self.frame.y + self.frame.height / 2.0;
        let y = if upper_half { self.work.y + gap } else { self.work.bottom() - gap - height };
        Area::new(x, y, width, height)
    }

    /// Where the cursor keeps a hover-opened panel open: the panel, the strip between it
    /// and the top edge the cursor crosses to reach it, and some slop.
    pub fn hover_zone(&self, panel: Area) -> Area {
        let strip = Area::new(panel.x, self.frame.y, panel.width, (panel.y - self.frame.y).max(0.0));
        panel.union(&strip).inflated(HOVER_SLOP * self.scale)
    }

    fn clamp_x(&self, x: f64, width: f64) -> f64 {
        let min = self.frame.x + SCREEN_INSET * self.scale;
        let max = self.frame.right() - SCREEN_INSET * self.scale - width;
        x.clamp(min, max.max(min))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn screen(scale: f64) -> Screen {
        // 1920×1080 logical with a 48-logical-pixel taskbar at the bottom.
        let frame = Area::new(0.0, 0.0, 1920.0 * scale, 1080.0 * scale);
        let work = Area::new(0.0, 0.0, 1920.0 * scale, (1080.0 - 48.0) * scale);
        Screen { frame, work, scale }
    }

    #[test]
    fn trigger_is_the_top_edge_only() {
        let s = screen(1.5);
        assert!(s.is_trigger(1440.0, 0.0));
        assert!(!s.is_trigger(1440.0, 1.0), "one pixel below the edge");
        assert!(!s.is_trigger(-1.0, 0.0), "another screen");
    }

    #[test]
    fn trigger_skips_the_corners() {
        // A second monitor to the right of the first, so the band starts from its own x.
        let s = Screen { frame: Area::new(1920.0, 0.0, 1000.0, 800.0), work: Area::new(1920.0, 0.0, 1000.0, 760.0), scale: 1.0 };
        assert!(!s.is_trigger(1920.0 + 100.0, 0.0), "menus on the left");
        assert!(!s.is_trigger(1920.0 + 279.0, 0.0));
        assert!(s.is_trigger(1920.0 + 280.0, 0.0));
        assert!(s.is_trigger(1920.0 + 500.0, 0.0), "centre");
        assert!(s.is_trigger(1920.0 + 750.0, 0.0));
        assert!(!s.is_trigger(1920.0 + 751.0, 0.0));
        assert!(!s.is_trigger(1920.0 + 980.0, 0.0), "window buttons on the right");
    }

    #[test]
    fn pill_hangs_from_the_top_and_stays_on_screen() {
        let s = screen(1.0);
        let frame = s.below_top((200.0, 34.0), 960.0);
        assert_eq!(frame, Area::new(860.0, 6.0, 200.0, 34.0));
        assert_eq!(s.below_top((200.0, 34.0), 0.0).x, 8.0);
        assert_eq!(s.below_top((200.0, 34.0), 1920.0).right(), 1912.0);
    }

    #[test]
    fn dashboard_sits_above_a_bottom_taskbar_and_below_a_top_one() {
        let s = screen(1.0);
        let tray = Area::new(1800.0, 1040.0, 24.0, 24.0);
        let frame = s.beside_tray((520.0, 300.0), tray);
        assert_eq!(frame.bottom(), 1032.0 - 6.0);
        assert_eq!(frame.right(), 1920.0 - 6.0, "clamped to the right edge");

        let top = Screen { work: Area::new(0.0, 40.0, 1920.0, 1040.0), ..s };
        let frame = top.beside_tray((520.0, 300.0), Area::new(900.0, 8.0, 24.0, 24.0));
        assert_eq!(frame.y, 46.0);
        assert_eq!(frame.x, 912.0 - 260.0);
    }

    #[test]
    fn dashboard_sits_beside_a_side_taskbar() {
        let s = Screen {
            frame: Area::new(0.0, 0.0, 1920.0, 1080.0),
            work: Area::new(0.0, 0.0, 1860.0, 1080.0),
            scale: 1.0,
        };
        let frame = s.beside_tray((520.0, 300.0), Area::new(1880.0, 1000.0, 24.0, 24.0));
        assert_eq!(frame.right(), 1854.0);
        assert_eq!(frame.bottom(), 1074.0);
    }

    #[test]
    fn hover_zone_covers_the_way_up_to_the_edge() {
        let s = screen(1.0);
        let zone = s.hover_zone(Area::new(860.0, 6.0, 200.0, 34.0));
        assert!(zone.contains(960.0, 0.0));
        assert!(zone.contains(845.0, 20.0));
        assert!(!zone.contains(960.0, 70.0));
    }
}
