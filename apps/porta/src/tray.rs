use crate::update;
use crate::TrayState;
use tauri::async_runtime;
use tauri::menu::{MenuBuilder, MenuItemBuilder};
use tauri::tray::TrayIconBuilder;
use tauri::{Emitter, Manager};

pub fn setup(app: &mut tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    let status_item = MenuItemBuilder::with_id("status", "Cyfr: Starting...")
        .enabled(false)
        .build(app)?;
    let check_updates_item =
        MenuItemBuilder::with_id("check_updates", "Check for Updates").build(app)?;
    let tool_providers_item =
        MenuItemBuilder::with_id("tool_providers", "Tool Providers...").build(app)?;
    let quit_item = MenuItemBuilder::with_id("quit", "Quit").build(app)?;

    let menu = MenuBuilder::new(app)
        .item(&status_item)
        .separator()
        .item(&check_updates_item)
        .item(&tool_providers_item)
        .separator()
        .item(&quit_item)
        .build()?;

    // Use dedicated tray icon (small, works as template for menu bar)
    let tray_icon = tauri::image::Image::from_bytes(include_bytes!("../icons/tray-icon.png"))
        .expect("failed to load tray icon");

    let _tray = TrayIconBuilder::new()
        .tooltip("CYFR")
        .icon(tray_icon)
        .icon_as_template(false)
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(move |app, event| {
            let app = app.clone();
            match event.id().as_ref() {
                "check_updates" => {
                    async_runtime::spawn(async move {
                        match update::check_cyfr_update().await {
                            Some(info) => {
                                update::show_update_banner(&app, &info);
                            }
                            None => {
                                if let Some(state) = app.try_state::<TrayState>() {
                                    let _ = state.status_item.set_text("Cyfr: Up to date");
                                }
                            }
                        }
                    });
                }
                "tool_providers" => {
                    // Emit event for the React frontend to navigate to settings
                    let _ = app.emit("navigate", "settings");
                    // Show and focus the main window (try main first, fall back to boot)
                    if let Some(window) = app.get_webview_window("main") {
                        let _ = window.show();
                        let _ = window.set_focus();
                    } else if let Some(window) = app.get_webview_window("boot") {
                        let _ = window.show();
                        let _ = window.set_focus();
                    }
                }
                "quit" => {
                    app.exit(0);
                }
                _ => {}
            }
        })
        .build(app)?;

    app.manage(TrayState {
        status_item,
    });

    Ok(())
}

