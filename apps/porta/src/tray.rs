use crate::update;
use crate::TrayState;
use tauri::async_runtime;
use tauri::menu::{MenuBuilder, MenuItemBuilder};
use tauri::tray::TrayIconBuilder;
use tauri::Manager;

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

    let _tray = TrayIconBuilder::new()
        .tooltip("CYFR Porta")
        .icon(app.default_window_icon().cloned().expect("no app icon"))
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
                    open_settings_window(&app);
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

pub fn open_settings_window(app: &tauri::AppHandle) {
    if let Some(window) = app.get_webview_window("settings") {
        let _ = window.set_focus();
        return;
    }

    let _ = tauri::WebviewWindowBuilder::new(
        app,
        "settings",
        tauri::WebviewUrl::App("settings/index.html".into()),
    )
    .title("Tool Providers")
    .inner_size(720.0, 560.0)
    .center()
    .build();
}
