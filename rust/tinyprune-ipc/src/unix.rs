//! Same-effective-uid Unix sockets. The endpoint directory must be private and owned by this user.
use std::fs::{self, DirBuilder};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::{
    fs::{DirBuilderExt, MetadataExt, PermissionsExt},
    net::{UnixListener, UnixStream},
};
use std::path::{Path, PathBuf};
use std::time::Duration;
fn denied(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::PermissionDenied, message)
}
pub fn current_uid() -> u32 {
    unsafe { libc::geteuid() }
}
pub fn verify_peer(stream: &UnixStream, expected_uid: u32) -> io::Result<()> {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    let uid = unsafe {
        let mut credentials: libc::ucred = std::mem::zeroed();
        let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
        if libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut length,
        ) != 0
        {
            return Err(io::Error::last_os_error());
        }
        if length as usize != std::mem::size_of::<libc::ucred>() {
            return Err(denied("invalid peer credentials"));
        }
        credentials.uid
    };
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    let uid = unsafe {
        let mut uid = 0;
        let mut gid = 0;
        if libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) != 0 {
            return Err(io::Error::last_os_error());
        }
        uid
    };
    if uid != expected_uid {
        return Err(denied("peer uid does not match"));
    }
    Ok(())
}
fn configure(stream: &UnixStream) -> io::Result<()> {
    stream.set_nonblocking(false)?;
    // Bound idle connections so a same-user stalled client cannot occupy a worker forever.
    stream.set_read_timeout(Some(Duration::from_secs(30)))?;
    stream.set_write_timeout(Some(Duration::from_secs(30)))
}
pub struct Listener {
    listener: UnixListener,
    path: PathBuf,
    device: u64,
    inode: u64,
}
impl Listener {
    pub fn bind(path: impl AsRef<Path>) -> io::Result<Self> {
        let path = path.as_ref();
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "socket needs a private directory",
                )
            })?;
        match DirBuilder::new().mode(0o700).create(parent) {
            Ok(()) => (),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => (),
            Err(e) => return Err(e),
        }
        let metadata = fs::symlink_metadata(parent)?;
        if !metadata.is_dir() || metadata.uid() != current_uid() || metadata.mode() & 0o777 != 0o700
        {
            return Err(denied(
                "socket directory must be owned by current uid with mode 0700",
            ));
        }
        let listener = UnixListener::bind(path)?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        let metadata = fs::symlink_metadata(path)?;
        Ok(Self {
            listener,
            path: path.to_owned(),
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }
    pub fn accept(&self) -> io::Result<UnixStream> {
        let (stream, _) = self.listener.accept()?;
        verify_peer(&stream, current_uid())?;
        configure(&stream)?;
        Ok(stream)
    }
    pub fn local_path(&self) -> &Path {
        &self.path
    }
    pub fn set_nonblocking(&self, nonblocking: bool) -> io::Result<()> {
        self.listener.set_nonblocking(nonblocking)
    }
}
impl Drop for Listener {
    fn drop(&mut self) {
        if let Ok(m) = fs::symlink_metadata(&self.path) {
            if m.dev() == self.device && m.ino() == self.inode {
                let _ = fs::remove_file(&self.path);
            }
        }
    }
}
pub fn connect(path: impl AsRef<Path>) -> io::Result<UnixStream> {
    let stream = UnixStream::connect(path)?;
    verify_peer(&stream, current_uid())?;
    configure(&stream)?;
    Ok(stream)
}
