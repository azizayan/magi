use std::sync::mpsc::{self, Receiver};

use eframe::egui;
use global_hotkey::{
    GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState,
    hotkey::{Code, HotKey, Modifiers},
};
use serde::{Deserialize, Serialize};
#[cfg(any(target_os = "macos", target_os = "windows"))]
use tray_icon::{
    Icon, TrayIcon, TrayIconBuilder,
    menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem},
};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum ShortcutChoice {
    #[default]
    OptionM,
    CommandShiftM,
    ControlShiftM,
    Disabled,
}

impl ShortcutChoice {
    pub const ALL: [Self; 4] = [
        Self::OptionM,
        Self::CommandShiftM,
        Self::ControlShiftM,
        Self::Disabled,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Self::OptionM => "Option + M",
            Self::CommandShiftM => "Command + Shift + M",
            Self::ControlShiftM => "Control + Shift + M",
            Self::Disabled => "Disabled",
        }
    }

    fn hotkey(self) -> Option<HotKey> {
        let modifiers = match self {
            Self::OptionM => Modifiers::ALT,
            Self::CommandShiftM => Modifiers::SUPER | Modifiers::SHIFT,
            Self::ControlShiftM => Modifiers::CONTROL | Modifiers::SHIFT,
            Self::Disabled => return None,
        };
        Some(HotKey::new(Some(modifiers), Code::KeyM))
    }
}

#[derive(Clone, Copy, Debug)]
pub enum DesktopAction {
    ToggleWindow,
    #[cfg(any(target_os = "macos", target_os = "windows"))]
    ToggleListening,
    #[cfg(any(target_os = "macos", target_os = "windows"))]
    Quit,
}

pub struct DesktopIntegration {
    #[cfg(any(target_os = "macos", target_os = "windows"))]
    _tray_icon: Option<TrayIcon>,
    #[cfg(any(target_os = "macos", target_os = "windows"))]
    show_hide_item: Option<MenuItem>,
    #[cfg(any(target_os = "macos", target_os = "windows"))]
    listening_item: Option<CheckMenuItem>,
    action_receiver: Receiver<DesktopAction>,
    hotkey_manager: Option<GlobalHotKeyManager>,
    hotkey: Option<HotKey>,
    error: Option<String>,
}

impl DesktopIntegration {
    pub fn new(ctx: &egui::Context, shortcut: ShortcutChoice) -> Self {
        let (action_sender, action_receiver) = mpsc::channel();
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        let (tray_icon, show_hide_item, listening_item, tray_error) =
            match create_tray(ctx, action_sender.clone()) {
                Ok((icon, show_hide, listening)) => {
                    (Some(icon), Some(show_hide), Some(listening), None)
                }
                Err(error) => (None, None, None, Some(error)),
            };
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        let tray_error = None;

        let repaint = ctx.clone();
        GlobalHotKeyEvent::set_event_handler(Some(move |event: GlobalHotKeyEvent| {
            if event.state == HotKeyState::Pressed {
                let _ = action_sender.send(DesktopAction::ToggleWindow);
                repaint.request_repaint();
            }
        }));

        let mut integration = Self {
            #[cfg(any(target_os = "macos", target_os = "windows"))]
            _tray_icon: tray_icon,
            #[cfg(any(target_os = "macos", target_os = "windows"))]
            show_hide_item,
            #[cfg(any(target_os = "macos", target_os = "windows"))]
            listening_item,
            action_receiver,
            hotkey_manager: GlobalHotKeyManager::new().ok(),
            hotkey: None,
            error: tray_error,
        };
        integration.set_shortcut(shortcut);
        integration
    }

    pub fn next_action(&self) -> Option<DesktopAction> {
        self.action_receiver.try_recv().ok()
    }

    pub fn set_window_visible(&self, visible: bool) {
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        if let Some(item) = &self.show_hide_item {
            item.set_text(if visible { "Hide Magi" } else { "Show Magi" });
        }
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        let _ = visible;
    }

    pub fn set_listening(&self, listening: bool) {
        #[cfg(any(target_os = "macos", target_os = "windows"))]
        if let Some(item) = &self.listening_item {
            item.set_checked(listening);
        }
        #[cfg(not(any(target_os = "macos", target_os = "windows")))]
        let _ = listening;
    }

    pub fn set_shortcut(&mut self, shortcut: ShortcutChoice) {
        let Some(manager) = &self.hotkey_manager else {
            self.record_error("Global shortcuts are unavailable on this system.");
            return;
        };

        if let Some(hotkey) = self.hotkey.take() {
            let _ = manager.unregister(hotkey);
        }

        let Some(hotkey) = shortcut.hotkey() else {
            return;
        };
        match manager.register(hotkey) {
            Ok(()) => self.hotkey = Some(hotkey),
            Err(error) => self.record_error(format!(
                "Could not register shortcut {}: {error}",
                shortcut.label()
            )),
        }
    }

    pub fn error(&self) -> Option<&str> {
        self.error.as_deref()
    }

    fn record_error(&mut self, error: impl Into<String>) {
        let error = error.into();
        match &mut self.error {
            Some(existing) => {
                existing.push('\n');
                existing.push_str(&error);
            }
            None => self.error = Some(error),
        }
    }
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
fn create_tray(
    ctx: &egui::Context,
    action_sender: mpsc::Sender<DesktopAction>,
) -> Result<(TrayIcon, MenuItem, CheckMenuItem), String> {
    let menu = Menu::new();
    let show_hide = MenuItem::new("Hide Magi", true, None);
    let listening = CheckMenuItem::new("Auto-update", true, false, None);
    let separator = PredefinedMenuItem::separator();
    let quit = MenuItem::new("Quit Magi", true, None);
    menu.append_items(&[&show_hide, &listening, &separator, &quit])
        .map_err(|error| format!("Could not create menu: {error}"))?;

    let show_hide_id = show_hide.id().clone();
    let listening_id = listening.id().clone();
    let quit_id = quit.id().clone();
    let repaint = ctx.clone();
    MenuEvent::set_event_handler(Some(move |event: MenuEvent| {
        let action = if event.id == show_hide_id {
            Some(DesktopAction::ToggleWindow)
        } else if event.id == listening_id {
            Some(DesktopAction::ToggleListening)
        } else if event.id == quit_id {
            Some(DesktopAction::Quit)
        } else {
            None
        };
        if let Some(action) = action {
            let _ = action_sender.send(action);
            repaint.request_repaint();
        }
    }));

    let icon = TrayIconBuilder::new()
        .with_tooltip("Magi reading lens")
        .with_icon(magi_icon()?)
        .with_icon_as_template(true)
        .with_menu(Box::new(menu))
        .build()
        .map_err(|error| format!("Could not create menu-bar icon: {error}"))?;
    Ok((icon, show_hide, listening))
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
fn magi_icon() -> Result<Icon, String> {
    const SIZE: usize = 32;
    let mut rgba = vec![0; SIZE * SIZE * 4];
    for y in 5..27 {
        for x in 0..4 {
            set_pixel(&mut rgba, 5 + x, y);
            set_pixel(&mut rgba, 23 + x, y);
        }
    }
    for step in 0..10 {
        for width in 0..3 {
            set_pixel(&mut rgba, 8 + step, 7 + step + width);
            set_pixel(&mut rgba, 21 - step, 7 + step + width);
        }
    }
    Icon::from_rgba(rgba, SIZE as u32, SIZE as u32)
        .map_err(|error| format!("Could not create menu-bar artwork: {error}"))
}

#[cfg(any(target_os = "macos", target_os = "windows"))]
fn set_pixel(rgba: &mut [u8], x: usize, y: usize) {
    let index = (y * 32 + x) * 4;
    rgba[index..index + 4].copy_from_slice(&[255, 255, 255, 255]);
}
