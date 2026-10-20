//! Unreleased blocking local IPC; no policy evaluation or filesystem-content access.
pub mod dto;
pub mod loopback;
#[cfg(unix)] pub mod unix;
#[cfg(windows)] pub mod windows;
pub use dto::*;
use serde::{de::DeserializeOwned, Serialize};
use std::io::{self, Read, Write};
use std::sync::{atomic::{AtomicUsize, Ordering}, Arc};
use std::thread::{self, JoinHandle};

pub const DEFAULT_MAX_FRAME: usize = 1024 * 1024;

/// Shared per-user endpoint. Overrides are interpreted verbatim and validated by
/// the platform listener. This computes a path; it does not create directories.
pub fn default_endpoint() -> io::Result<std::path::PathBuf> {
    for key in ["TINYPRUNE_ENDPOINT", "TINYPRUNE_SOCKET"] {
        if let Some(value) = std::env::var_os(key) {
            if value.is_empty() {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, format!("{key} is empty")));
            }
            return Ok(value.into());
        }
    }
    #[cfg(windows)]
    { windows::default_endpoint() }
    #[cfg(unix)]
    {
        let home = || std::env::var_os("HOME").filter(|v| !v.is_empty())
            .map(std::path::PathBuf::from)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "HOME is not set"));
        #[cfg(target_os = "macos")]
        { Ok(home()?.join("Library/Application Support/TinyPrune/agent.sock")) }
        #[cfg(not(target_os = "macos"))]
        {
            let base = match std::env::var_os("XDG_DATA_HOME").filter(|v| !v.is_empty()) {
                Some(value) => std::path::PathBuf::from(value),
                None => home()?.join(".local/share"),
            };
            Ok(base.join("tinyprune/agent.sock"))
        }
    }
}
fn invalid(message: &str) -> io::Error { io::Error::new(io::ErrorKind::InvalidData, message) }

/// Reject the announced size before allocating the payload buffer.
pub fn read_frame<T: DeserializeOwned>(stream: &mut impl Read, max: usize) -> io::Result<T> {
    let mut header = [0; 4];
    stream.read_exact(&mut header)?;
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 || length > max { return Err(invalid("frame size exceeds limit or is zero")); }
    let mut bytes = vec![0; length];
    stream.read_exact(&mut bytes)?;
    serde_json::from_slice(&bytes).map_err(|e| invalid(&e.to_string()))
}
struct LimitedBuffer { bytes: Vec<u8>, max: usize }
impl Write for LimitedBuffer {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        if bytes.len() > self.max.saturating_sub(self.bytes.len()) { return Err(invalid("frame size exceeds limit")); }
        self.bytes.extend_from_slice(bytes); Ok(bytes.len())
    }
    fn flush(&mut self) -> io::Result<()> { Ok(()) }
}
pub fn write_frame<T: Serialize>(stream: &mut impl Write, value: &T, max: usize) -> io::Result<()> {
    let mut buffer = LimitedBuffer { bytes: Vec::new(), max: max.min(u32::MAX as usize) };
    serde_json::to_writer(&mut buffer, value).map_err(|e| invalid(&e.to_string()))?;
    stream.write_all(&(buffer.bytes.len() as u32).to_be_bytes())?;
    stream.write_all(&buffer.bytes)?;
    stream.flush()
}
pub trait Connection: Read + Write + Send + 'static {}
impl<T: Read + Write + Send + 'static> Connection for T {}
pub trait AgentService: Send + Sync + 'static {
    /// Mutations must be durable/audited before returning acknowledgement. Dispatch does not authorize Trash.
    fn handle(&self, request: Request) -> Response;
}
#[derive(Clone, Copy, Debug)]
pub struct ServerOptions { pub versions: VersionRange, pub max_frame: usize, pub max_connections: usize }
impl Default for ServerOptions {
    fn default() -> Self { Self { versions: VersionRange::default(), max_frame: DEFAULT_MAX_FRAME, max_connections: 16 } }
}
pub struct Server { service: Arc<dyn AgentService>, options: ServerOptions, active: Arc<AtomicUsize> }
struct Permit(Arc<AtomicUsize>);
impl Drop for Permit { fn drop(&mut self) { self.0.fetch_sub(1, Ordering::AcqRel); } }
impl Server {
    pub fn new(service: Arc<dyn AgentService>, options: ServerOptions) -> io::Result<Self> {
        if options.max_connections == 0 || options.max_frame == 0 || options.versions.min > options.versions.max {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid server bounds"));
        }
        Ok(Self { service, options, active: Arc::new(AtomicUsize::new(0)) })
    }
    /// On saturation closes the supplied connection without spawning or queueing a thread.
    pub fn dispatch(&self, stream: impl Connection) -> io::Result<JoinHandle<io::Result<()>>> {
        self.active.fetch_update(Ordering::AcqRel, Ordering::Acquire, |n|
            (n < self.options.max_connections).then_some(n + 1))
            .map_err(|_| io::Error::new(io::ErrorKind::WouldBlock, "connection limit reached"))?;
        let permit = Permit(self.active.clone());
        let service = self.service.clone(); let options = self.options;
        thread::Builder::new().name("tinyprune-ipc".into()).spawn(move || {
            let _permit = permit;
            serve_connection(stream, service.as_ref(), options)
        })
    }
}
fn serve_connection(mut stream: impl Connection, service: &dyn AgentService, options: ServerOptions) -> io::Result<()> {
    let hello: Handshake = read_frame(&mut stream, options.max_frame)?;
    let selected = if hello.protocol_version == hello.versions.max { options.versions.negotiate(hello.versions) } else { None };
    write_frame(&mut stream, &HandshakeReply { protocol_version: selected, versions: options.versions }, options.max_frame)?;
    let version = selected.ok_or_else(|| invalid("unsupported protocol"))?;
    loop {
        let request: RequestEnvelope = match read_frame(&mut stream, options.max_frame) {
            Ok(request) => request,
            Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(()),
            Err(e) => return Err(e),
        };
        let response = if request.protocol_version != version {
            Response::Failure(ServiceError { code: ErrorCode::UnsupportedProtocol, message: "request version differs from handshake".into() })
        } else if matches!(request.request, Request::Unknown) {
            Response::Failure(ServiceError { code: ErrorCode::InvalidRequest, message: "unknown operation".into() })
        } else { service.handle(request.request) };
        write_frame(&mut stream, &ResponseEnvelope { protocol_version: version, response }, options.max_frame)?;
    }
}
pub struct Client<C> { stream: C, version: u32, max_frame: usize }
impl<C: Read + Write> Client<C> {
    pub fn connect(mut stream: C, versions: VersionRange, max_frame: usize) -> io::Result<Self> {
        write_frame(&mut stream, &Handshake { protocol_version: versions.max, versions }, max_frame)?;
        let reply: HandshakeReply = read_frame(&mut stream, max_frame)?;
        let version = reply.protocol_version.filter(|v| versions.negotiate(reply.versions) == Some(*v))
            .ok_or_else(|| invalid("unsupported protocol"))?;
        Ok(Self { stream, version, max_frame })
    }
    /// Transport errors after sending may mean a mutation applied; never automatically retry.
    pub fn request(&mut self, request: Request) -> io::Result<Response> {
        write_frame(&mut self.stream, &RequestEnvelope { protocol_version: self.version, request }, self.max_frame)?;
        let response: ResponseEnvelope = read_frame(&mut self.stream, self.max_frame)?;
        if response.protocol_version != self.version { return Err(invalid("reply protocol mismatch")); }
        Ok(response.response)
    }
    pub fn protocol_version(&self) -> u32 { self.version }
}
