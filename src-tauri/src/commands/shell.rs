#[tauri::command]
pub fn open_url(url: String) -> Result<(), String> {
    open_impl(url)
}

#[cfg(target_os = "linux")]
fn open_impl(url: String) -> Result<(), String> {
    std::process::Command::new("xdg-open")
        .arg(url)
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

#[cfg(target_os = "macos")]
fn open_impl(url: String) -> Result<(), String> {
    std::process::Command::new("open")
        .arg(url)
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

#[cfg(target_os = "windows")]
fn open_impl(url: String) -> Result<(), String> {
    std::process::Command::new("cmd")
        .args(["/c", "start", "", &url])
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

#[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
fn open_impl(_url: String) -> Result<(), String> {
    Ok(())
}
