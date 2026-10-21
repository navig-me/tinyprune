//! Hardened extraction of the release archive (Linux `.tar.gz`, Windows `.zip`).
//!
//! The archive has already been authenticated by SHA-256 against the signed feed; this is defense in
//! depth against a bad build or a future signing mistake: no path escapes, no links or special files,
//! bounded entry count and (decompressed) size, one top-level directory which is stripped.

use crate::manifest::ArchiveKind;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy)]
pub struct Limits {
    pub max_entries: usize,
    pub max_total_bytes: u64,
    pub max_file_bytes: u64,
}
impl Default for Limits {
    fn default() -> Self {
        Self {
            max_entries: 5_000,
            max_total_bytes: 1024 * 1024 * 1024,
            max_file_bytes: 512 * 1024 * 1024,
        }
    }
}

#[derive(Debug)]
pub enum ArchiveError {
    UnsafePath(String),
    UnsupportedEntry(String),
    TooManyEntries,
    TooLarge,
    /// Entries do not share exactly one top-level directory.
    Layout(String),
    Format(String),
    Io(String),
}
impl std::fmt::Display for ArchiveError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnsafePath(p) => write!(f, "archive entry has an unsafe path: {p:?}"),
            Self::UnsupportedEntry(p) => {
                write!(f, "archive entry {p:?} is not a regular file or directory")
            }
            Self::TooManyEntries => f.write_str("archive has too many entries"),
            Self::TooLarge => f.write_str("archive expands beyond its size limit"),
            Self::Layout(m) => write!(f, "archive layout rejected: {m}"),
            Self::Format(m) => write!(f, "archive is corrupt: {m}"),
            Self::Io(m) => write!(f, "could not extract archive: {m}"),
        }
    }
}
impl std::error::Error for ArchiveError {}
impl From<io::Error> for ArchiveError {
    fn from(e: io::Error) -> Self {
        Self::Io(e.to_string())
    }
}

/// Split a raw entry name into safe components (top-level directory included).
fn components(raw: &str) -> Result<Vec<&str>, ArchiveError> {
    let unsafe_path = || ArchiveError::UnsafePath(raw.to_owned());
    if raw.is_empty() || raw.starts_with('/') || raw.contains('\\') || raw.contains('\0') {
        return Err(unsafe_path());
    }
    let mut parts = Vec::new();
    for part in raw.trim_end_matches('/').split('/') {
        if part.is_empty()
            || part == "."
            || part == ".."
            || part.contains(':')
            || part.chars().any(char::is_control)
            || part.len() > 255
        {
            return Err(unsafe_path());
        }
        parts.push(part);
    }
    Ok(parts)
}

struct Sink {
    dest: PathBuf,
    top: Option<String>,
    limits: Limits,
    entries: usize,
    total: u64,
}
impl Sink {
    fn new(dest: &Path, limits: Limits) -> Self {
        Self {
            dest: dest.to_owned(),
            top: None,
            limits,
            entries: 0,
            total: 0,
        }
    }
    /// Validate and map an entry name to a path under `dest` (None for the top directory itself).
    fn target(&mut self, raw: &str) -> Result<Option<PathBuf>, ArchiveError> {
        self.entries += 1;
        if self.entries > self.limits.max_entries {
            return Err(ArchiveError::TooManyEntries);
        }
        let parts = components(raw)?;
        match &self.top {
            None => self.top = Some(parts[0].to_owned()),
            Some(top) if top != parts[0] => {
                return Err(ArchiveError::Layout("more than one top-level entry".into()))
            }
            Some(_) => {}
        }
        Ok((parts.len() > 1).then(|| parts[1..].iter().fold(self.dest.clone(), |p, c| p.join(c))))
    }
    fn make_dir(&self, path: &Path) -> Result<(), ArchiveError> {
        fs::create_dir_all(path)?;
        Ok(())
    }
    fn write_file(
        &mut self,
        path: &Path,
        reader: &mut dyn Read,
        mode: u32,
    ) -> Result<(), ArchiveError> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(if mode & 0o111 != 0 { 0o755 } else { 0o644 });
        }
        #[cfg(not(unix))]
        let _ = mode;
        let mut file: File = options.open(path)?;
        let allowance = self
            .limits
            .max_file_bytes
            .min(self.limits.max_total_bytes - self.total);
        let copied = io::copy(&mut reader.take(allowance + 1), &mut file)?;
        if copied > allowance {
            return Err(ArchiveError::TooLarge);
        }
        self.total += copied;
        file.sync_all()?;
        Ok(())
    }
}

/// Extract into the (not yet existing) directory `dest`. On any error `dest` is removed.
pub fn extract(
    kind: ArchiveKind,
    archive: &Path,
    dest: &Path,
    limits: Limits,
) -> Result<(), ArchiveError> {
    fs::create_dir(dest)?;
    let result = match kind {
        ArchiveKind::TarGz => extract_tar_gz(archive, dest, limits),
        ArchiveKind::Zip => extract_zip(archive, dest, limits),
    };
    if result.is_err() {
        let _ = fs::remove_dir_all(dest);
    }
    result
}

fn extract_tar_gz(archive: &Path, dest: &Path, limits: Limits) -> Result<(), ArchiveError> {
    // Bound the decompressed stream (headers/padding included) so a gzip bomb stops early.
    let ceiling = limits.max_total_bytes + limits.max_entries as u64 * 2048 + 1024 * 1024;
    let decoder = flate2::read::GzDecoder::new(File::open(archive)?).take(ceiling);
    let mut tar = tar::Archive::new(decoder);
    let mut sink = Sink::new(dest, limits);
    let format = |e: io::Error| ArchiveError::Format(e.to_string());
    for entry in tar.entries().map_err(format)? {
        let mut entry = entry.map_err(format)?;
        let name = entry
            .path()
            .map_err(format)?
            .to_str()
            .ok_or_else(|| ArchiveError::UnsafePath("non-UTF-8 name".into()))?
            .to_owned();
        let kind = entry.header().entry_type();
        if kind.is_pax_global_extensions()
            || kind.is_pax_local_extensions()
            || kind.is_gnu_longname()
            || kind.is_gnu_longlink()
        {
            continue;
        }
        let mode = entry.header().mode().unwrap_or(0o644);
        let target = sink.target(&name)?;
        if kind.is_dir() {
            if let Some(path) = target {
                sink.make_dir(&path)?;
            }
        } else if kind.is_file() {
            let path =
                target.ok_or_else(|| ArchiveError::Layout("top-level entry is a file".into()))?;
            sink.write_file(&path, &mut entry, mode)?;
        } else {
            return Err(ArchiveError::UnsupportedEntry(name));
        }
    }
    finish(&sink)
}

fn extract_zip(archive: &Path, dest: &Path, limits: Limits) -> Result<(), ArchiveError> {
    let mut zip = zip::ZipArchive::new(File::open(archive)?)
        .map_err(|e| ArchiveError::Format(e.to_string()))?;
    let mut sink = Sink::new(dest, limits);
    for index in 0..zip.len() {
        if index >= limits.max_entries {
            return Err(ArchiveError::TooManyEntries);
        }
        let mut entry = zip
            .by_index(index)
            .map_err(|e| ArchiveError::Format(e.to_string()))?;
        let name = entry
            .name()
            .map_err(|_| ArchiveError::UnsafePath("non-UTF-8 name".into()))?
            .into_owned();
        if entry.unix_mode().is_some_and(|m| {
            matches!(
                m & 0o170000,
                0o120000 | 0o020000 | 0o060000 | 0o010000 | 0o140000
            )
        }) {
            return Err(ArchiveError::UnsupportedEntry(name));
        }
        let mode = entry.unix_mode().unwrap_or(0o644);
        let target = sink.target(&name)?;
        if entry.is_dir() {
            if let Some(path) = target {
                sink.make_dir(&path)?;
            }
        } else {
            let path =
                target.ok_or_else(|| ArchiveError::Layout("top-level entry is a file".into()))?;
            sink.write_file(&path, &mut entry, mode)?;
        }
    }
    finish(&sink)
}

fn finish(sink: &Sink) -> Result<(), ArchiveError> {
    if sink.top.is_none() {
        return Err(ArchiveError::Layout("archive is empty".into()));
    }
    Ok(())
}

#[cfg(test)]
pub(crate) mod testing {
    use std::io::Write;

    pub enum Entry<'a> {
        File(&'a str, &'a [u8], u32),
        Dir(&'a str),
        Symlink(&'a str, &'a str),
        Hardlink(&'a str, &'a str),
    }

    /// Writes names verbatim (the tar builder API would refuse `..`/absolute paths).
    pub fn tar_gz(entries: &[Entry]) -> Vec<u8> {
        let mut raw = Vec::new();
        for entry in entries {
            let (name, kind, data, mode, link): (&str, u8, &[u8], u32, &str) = match entry {
                Entry::File(n, d, m) => (n, b'0', d, *m, ""),
                Entry::Dir(n) => (n, b'5', &[][..], 0o755, ""),
                Entry::Symlink(n, t) => (n, b'2', &[][..], 0o777, t),
                Entry::Hardlink(n, t) => (n, b'1', &[][..], 0o644, t),
            };
            let mut header = [0u8; 512];
            header[..name.len()].copy_from_slice(name.as_bytes());
            header[100..107].copy_from_slice(format!("{mode:07o}").as_bytes());
            header[108..115].copy_from_slice(b"0000000");
            header[116..123].copy_from_slice(b"0000000");
            header[124..135].copy_from_slice(format!("{:011o}", data.len()).as_bytes());
            header[136..147].copy_from_slice(b"00000000000");
            header[156] = kind;
            header[157..157 + link.len()].copy_from_slice(link.as_bytes());
            header[257..263].copy_from_slice(b"ustar\0");
            header[263..265].copy_from_slice(b"00");
            header[148..156].fill(b' ');
            let sum: u32 = header.iter().map(|b| *b as u32).sum();
            header[148..155].copy_from_slice(format!("{sum:06o}\0").as_bytes());
            raw.extend_from_slice(&header);
            raw.extend_from_slice(data);
            raw.resize(raw.len().div_ceil(512) * 512, 0);
        }
        raw.extend_from_slice(&[0u8; 1024]);
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        gz.write_all(&raw).unwrap();
        gz.finish().unwrap()
    }

    pub fn zip(entries: &[(&str, &[u8])]) -> Vec<u8> {
        let mut out = std::io::Cursor::new(Vec::new());
        let mut writer = zip::ZipWriter::new(&mut out);
        let options = zip::write::SimpleFileOptions::default()
            .compression_method(zip::CompressionMethod::Deflated);
        for (name, data) in entries {
            writer.start_file(*name, options).unwrap();
            writer.write_all(data).unwrap();
        }
        writer.finish().unwrap();
        out.into_inner()
    }
}

#[cfg(test)]
mod tests {
    use super::testing::*;
    use super::*;
    use crate::test_support::TempDir;

    fn run(kind: ArchiveKind, bytes: &[u8], limits: Limits) -> (TempDir, Result<(), ArchiveError>) {
        let dir = TempDir::new();
        let archive = dir.path().join("a");
        fs::write(&archive, bytes).unwrap();
        let result = extract(kind, &archive, &dir.path().join("out"), limits);
        (dir, result)
    }

    #[test]
    fn extracts_and_strips_the_single_top_directory() {
        let bytes = tar_gz(&[
            Entry::Dir("pkg/"),
            Entry::Dir("pkg/bin/"),
            Entry::File("pkg/bin/tool", b"#!x", 0o755),
            Entry::File("pkg/VERSION", b"v", 0o600),
        ]);
        let (dir, result) = run(ArchiveKind::TarGz, &bytes, Limits::default());
        result.unwrap();
        assert_eq!(fs::read(dir.path().join("out/bin/tool")).unwrap(), b"#!x");
        assert_eq!(fs::read(dir.path().join("out/VERSION")).unwrap(), b"v");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(dir.path().join("out/bin/tool"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o755
            );
            assert_eq!(
                fs::metadata(dir.path().join("out/VERSION"))
                    .unwrap()
                    .permissions()
                    .mode()
                    & 0o777,
                0o644
            );
        }
    }
    #[test]
    fn rejects_path_escapes_links_and_multiple_roots_and_cleans_up() {
        let cases: Vec<Vec<Entry>> = vec![
            vec![Entry::File("pkg/../evil", b"x", 0o644)],
            vec![Entry::File("/etc/evil", b"x", 0o644)],
            vec![Entry::File("pkg/a:b", b"x", 0o644)],
            vec![Entry::Dir("pkg/"), Entry::Symlink("pkg/link", "/etc")],
            vec![Entry::Dir("pkg/"), Entry::Hardlink("pkg/h", "pkg/x")],
            vec![
                Entry::File("one/a", b"x", 0o644),
                Entry::File("two/b", b"x", 0o644),
            ],
            vec![Entry::File("flat", b"x", 0o644)],
        ];
        for entries in &cases {
            let (dir, result) = run(ArchiveKind::TarGz, &tar_gz(entries), Limits::default());
            assert!(result.is_err());
            assert!(
                !dir.path().join("out").exists(),
                "partial extraction removed"
            );
            assert!(!dir.path().join("evil").exists());
        }
        let (_, result) = run(ArchiveKind::TarGz, &tar_gz(&[]), Limits::default());
        assert!(matches!(result, Err(ArchiveError::Layout(_))));
        let (_, result) = run(ArchiveKind::TarGz, b"not gzip at all", Limits::default());
        assert!(matches!(
            result,
            Err(ArchiveError::Format(_)) | Err(ArchiveError::Io(_))
        ));
    }
    #[test]
    fn enforces_entry_and_size_limits() {
        let limits = Limits {
            max_entries: 3,
            max_total_bytes: 1000,
            max_file_bytes: 600,
        };
        let many = tar_gz(&[
            Entry::Dir("p/"),
            Entry::File("p/a", b"1", 0o644),
            Entry::File("p/b", b"1", 0o644),
            Entry::File("p/c", b"1", 0o644),
        ]);
        assert!(matches!(
            run(ArchiveKind::TarGz, &many, limits).1,
            Err(ArchiveError::TooManyEntries)
        ));
        let big_file = tar_gz(&[Entry::File("p/a", &[0u8; 700], 0o644)]);
        assert!(matches!(
            run(ArchiveKind::TarGz, &big_file, limits).1,
            Err(ArchiveError::TooLarge)
        ));
        let big_total = tar_gz(&[
            Entry::File("p/a", &[0u8; 500], 0o644),
            Entry::File("p/b", &[0u8; 500], 0o644),
            Entry::File("p/c", &[0u8; 500], 0o644),
        ]);
        let roomy = Limits {
            max_entries: 10,
            ..limits
        };
        assert!(matches!(
            run(ArchiveKind::TarGz, &big_total, roomy).1,
            Err(ArchiveError::TooLarge)
        ));
    }
    #[test]
    fn zip_extracts_and_rejects_escapes() {
        let ok = zip(&[("pkg/bin/tinyprune.exe", b"MZ"), ("pkg/VERSION", b"v")]);
        let (dir, result) = run(ArchiveKind::Zip, &ok, Limits::default());
        result.unwrap();
        assert_eq!(
            fs::read(dir.path().join("out/bin/tinyprune.exe")).unwrap(),
            b"MZ"
        );
        for name in ["pkg/../evil", "/abs", "pkg\\evil", "C:evil"] {
            let (dir, result) = run(ArchiveKind::Zip, &zip(&[(name, b"x")]), Limits::default());
            assert!(result.is_err(), "{name}");
            assert!(!dir.path().join("out").exists());
        }
        let two = zip(&[("a/x", b"1"), ("b/y", b"1")]);
        assert!(matches!(
            run(ArchiveKind::Zip, &two, Limits::default()).1,
            Err(ArchiveError::Layout(_))
        ));
    }
}
