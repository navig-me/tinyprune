//! Lexical platform paths. Windows uses ordinal, single-scalar uppercase comparison, not NFC or full case folding.
use crate::swiftstr::{canonical_eq, has_prefix};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum PathFlavor {
    #[default]
    Posix,
    Windows,
}

// Like ordinal ignore-case, expansions (for example ß -> SS) are deliberately not performed.
fn ordinal_upper(c: char) -> char {
    let mut upper = c.to_uppercase();
    let first = upper.next().unwrap_or(c);
    if upper.next().is_none() { first } else { c }
}

impl PathFlavor {
    pub fn fold(self, text: &str) -> String {
        match self { Self::Posix => text.into(), Self::Windows => text.chars().map(ordinal_upper).collect() }
    }

    pub fn equal(self, a: &str, b: &str) -> bool {
        match self {
            Self::Posix => canonical_eq(a, b),
            Self::Windows => a.chars().map(ordinal_upper).eq(b.chars().map(ordinal_upper)),
        }
    }

    pub fn normalize(self, path: &str) -> String {
        if self == Self::Posix { return crate::rule::normalize_path(path); }
        let replaced = path.replace('\\', "/");
        let plain = if replaced.get(..8).is_some_and(|p| p.eq_ignore_ascii_case("//?/UNC/")) {
            format!("//{}", &replaced[8..])
        } else { replaced.strip_prefix("//?/").unwrap_or(&replaced).into() };
        let (root, tail) = if let Some(unc) = plain.strip_prefix("//") {
            let mut parts = unc.split('/').filter(|part| !part.is_empty());
            let server = parts.next().unwrap_or("");
            let share = parts.next().unwrap_or("");
            (format!("//{server}/{share}"), parts.collect::<Vec<_>>().join("/"))
        } else if plain.as_bytes().get(1) == Some(&b':') {
            (format!("{}/", &plain[..2]), plain[2..].trim_start_matches('/').into())
        } else { return plain; };
        let mut parts = Vec::new();
        for part in tail.split('/') {
            match part { "" | "." => {}, ".." => { parts.pop(); }, _ => parts.push(part) }
        }
        if parts.is_empty() { root } else { format!("{}/{}", root.trim_end_matches('/'), parts.join("/")) }
    }

    pub fn is_absolute(self, path: &str) -> bool {
        if self == Self::Posix { return path.starts_with('/'); }
        let p = path.replace('\\', "/");
        let p = if p.get(..8).is_some_and(|s| s.eq_ignore_ascii_case("//?/UNC/")) { format!("//{}", &p[8..]) }
            else { p.strip_prefix("//?/").unwrap_or(&p).into() };
        if p.starts_with("//") {
            let parts: Vec<_> = p.trim_start_matches('/').split('/').take(2).collect();
            return parts.len() == 2 && parts.iter().all(|part| !part.is_empty() && !matches!(*part, "." | ".." | "?") && !part.contains(':'));
        }
        p.as_bytes().first().is_some_and(u8::is_ascii_alphabetic) && p.as_bytes().get(1..3) == Some(b":/")
    }

    pub fn is_root(self, path: &str) -> bool {
        let p = self.normalize(path);
        match self { Self::Posix => p == "/", Self::Windows => p.ends_with(":/") || (p.starts_with("//") && p[2..].split('/').count() == 2) }
    }

    /// Strict descendant comparison, including the component boundary.
    pub fn is_descendant(self, path: &str, root: &str) -> bool {
        let path = self.normalize(path);
        let root = self.normalize(root);
        let prefix = format!("{}/", root.trim_end_matches('/'));
        match self {
            Self::Posix => has_prefix(&path, &prefix),
            Self::Windows => {
                let mut chars = path.chars().map(ordinal_upper);
                prefix.chars().map(ordinal_upper).all(|c| chars.next() == Some(c)) && chars.next().is_some()
            }
        }
    }
}
