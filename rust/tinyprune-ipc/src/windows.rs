//! Byte-mode named pipes with a protected current-user-only DACL and remote clients rejected.
use std::{fs::File, io, os::windows::io::{AsRawHandle, FromRawHandle}};
use windows::{core::{PCWSTR, PWSTR}, Win32::{Foundation::*, Security::{*, Authorization::*}, Storage::FileSystem::*, System::{Pipes::*, Threading::*}}};
fn error(e: windows::core::Error) -> io::Error { io::Error::from_raw_os_error(e.code().0 & 0xffff) }
struct Owned(HANDLE);
impl Drop for Owned { fn drop(&mut self) { unsafe { let _ = CloseHandle(self.0); } } }
struct Local(*mut std::ffi::c_void);
impl Drop for Local { fn drop(&mut self) { unsafe { LocalFree(Some(HLOCAL(self.0))); } } }
fn wide(text: &str) -> Vec<u16> { text.encode_utf16().chain(Some(0)).collect() }
pub(crate) fn default_endpoint() -> io::Result<std::path::PathBuf> {
    let sid = unsafe { user_sid(GetCurrentProcess())? };
    Ok(format!(r"\\.\pipe\tinyprune-agent-{sid}").into())
}
fn user_sid(process: HANDLE) -> io::Result<String> {
    unsafe {
        let mut token = HANDLE::default();
        OpenProcessToken(process, TOKEN_QUERY, &mut token).map_err(error)?;
        let token = Owned(token);
        let mut size = 0;
        let _ = GetTokenInformation(token.0, TokenUser, None, 0, &mut size);
        if size == 0 { return Err(io::Error::last_os_error()); }
        // usize backing guarantees TOKEN_USER alignment.
        let mut buffer = vec![0usize; (size as usize).div_ceil(std::mem::size_of::<usize>())];
        GetTokenInformation(token.0, TokenUser, Some(buffer.as_mut_ptr().cast()), size, &mut size).map_err(error)?;
        let user = &*buffer.as_ptr().cast::<TOKEN_USER>();
        let mut sid = PWSTR::null();
        ConvertSidToStringSidW(user.User.Sid, &mut sid).map_err(error)?;
        let _free = Local(sid.0.cast());
        sid.to_string().map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))
    }
}
fn verify_process(pid: u32) -> io::Result<()> {
    unsafe {
        let process = Owned(OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).map_err(error)?);
        if user_sid(process.0)? != user_sid(GetCurrentProcess())? {
            return Err(io::Error::new(io::ErrorKind::PermissionDenied, "pipe peer is a different user"));
        }
    }
    Ok(())
}
fn validate_name(name: &str) -> io::Result<()> {
    if !name.starts_with(r"\\.\pipe\") || name[9..].is_empty() || name[9..].contains(['\\', '/', '\0']) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "expected a local named-pipe path"));
    }
    Ok(())
}
fn create(name: &str, first: bool) -> io::Result<File> {
    unsafe {
        let sid = user_sid(GetCurrentProcess())?;
        let sddl = wide(&format!("D:P(A;;GA;;;{sid})"));
        let mut descriptor = PSECURITY_DESCRIPTOR::default();
        ConvertStringSecurityDescriptorToSecurityDescriptorW(PCWSTR(sddl.as_ptr()), SDDL_REVISION_1, &mut descriptor, None).map_err(error)?;
        let _free = Local(descriptor.0);
        let attributes = SECURITY_ATTRIBUTES { nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: descriptor.0, bInheritHandle: false.into() };
        let name = wide(name);
        let flags = PIPE_ACCESS_DUPLEX | if first { FILE_FLAG_FIRST_PIPE_INSTANCE } else { FILE_FLAGS_AND_ATTRIBUTES(0) };
        let handle = CreateNamedPipeW(PCWSTR(name.as_ptr()), flags, PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
            PIPE_UNLIMITED_INSTANCES, 65536, 65536, 30000, Some(&attributes));
        if handle.is_invalid() { return Err(io::Error::last_os_error()); }
        Ok(File::from_raw_handle(handle.0))
    }
}
pub struct Listener { name: String, pending: File, nonblocking: bool }
impl Listener {
    pub fn bind(name: &str) -> io::Result<Self> {
        validate_name(name)?;
        Ok(Self { name: name.into(), pending: create(name, true)?, nonblocking: false })
    }
    /// Only acceptance is nonblocking; accepted worker streams remain blocking.
    pub fn set_nonblocking(&mut self, nonblocking: bool) -> io::Result<()> {
        set_mode(&self.pending, nonblocking)?;
        self.nonblocking = nonblocking;
        Ok(())
    }
    pub fn accept(&mut self) -> io::Result<File> {
        let handle = HANDLE(self.pending.as_raw_handle());
        unsafe {
            if let Err(e) = ConnectNamedPipe(handle, None) {
                let code = e.code().0 as u32 & 0xffff;
                if self.nonblocking && (code == ERROR_PIPE_LISTENING.0 || code == ERROR_NO_DATA.0) {
                    if code == ERROR_NO_DATA.0 { let _ = DisconnectNamedPipe(handle); }
                    return Err(io::Error::new(io::ErrorKind::WouldBlock, "no pipe client"));
                }
                if code != ERROR_PIPE_CONNECTED.0 { return Err(error(e)); }
            }
            let mut pid = 0;
            if let Err(e) = GetNamedPipeClientProcessId(handle, &mut pid) {
                let code = e.code().0 as u32 & 0xffff;
                if self.nonblocking && (code == ERROR_PIPE_LISTENING.0 || code == ERROR_PIPE_NOT_CONNECTED.0) {
                    return Err(io::Error::new(io::ErrorKind::WouldBlock, "no pipe client"));
                }
                return Err(error(e));
            }
            verify_process(pid)?;
        }
        let next = create(&self.name, false)?;
        set_mode(&next, self.nonblocking)?;
        set_mode(&self.pending, false)?;
        Ok(std::mem::replace(&mut self.pending, next))
    }
}
fn set_mode(file: &File, nonblocking: bool) -> io::Result<()> {
    let mode = PIPE_READMODE_BYTE | if nonblocking { PIPE_NOWAIT } else { PIPE_WAIT };
    unsafe { SetNamedPipeHandleState(HANDLE(file.as_raw_handle()), Some(&mode), None, None).map_err(error) }
}
pub fn connect(name: &str) -> io::Result<File> {
    validate_name(name)?;
    let name = wide(name);
    unsafe {
        let handle = CreateFileW(PCWSTR(name.as_ptr()), GENERIC_READ.0 | GENERIC_WRITE.0, FILE_SHARE_MODE(0), None, OPEN_EXISTING, FILE_FLAGS_AND_ATTRIBUTES(0), None).map_err(error)?;
        let file = File::from_raw_handle(handle.0);
        let mut pid = 0;
        GetNamedPipeServerProcessId(handle, &mut pid).map_err(error)?;
        verify_process(pid)?;
        Ok(file)
    }
}
