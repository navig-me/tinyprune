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
    if c.is_ascii() { return c.to_ascii_uppercase(); }
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
        windows_normalize(path)
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
        match self {
            Self::Posix => {
                let path = self.normalize(path);
                let root = self.normalize(root);
                has_prefix(&path, &format!("{}/", root.trim_end_matches('/')))
            }
            Self::Windows => WindowsKey::new(path).is_descendant_of(&WindowsKey::new(root)),
        }
    }
}

/// Windows comparison key: the lexically normalized path with ordinal single-scalar uppercase applied once.
///
/// Two paths are equal under `PathFlavor::Windows.equal(normalize(a), normalize(b))` exactly when their keys are
/// equal, and `is_descendant_of` is identical to `PathFlavor::Windows.is_descendant`. Hot loops compute a key once per
/// path and then compare without allocating, instead of re-normalizing both operands for every pair.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct WindowsKey(String);

impl WindowsKey {
    pub fn new(path: &str) -> Self {
        let mut key = windows_normalize(path);
        if key.is_ascii() { key.make_ascii_uppercase(); } else { key = key.chars().map(ordinal_upper).collect(); }
        Self(key)
    }

    pub fn as_str(&self) -> &str { &self.0 }

    /// Folds an already normalized path (the output of `PathFlavor::normalize`) without normalizing it again.
    pub fn from_normalized(normalized: &str) -> Self {
        let mut key = normalized.to_owned();
        if key.is_ascii() { key.make_ascii_uppercase(); } else { key = key.chars().map(ordinal_upper).collect(); }
        Self(key)
    }

    /// Strictly below `root` on a component boundary.
    pub fn is_descendant_of(&self, root: &WindowsKey) -> bool {
        let root = root.0.trim_end_matches('/');
        self.0.len() > root.len() + 1 && self.0.as_bytes()[root.len()] == b'/' && self.0.starts_with(root)
    }

    /// Equal to `root` or strictly below it.
    pub fn within(&self, root: &WindowsKey) -> bool { self == root || self.is_descendant_of(root) }
}

/// Answers "does any inserted path lie strictly below this directory?" in time proportional to the directory's
/// depth, by recording every strict ancestor of each inserted path. Replaces an `any(is_descendant)` scan per directory.
#[derive(Default, Debug)]
pub struct AncestorIndex(std::collections::HashSet<String>);

impl AncestorIndex {
    pub fn new() -> Self { Self::default() }

    pub fn insert(&mut self, path: &WindowsKey) {
        let key = path.0.as_str();
        let mut end = key.len();
        // Every shorter ancestor was inserted together with a longer one, so stop at the first known prefix.
        while let Some(slash) = key[..end].rfind('/') {
            end = slash;
            if slash + 1 >= key.len() { continue; }
            if self.0.contains(&key[..slash]) { break; }
            self.0.insert(key[..slash].to_owned());
        }
    }

    /// True when an inserted path is a strict descendant of `directory` (`WindowsKey::is_descendant_of`).
    pub fn has_strict_descendant(&self, directory: &WindowsKey) -> bool {
        self.0.contains(directory.0.trim_end_matches('/'))
    }
}

/// For a path, finds every indexed entry whose own path contains it (equal to it or a strict ancestor), in time
/// proportional to the path's depth instead of the number of entries. Entries are numbered in insertion order.
#[derive(Default, Debug)]
pub struct ContainerIndex {
    equal: std::collections::HashMap<String, Vec<usize>>,
    /// Entries by key without trailing slashes, the form a strict-descendant test compares against.
    ancestors: std::collections::HashMap<String, Vec<usize>>,
    len: usize,
}

impl ContainerIndex {
    pub fn new(keys: impl IntoIterator<Item = WindowsKey>) -> Self {
        let mut index = Self::default();
        for key in keys {
            let entry = index.len;
            index.len += 1;
            index.ancestors.entry(key.0.trim_end_matches('/').to_owned()).or_default().push(entry);
            index.equal.entry(key.0).or_default().push(entry);
        }
        index
    }

    pub fn len(&self) -> usize { self.len }

    pub fn is_empty(&self) -> bool { self.len == 0 }

    /// Appends, in ascending order, the entries `e` with `path.within(key_e)` to `out` (cleared first).
    pub fn containing(&self, path: &WindowsKey, out: &mut Vec<usize>) {
        out.clear();
        let key = path.0.as_str();
        if let Some(found) = self.equal.get(key) { out.extend_from_slice(found); }
        let mut end = key.len();
        while let Some(slash) = key[..end].rfind('/') {
            end = slash;
            if slash + 1 < key.len() {
                if let Some(found) = self.ancestors.get(&key[..slash]) { out.extend_from_slice(found); }
            }
        }
        out.sort_unstable();
        // A key with trailing slashes can be both equal to the path and a strict ancestor of itself.
        out.dedup();
    }
}

fn windows_normalize(path: &str) -> String {
    let replaced: String = path.chars().map(|c| if c == '\\' { '/' } else { c }).collect();
    // `unc` is the text after the leading "//" when the prefix-stripped path is a UNC path.
    let (plain, unc) = if replaced.get(..8).is_some_and(|p| p.eq_ignore_ascii_case("//?/UNC/")) {
        (replaced.as_str(), Some(&replaced[8..]))
    } else {
        let plain = replaced.strip_prefix("//?/").unwrap_or(&replaced);
        (plain, plain.strip_prefix("//"))
    };
    if let Some(unc) = unc {
        let mut parts = unc.split('/').filter(|part| !part.is_empty());
        let server = parts.next().unwrap_or("");
        let share = parts.next().unwrap_or("");
        let mut root = String::with_capacity(unc.len() + 3);
        root.push_str("//");
        root.push_str(server);
        root.push('/');
        root.push_str(share);
        collapse(root, parts)
    } else if plain.as_bytes().get(1) == Some(&b':') {
        let mut root = String::with_capacity(plain.len() + 1);
        root.push_str(&plain[..2]);
        root.push('/');
        collapse(root, plain[2..].trim_start_matches('/').split('/'))
    } else {
        plain.to_owned()
    }
}

/// Appends `parts` to `root` with `.`/empty components dropped and `..` popping the previous component.
fn collapse<'a>(mut root: String, parts: impl Iterator<Item = &'a str>) -> String {
    let mut stack: Vec<&str> = Vec::new();
    for part in parts {
        match part { "" | "." => {}, ".." => { stack.pop(); }, _ => stack.push(part) }
    }
    if stack.is_empty() { return root; }
    root.truncate(root.trim_end_matches('/').len());
    for part in stack {
        root.push('/');
        root.push_str(part);
    }
    root
}
