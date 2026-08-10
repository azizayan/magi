use std::time::{Duration, Instant};

use arboard::Clipboard;
use eframe::egui::{self, Color32, FontFamily, FontId, RichText, Stroke, TextStyle};
use magi::{
    ReaderState,
    markdown::{RenderedMarkdown, SpanKind},
};
use serde::{Deserialize, Serialize};

mod desktop;

use desktop::{DesktopAction, DesktopIntegration, ShortcutChoice};

const SETTINGS_KEY: &str = "magi_settings";
const POLL_INTERVAL: Duration = Duration::from_millis(350);

#[derive(Debug, Serialize, Deserialize)]
#[serde(default)]
struct Settings {
    font_size: f32,
    shortcut: ShortcutChoice,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            font_size: 24.0,
            shortcut: ShortcutChoice::default(),
        }
    }
}

struct MagiApp {
    reader: ReaderState,
    clipboard: Option<Clipboard>,
    clipboard_error: Option<String>,
    last_poll: Instant,
    was_focused: bool,
    prose_font: FontFamily,
    settings: Settings,
    desktop: DesktopIntegration,
    window_visible: bool,
    quitting: bool,
}

impl MagiApp {
    fn new(cc: &eframe::CreationContext<'_>) -> Self {
        let prose_font = install_readable_font(&cc.egui_ctx);
        cc.egui_ctx.all_styles_mut(|style| {
            style
                .text_styles
                .insert(TextStyle::Body, FontId::new(16.0, prose_font.clone()));
            style
                .text_styles
                .insert(TextStyle::Button, FontId::new(15.0, prose_font.clone()));
        });

        let clipboard = Clipboard::new().ok();
        let clipboard_error = clipboard
            .is_none()
            .then(|| "Clipboard access is unavailable on this system.".to_owned());
        let settings: Settings = cc
            .storage
            .and_then(|storage| eframe::get_value(storage, SETTINGS_KEY))
            .unwrap_or_default();

        let desktop = DesktopIntegration::new(&cc.egui_ctx, settings.shortcut);

        Self {
            reader: ReaderState::new(None),
            clipboard,
            clipboard_error,
            last_poll: Instant::now(),
            was_focused: true,
            prose_font,
            settings,
            desktop,
            window_visible: true,
            quitting: false,
        }
    }

    fn handle_desktop_actions(&mut self, ctx: &egui::Context) {
        while let Some(action) = self.desktop.next_action() {
            match action {
                DesktopAction::ToggleWindow => {
                    self.window_visible = !self.window_visible;
                    ctx.send_viewport_cmd(egui::ViewportCommand::Visible(self.window_visible));
                    if self.window_visible {
                        ctx.send_viewport_cmd(egui::ViewportCommand::Focus);
                    }
                    self.desktop.set_window_visible(self.window_visible);
                }
                DesktopAction::ToggleListening => {
                    self.reader.set_listening(!self.reader.is_listening());
                    self.desktop.set_listening(self.reader.is_listening());
                }
                DesktopAction::Quit => {
                    self.quitting = true;
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                }
            }
        }

        if ctx.input(|input| input.viewport().close_requested()) && !self.quitting {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            ctx.send_viewport_cmd(egui::ViewportCommand::Visible(false));
            self.window_visible = false;
            self.desktop.set_window_visible(false);
        }
    }

    fn read_clipboard(&mut self, force: bool) {
        let Some(clipboard) = self.clipboard.as_mut() else {
            return;
        };

        match clipboard.get_text() {
            Ok(text) => {
                self.clipboard_error = None;
                if force {
                    self.reader.capture_now(text);
                } else {
                    self.reader.observe_clipboard(text);
                }
            }
            Err(error) if force => {
                self.clipboard_error = Some(format!("Could not read text from clipboard: {error}"));
            }
            Err(_) => {}
        }
    }

    fn poll_clipboard(&mut self, ctx: &egui::Context) {
        let focused = ctx.input(|input| input.focused);
        if self.was_focused && !focused {
            if let Some(clipboard) = self.clipboard.as_mut()
                && let Ok(text) = clipboard.get_text()
            {
                self.reader.baseline_clipboard(text);
            }
            self.last_poll = Instant::now();
        }
        self.was_focused = focused;

        if !focused && self.reader.is_listening() && self.last_poll.elapsed() >= POLL_INTERVAL {
            self.last_poll = Instant::now();
            self.read_clipboard(false);
        }
        ctx.request_repaint_after(POLL_INTERVAL);
    }

    fn toolbar(&mut self, ui: &mut egui::Ui) {
        ui.horizontal(|ui| {
            let status_color = if self.reader.is_listening() {
                Color32::from_rgb(73, 196, 113)
            } else {
                Color32::from_gray(130)
            };
            ui.label(RichText::new("●").color(status_color));
            ui.label(if self.reader.is_listening() {
                "Listening for copied text"
            } else {
                "Paused"
            });

            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.button("A+").on_hover_text("Larger text").clicked() {
                    self.settings.font_size = (self.settings.font_size + 2.0).min(48.0);
                }
                if ui.button("A−").on_hover_text("Smaller text").clicked() {
                    self.settings.font_size = (self.settings.font_size - 2.0).max(16.0);
                }
            });
        });

        ui.horizontal(|ui| {
            let mut listening = self.reader.is_listening();
            if ui.checkbox(&mut listening, "Auto-update").changed() {
                self.reader.set_listening(listening);
                self.desktop.set_listening(listening);
            }
            if ui.button("Paste now").clicked() {
                self.read_clipboard(true);
            }
            if ui.button("Clear").clicked() {
                self.reader.clear_content();
            }
            ui.label(
                RichText::new("Auto-update reads all copied text while Magi is in the background.")
                    .weak(),
            );
        });

        ui.horizontal(|ui| {
            ui.label("Show/hide shortcut");
            let previous = self.settings.shortcut;
            egui::ComboBox::from_id_salt("global-shortcut")
                .selected_text(self.settings.shortcut.label())
                .show_ui(ui, |ui| {
                    for shortcut in ShortcutChoice::ALL {
                        ui.selectable_value(
                            &mut self.settings.shortcut,
                            shortcut,
                            shortcut.label(),
                        );
                    }
                });
            if self.settings.shortcut != previous {
                self.desktop.set_shortcut(self.settings.shortcut);
            }
        });
    }

    fn reader(&self, ui: &mut egui::Ui) {
        if self.reader.is_empty() {
            ui.vertical_centered(|ui| {
                ui.add_space(80.0);
                ui.heading("Paste a response to read it here");
                ui.add_space(8.0);
                ui.label("Use the Copy button in Codex or Claude Code.");
                ui.label("Then choose Paste now. Auto-update is opt-in.");
            });
            return;
        }

        let rendered = RenderedMarkdown::parse(self.reader.content());
        let mut job = egui::text::LayoutJob::default();
        for span in rendered.spans {
            let (size, family, background) = match span.kind {
                SpanKind::Prose => (
                    self.settings.font_size,
                    self.prose_font.clone(),
                    Color32::TRANSPARENT,
                ),
                SpanKind::Heading(level) => (
                    self.settings.font_size + (7 - level.min(6)) as f32 * 1.5,
                    self.prose_font.clone(),
                    Color32::TRANSPARENT,
                ),
                SpanKind::Code => (
                    (self.settings.font_size - 2.0).max(14.0),
                    FontFamily::Monospace,
                    ui.visuals().faint_bg_color,
                ),
            };
            job.append(
                &span.text,
                0.0,
                egui::TextFormat {
                    font_id: FontId::new(size, family),
                    color: ui.visuals().text_color(),
                    background,
                    line_height: Some(self.settings.font_size * 1.45),
                    ..Default::default()
                },
            );
        }

        egui::ScrollArea::vertical()
            .auto_shrink([false, false])
            .show(ui, |ui| {
                ui.add(egui::Label::new(job).selectable(true).wrap());
            });
    }
}

fn install_readable_font(ctx: &egui::Context) -> FontFamily {
    let family = FontFamily::Name("magi-readable".into());
    for path in readable_font_paths() {
        let Ok(bytes) = std::fs::read(path) else {
            continue;
        };

        let mut fonts = egui::FontDefinitions::default();
        fonts.font_data.insert(
            "magi-readable".to_owned(),
            egui::FontData::from_owned(bytes).into(),
        );
        let fallback_fonts = fonts
            .families
            .get(&FontFamily::Proportional)
            .cloned()
            .unwrap_or_default();
        let family_fonts = fonts.families.entry(family.clone()).or_default();
        family_fonts.push("magi-readable".to_owned());
        family_fonts.extend(fallback_fonts);
        ctx.set_fonts(fonts);
        return family;
    }

    FontFamily::Proportional
}

#[cfg(target_os = "macos")]
fn readable_font_paths() -> &'static [&'static str] {
    &["/System/Library/Fonts/Supplemental/Arial Bold.ttf"]
}

#[cfg(target_os = "windows")]
fn readable_font_paths() -> &'static [&'static str] {
    &[r"C:\Windows\Fonts\arialbd.ttf"]
}

#[cfg(target_os = "linux")]
fn readable_font_paths() -> &'static [&'static str] {
    &[
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
    ]
}

impl eframe::App for MagiApp {
    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        self.handle_desktop_actions(ui.ctx());
        self.poll_clipboard(ui.ctx());

        egui::CentralPanel::default()
            .frame(
                egui::Frame::central_panel(ui.style())
                    .inner_margin(egui::Margin::same(20))
                    .stroke(Stroke::NONE),
            )
            .show(ui, |ui| {
                self.toolbar(ui);
                ui.separator();

                if let Some(error) = &self.clipboard_error {
                    ui.colored_label(Color32::from_rgb(225, 95, 95), error);
                    ui.separator();
                }

                if let Some(error) = self.desktop.error() {
                    ui.colored_label(Color32::from_rgb(225, 155, 75), error);
                    ui.separator();
                }

                self.reader(ui);
            });
    }

    fn save(&mut self, storage: &mut dyn eframe::Storage) {
        eframe::set_value(storage, SETTINGS_KEY, &self.settings);
    }
}

fn main() -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_app_id("com.azizemreayan.magi")
            .with_title("Magi")
            .with_inner_size([620.0, 820.0])
            .with_min_inner_size([420.0, 360.0])
            .with_always_on_top(),
        ..Default::default()
    };

    eframe::run_native(
        "Magi",
        options,
        Box::new(|cc| Ok(Box::new(MagiApp::new(cc)))),
    )
}
