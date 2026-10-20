#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]
use tinyprune_ipc::{Client, Request, Response, VersionRange, DEFAULT_MAX_FRAME};

fn request_agent(request: Request) -> Result<Response, String> {
    let endpoint = tinyprune_ipc::default_endpoint().map_err(|e| e.to_string())?;
    #[cfg(unix)]
    let stream = tinyprune_ipc::unix::connect(endpoint).map_err(|e| e.to_string())?;
    #[cfg(windows)]
    let stream =
        tinyprune_ipc::windows::connect(endpoint.to_str().ok_or("Endpoint is not valid Unicode")?)
            .map_err(|e| e.to_string())?;
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
fn main() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![agent_request])
        .run(tauri::generate_context!())
        .expect("cannot start TinyPrune development UI");
}
