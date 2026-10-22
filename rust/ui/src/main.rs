#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use tinyprune_ipc::{Client, Request, Response, VersionRange, DEFAULT_MAX_FRAME};

fn unreachable(endpoint: &std::path::Path, error: &std::io::Error) -> String {
    use std::io::ErrorKind::{ConnectionRefused, NotFound, PermissionDenied};
    let reason = match error.kind() {
        NotFound | ConnectionRefused => "The TinyPrune agent is not running or is not listening there.",
        PermissionDenied => "This account may not use that agent endpoint.",
        _ => "The agent endpoint could not be opened.",
    };
    format!("{reason} Endpoint: {} ({error})", endpoint.display())
}

fn request_agent(request: Request) -> Result<Response, String> {
    let endpoint = tinyprune_ipc::default_endpoint().map_err(|e| e.to_string())?;
    #[cfg(unix)]
    let stream = tinyprune_ipc::unix::connect(&endpoint).map_err(|e| unreachable(&endpoint, &e))?;
    #[cfg(windows)]
    let stream = tinyprune_ipc::windows::connect(endpoint.to_str().ok_or("Endpoint is not valid Unicode")?)
        .map_err(|e| unreachable(&endpoint, &e))?;
    let mut client = Client::connect(stream, VersionRange::default(), DEFAULT_MAX_FRAME)
        .map_err(|e| e.to_string())?;
    client.request(request).map_err(|e| {
        format!("Agent connection failed. A mutation may have applied; reload before retrying. {e}")
    })
}

#[tauri::command]
async fn agent_request(request: Request) -> Result<Response, String> {
    tauri::async_runtime::spawn_blocking(move || request_agent(request))
        .await
        .map_err(|e| e.to_string())?
}

#[tauri::command]
fn ui_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// The `tinyprune` CLI shipped beside this executable (a managed install resolves both into the same
/// `versions/<name>/bin`), else the one on PATH. The CLI owns the signed-feed check and trust decisions.
fn cli_path() -> std::path::PathBuf {
    let name = if cfg!(windows) { "tinyprune.exe" } else { "tinyprune" };
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|dir| dir.join(name)))
        .filter(|path| path.is_file())
        .unwrap_or_else(|| name.into())
}

/// Runs `tinyprune update check --json` and returns its stdout. Failures that the CLI itself describes
/// (offline, feed rejected, updates disabled) are JSON on stdout with a non-zero exit, so they are
/// returned as `Ok` for the frontend to word; `Err` means the CLI could not be run or said nothing.
fn run_update_check() -> Result<String, String> {
    let mut command = std::process::Command::new(cli_path());
    command.args(["update", "check", "--json"]).stdin(std::process::Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    }
    let output = command.output().map_err(|e| {
        format!("Could not run the tinyprune command-line tool that checks for updates ({e}). Reinstall TinyPrune or put `tinyprune` on PATH.")
    })?;
    let stdout = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if !stdout.is_empty() {
        return Ok(stdout);
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    Err(format!("The update check ended without an answer ({}). {}", output.status, stderr.trim()))
}

#[tauri::command]
async fn update_check() -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(run_update_check)
        .await
        .map_err(|e| e.to_string())?
}

fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![agent_request, ui_version, update_check])
        .run(tauri::generate_context!())
        .expect("cannot start TinyPrune development UI");
}
