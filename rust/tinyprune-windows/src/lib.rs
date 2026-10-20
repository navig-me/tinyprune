//! Unreleased Windows metadata and Recycle Bin adapter; not a platform agent.
#![cfg(windows)]

use std::cell::RefCell;
use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::windows::fs::{MetadataExt, OpenOptionsExt};
use std::os::windows::io::AsRawHandle;
use std::path::{Component, Path, PathBuf};
use std::rc::Rc;
use std::time::{SystemTime, UNIX_EPOCH};
use tinyprune_core::resolve::{ItemOverridePolicy, ItemPolicyOverride};
use tinyprune_core::rule::{CandidateTimestamps, FilesystemIdentity, ItemKind, RuleCandidate, PathFlavor};
use tinyprune_core::trash::{DescendantProtection, FileAccess, WalkBudget};
use tinyprune_core::uuid::Uuid;
use windows::core::{implement, Error, HRESULT, PCWSTR, Ref};
use windows::Win32::Foundation::{E_ABORT, HANDLE};
use windows::Win32::Globalization::{CompareStringOrdinal, CSTR_EQUAL};
use windows::Win32::Storage::FileSystem::*;
use windows::Win32::System::Com::*;
use windows::Win32::System::Registry::*;
use windows::Win32::System::WindowsProgramming::DRIVE_FIXED;
use windows::Win32::UI::Shell::*;


/// Use for core rule scopes, settings, and managed-root validation in Windows integrations.
pub const PATH_FLAVOR: PathFlavor = PathFlavor::Windows;
pub struct WindowsFileAccess {
    now: fn() -> f64,
}

impl Default for WindowsFileAccess {
    fn default() -> Self { Self::new(system_now) }
}

impl WindowsFileAccess {
    /// Inject wall time for deterministic walk-budget tests. No sleeps or content reads.
    pub fn new(now: fn() -> f64) -> Self { Self { now } }
}

fn system_now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs_f64()
}

fn io_error(error: io::Error) -> String {
    match error.raw_os_error() {
        Some(32 | 33) => format!("transient sharing violation; defer and retry: {error}"),
        _ => error.to_string(),
    }
}

fn com_error(error: Error) -> String {
    if matches!(error.code().0 as u32, 0x80070020 | 0x80070021) {
        format!("transient sharing violation; defer and retry: {error}")
    } else { error.to_string() }
}

fn wide(text: &str) -> Result<Vec<u16>, String> {
    if text.contains('\0') { return Err("NUL in filesystem path".into()); }
    Ok(text.encode_utf16().chain(Some(0)).collect())
}

/// Normalize separators and the extended-length prefix, but never Unicode-normalize.
fn display_path(path: &str) -> String {
    let path = path.replace('/', "\\");
    if let Some(rest) = path.strip_prefix("\\\\?\\UNC\\") { format!("\\\\{rest}") }
    else { path.strip_prefix("\\\\?\\").unwrap_or(&path).to_owned() }
}

pub fn path_hints_equal(a: &str, b: &str) -> bool {
    let a: Vec<u16> = PATH_FLAVOR.normalize(a).encode_utf16().collect();
    let b: Vec<u16> = PATH_FLAVOR.normalize(b).encode_utf16().collect();
    // SAFETY: slices are valid UTF-16 buffers with explicit lengths, not nul-terminated strings.
    unsafe { CompareStringOrdinal(&a, &b, true) == CSTR_EQUAL }
}

fn within(path: &str, root: &str) -> bool {
    let path = display_path(path);
    let root = display_path(root);
    let root = root.trim_end_matches('\\');
    path_hints_equal(&path, root) || path.char_indices().filter(|(_, c)| *c == '\\')
        .any(|(i, _)| path_hints_equal(&path[..i], root))
}

fn absolute(path: &str) -> Result<PathBuf, String> {
    let plain = display_path(path);
    let p = Path::new(&plain);
    if !p.is_absolute() || p.components().any(|c| matches!(c, Component::ParentDir | Component::CurDir))
        || plain.split('\\').skip(1).any(|part| part.contains(':') || part.ends_with('.') || part.ends_with(' ')) {
        return Err("expected absolute Windows path without dot components, streams or ambiguous suffixes".into());
    }
    wide(&plain)?;
    Ok(PathBuf::from(if let Some(unc) = plain.strip_prefix("\\\\") {
        format!("\\\\?\\UNC\\{unc}")
    } else { format!("\\\\?\\{plain}") }))
}

fn text(path: &Path) -> Result<&str, String> {
    path.to_str().ok_or_else(|| "path is not UTF-8; never converted lossily".into())
}

fn metadata_handle(path: &Path) -> Result<File, String> {
    OpenOptions::new().access_mode(FILE_READ_ATTRIBUTES.0)
        .share_mode(FILE_SHARE_READ.0 | FILE_SHARE_WRITE.0 | FILE_SHARE_DELETE.0)
        .custom_flags(FILE_FLAG_BACKUP_SEMANTICS.0 | FILE_FLAG_OPEN_REPARSE_POINT.0)
        .open(path).map_err(io_error)
}

fn inspect_path(path: &str) -> Result<Option<RuleCandidate>, String> {
    let native = absolute(path)?;
    let file = match metadata_handle(&native) {
        Ok(file) => file,
        Err(error) => {
            // Preserve not-found as absence; other failures remain errors (including sharing violations).
            match fs::symlink_metadata(&native) {
                Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
                _ => return Err(error),
            }
        }
    };
    let m = file.metadata().map_err(io_error)?;
    if m.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0 {
        return Err("reparse points (including junctions and mount points) are not eligible".into());
    }
    reject_ancestors(&native)?;
    let mut id = FILE_ID_INFO::default();
    // SAFETY: live handle, correctly sized initialized output buffer for FileIdInfo.
    unsafe { GetFileInformationByHandleEx(HANDLE(file.as_raw_handle()), FileIdInfo,
        (&mut id as *mut FILE_ID_INFO).cast(), std::mem::size_of::<FILE_ID_INFO>() as u32) }.map_err(com_error)?;
    let time = |ticks: u64| ticks as f64 / 10_000_000.0 - 11_644_473_600.0;
    let created = Some(time(m.creation_time()));
    Ok(Some(RuleCandidate {
        identity: FilesystemIdentity { volume: Uuid(id.VolumeSerialNumber as u128),
            resource: id.FileId.Identifier.to_vec(), path_hint: display_path(path),
            creation_time: created, generation: None, is_persistent: false },
        name: native.file_name().and_then(|n| n.to_str()).ok_or("filesystem root is not an item")?.into(),
        kind: if m.is_dir() { ItemKind::Directory } else { ItemKind::File },
        platform_hidden: m.file_attributes() & FILE_ATTRIBUTE_HIDDEN.0 != 0,
        timestamps: CandidateTimestamps { created, modified: Some(time(m.last_write_time())),
            accessed: Some(time(m.last_access_time())), ..Default::default() },
    }))
}

fn reparse(path: &Path) -> Result<bool, String> {
    Ok(fs::symlink_metadata(path).map_err(io_error)?.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0)
}

fn reject_ancestors(path: &Path) -> Result<(), String> {
    for ancestor in path.ancestors() {
        if reparse(ancestor)? { return Err("reparse point in item or ancestor".into()); }
    }
    Ok(())
}

fn registry_dword(key: HKEY, subkey: &str, value: &str) -> Result<Option<u32>, String> {
    let subkey = wide(subkey)?;
    let value = wide(value)?;
    let mut data = 0u32;
    let mut length = 4u32;
    // SAFETY: valid nul-terminated names and correctly sized DWORD output; no registry writes.
    let status = unsafe { RegGetValueW(key, PCWSTR(subkey.as_ptr()), PCWSTR(value.as_ptr()),
        RRF_RT_REG_DWORD, None, Some((&mut data as *mut u32).cast()), Some(&mut length)) };
    match status.0 {
        0 => Ok(Some(data)),
        2 | 3 => Ok(None),
        _ => Err(format!("cannot establish Recycle Bin policy: {}", status.0)),
    }
}

fn recycle_available(path: &str) -> Result<(), String> {
    let path = wide(text(&absolute(path)?)?)?;
    let mut root = vec![0u16; 32768];
    // SAFETY: input is nul-terminated; output buffer has its supplied length.
    unsafe { GetVolumePathNameW(PCWSTR(path.as_ptr()), &mut root) }.map_err(com_error)?;
    // SAFETY: GetVolumePathNameW initialized a nul-terminated root.
    if unsafe { GetDriveTypeW(PCWSTR(root.as_ptr())) } != DRIVE_FIXED {
        return Err("Recycle Bin requires a local fixed volume; network/removable drives refused".into());
    }
    for hive in [HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE] {
        if registry_dword(hive, "Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer", "NoRecycleFiles")?.unwrap_or(0) != 0 {
            return Err("Recycle Bin disabled by policy".into());
        }
    }
    let mut volume = vec![0u16; 64];
    // SAFETY: root is nul-terminated and volume is a writable output slice.
    unsafe { GetVolumeNameForVolumeMountPointW(PCWSTR(root.as_ptr()), &mut volume) }.map_err(com_error)?;
    let end = volume.iter().position(|c| *c == 0).ok_or("unterminated volume name")?;
    let volume = String::from_utf16(&volume[..end]).map_err(|e| e.to_string())?;
    let guid = volume.strip_prefix("\\\\?\\Volume").and_then(|v| v.strip_suffix('\\')).ok_or("unexpected volume GUID name")?;
    let settings = format!("Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\BitBucket\\Volume\\{guid}");
    if registry_dword(HKEY_CURRENT_USER, &settings, "NukeOnDelete")?.unwrap_or(0) != 0
        || registry_dword(HKEY_CURRENT_USER, &settings, "MaxCapacity")? == Some(0)
        || registry_dword(HKEY_CURRENT_USER, "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\BitBucket", "NukeOnDelete")?.unwrap_or(0) != 0 {
        return Err("Recycle Bin disabled for this volume".into());
    }
    let mut query = SHQUERYRBINFO { cbSize: std::mem::size_of::<SHQUERYRBINFO>() as u32, ..Default::default() };
    // SAFETY: root is nul-terminated; query has the required cbSize and lives for the call.
    unsafe { SHQueryRecycleBinW(PCWSTR(root.as_ptr()), &mut query) }.map_err(com_error)
}

impl FileAccess for WindowsFileAccess {
    fn inspect(&mut self, path: &str) -> Result<Option<RuleCandidate>, String> { inspect_path(path) }

    fn has_symbolic_link_ancestor(&mut self, path: &str, below_root: &str) -> Result<bool, String> {
        let native = absolute(path)?;
        absolute(below_root)?;
        if !within(path, below_root) { return Err("item outside managed root".into()); }
        // Include the item AND managed root: any kind of reparse point fails closed.
        for ancestor in native.ancestors() {
            if reparse(ancestor)? { return Ok(true); }
            if path_hints_equal(text(ancestor)?, below_root) { return Ok(false); }
        }
        Err("managed root not found in item ancestry".into())
    }

    fn has_protected_descendant(&mut self, path: &str, overrides: &[ItemPolicyOverride], hidden: bool, budget: WalkBudget) -> Result<DescendantProtection, String> {
        let native = absolute(path)?;
        reject_ancestors(&native)?;
        if overrides.iter().any(|o| matches!(o.policy, ItemOverridePolicy::Keep { .. }) && within(&o.path, path)) {
            return Ok(DescendantProtection::Protected);
        }
        let mut stack = vec![fs::read_dir(native).map_err(io_error)?];
        let mut visited = 0;
        while let Some(entries) = stack.last_mut() {
            if visited >= budget.max_entries || !budget.deadline.is_finite() || (self.now)() >= budget.deadline {
                return Ok(DescendantProtection::Indeterminate);
            }
            let Some(entry) = entries.next() else { stack.pop(); continue; };
            let child = entry.map_err(io_error)?.path();
            visited += 1;
            let m = fs::symlink_metadata(&child).map_err(io_error)?;
            if m.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT.0 != 0 { return Ok(DescendantProtection::Protected); }
            let item = inspect_path(text(&child)?)?.ok_or("descendant disappeared during walk")?;
            if hidden && (item.name.starts_with('.') || m.file_attributes() & FILE_ATTRIBUTE_HIDDEN.0 != 0) {
                return Ok(DescendantProtection::Protected);
            }
            if overrides.iter().any(|o| {
                let ItemOverridePolicy::Keep { protect_descendants } = o.policy else { return false };
                o.identity.as_ref().is_some_and(|id| *id == item.identity)
                    || path_hints_equal(&o.path, &item.identity.path_hint)
                    || (protect_descendants && within(&item.identity.path_hint, &o.path))
            }) { return Ok(DescendantProtection::Protected); }
            if m.is_dir() { stack.push(fs::read_dir(child).map_err(io_error)?); }
        }
        Ok(DescendantProtection::None)
    }

    fn move_to_trash(&mut self, path: &str, expected: &FilesystemIdentity) -> Result<String, String> {
        let native = absolute(path)?;
        reject_ancestors(&native)?;
        if !path_hints_equal(path, &expected.path_hint) { return Err("identity path hint changed".into()); }
        if inspect_path(path)?.ok_or("item disappeared")?.identity != *expected { return Err("filesystem identity changed".into()); }
        recycle_available(path)?;
        recycle(path, expected)
    }
}

struct Apartment;
impl Drop for Apartment {
    fn drop(&mut self) {
        // SAFETY: constructed only after this thread successfully initialized COM.
        unsafe { CoUninitialize() };
    }
}

#[derive(Default)]
struct RecycleResult { destination: Option<String>, error: Option<String> }

#[implement(IFileOperationProgressSink)]
struct RecycleSink { path: String, expected: FilesystemIdentity, result: Rc<RefCell<RecycleResult>> }

#[allow(non_snake_case)]
impl IFileOperationProgressSink_Impl for RecycleSink_Impl {
    fn StartOperations(&self) -> windows::core::Result<()> { Ok(()) }
    fn FinishOperations(&self, result: HRESULT) -> windows::core::Result<()> { result.ok() }
    fn PreDeleteItem(&self, flags: u32, _item: Ref<IShellItem>) -> windows::core::Result<()> {
        let check = (|| {
            if flags & TSF_DELETE_RECYCLE_IF_POSSIBLE.0 as u32 == 0 { return Err("Shell proposed permanent deletion; refused".into()); }
            reject_ancestors(&absolute(&self.path)?)?;
            recycle_available(&self.path)?;
            if inspect_path(&self.path)?.ok_or("item disappeared")?.identity != self.expected {
                return Err("identity changed in Shell pre-delete callback".into());
            }
            Ok(())
        })();
        if let Err(error) = check {
            self.result.borrow_mut().error = Some(error);
            return Err(Error::from_hresult(E_ABORT));
        }
        Ok(())
    }
    fn PostDeleteItem(&self, _flags: u32, _item: Ref<IShellItem>, result: HRESULT, created: Ref<IShellItem>) -> windows::core::Result<()> {
        result.ok()?;
        let item = created.as_ref().ok_or_else(|| Error::from_hresult(E_ABORT))?;
        // SAFETY: live Shell item; returned COM-allocated string is freed immediately below.
        let name = unsafe { item.GetDisplayName(SIGDN_FILESYSPATH)? };
        // SAFETY: Shell returned a valid nul-terminated string owned by this callback.
        let path = unsafe { name.to_string() };
        // SAFETY: GetDisplayName allocates with the COM task allocator.
        unsafe { CoTaskMemFree(Some(name.0.cast())) };
        self.result.borrow_mut().destination = Some(path?);
        Ok(())
    }
    fn PreRenameItem(&self, _: u32, _: Ref<IShellItem>, _: &PCWSTR) -> windows::core::Result<()> { Err(Error::from_hresult(E_ABORT)) }
    fn PostRenameItem(&self, _: u32, _: Ref<IShellItem>, _: &PCWSTR, _: HRESULT, _: Ref<IShellItem>) -> windows::core::Result<()> { Ok(()) }
    fn PreMoveItem(&self, _: u32, _: Ref<IShellItem>, _: Ref<IShellItem>, _: &PCWSTR) -> windows::core::Result<()> { Err(Error::from_hresult(E_ABORT)) }
    fn PostMoveItem(&self, _: u32, _: Ref<IShellItem>, _: Ref<IShellItem>, _: &PCWSTR, _: HRESULT, _: Ref<IShellItem>) -> windows::core::Result<()> { Ok(()) }
    fn PreCopyItem(&self, _: u32, _: Ref<IShellItem>, _: Ref<IShellItem>, _: &PCWSTR) -> windows::core::Result<()> { Err(Error::from_hresult(E_ABORT)) }
    fn PostCopyItem(&self, _: u32, _: Ref<IShellItem>, _: Ref<IShellItem>, _: &PCWSTR, _: HRESULT, _: Ref<IShellItem>) -> windows::core::Result<()> { Ok(()) }
    fn PreNewItem(&self, _: u32, _: Ref<IShellItem>, _: &PCWSTR) -> windows::core::Result<()> { Err(Error::from_hresult(E_ABORT)) }
    fn PostNewItem(&self, _: u32, _: Ref<IShellItem>, _: &PCWSTR, _: &PCWSTR, _: u32, _: HRESULT, _: Ref<IShellItem>) -> windows::core::Result<()> { Ok(()) }
    fn UpdateProgress(&self, _: u32, _: u32) -> windows::core::Result<()> { Ok(()) }
    fn ResetTimer(&self) -> windows::core::Result<()> { Ok(()) }
    fn PauseTimer(&self) -> windows::core::Result<()> { Ok(()) }
    fn ResumeTimer(&self) -> windows::core::Result<()> { Ok(()) }
}

fn recycle(path: &str, expected: &FilesystemIdentity) -> Result<String, String> {
    // SAFETY: this synchronous operation owns its STA initialization on this thread.
    unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) }.ok().map_err(com_error)?;
    let _apartment = Apartment;
    let result = Rc::new(RefCell::new(RecycleResult::default()));
    let sink: IFileOperationProgressSink = RecycleSink { path: path.into(), expected: expected.clone(), result: result.clone() }.into();
    let native = absolute(path)?;
    let path = wide(text(&native)?)?;
    let stage = std::cell::Cell::new("create IFileOperation");
    // SAFETY: COM initialized above; all interfaces and nul-terminated buffers live through PerformOperations.
    let operation_result = unsafe {
        (|| -> windows::core::Result<()> {
            let operation: IFileOperation = CoCreateInstance(&FileOperation, None, CLSCTX_INPROC_SERVER)?;
            stage.set("SetOperationFlags");
            operation.SetOperationFlags(FOFX_RECYCLEONDELETE | FOF_ALLOWUNDO | FOF_SILENT | FOF_NOERRORUI | FOFX_EARLYFAILURE | FOF_WANTNUKEWARNING | FOF_NO_CONNECTED_ELEMENTS)?;
            stage.set("SHCreateItemFromParsingName");
            let item: IShellItem = SHCreateItemFromParsingName(PCWSTR(path.as_ptr()), None)?;
            stage.set("DeleteItem");
            operation.DeleteItem(&item, &sink)?;
            stage.set("PerformOperations");
            operation.PerformOperations()?;
            stage.set("GetAnyOperationsAborted");
            if operation.GetAnyOperationsAborted()?.as_bool() { return Err(Error::from_hresult(E_ABORT)); }
            Ok(())
        })()
    };
    let mut state = result.borrow_mut();
    if let Some(error) = state.error.take() { return Err(error); }
    operation_result.map_err(|error| format!("{} failed at {}", com_error(error), stage.get()))?;
    state.destination.take().ok_or_else(|| "Shell did not report a recycled destination; no success claimed".into())
}

#[cfg(test)]
mod tests;
