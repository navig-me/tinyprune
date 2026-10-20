//! Path safety with injected canonical resolution and home directories; never consults the host filesystem.
use crate::rule::{normalize_path, ExpiryBasis, LifetimeRule, RuleMatchMode, PathFlavor};
use crate::swiftstr::{canonical_eq, is_blank};

pub trait PathResolver {
    /// Resolve the deepest existing ancestor and append nonexistent tail components.
    fn canonical_path(&self, path: &str) -> String;
    fn home_directories(&self) -> &[String];
}

fn forms(path: &str, resolver: &impl PathResolver) -> [String; 2] {
    [normalize_path(path).to_lowercase(), resolver.canonical_path(path).to_lowercase()]
}

pub fn is_very_broad(path: &str, resolver: &impl PathResolver) -> bool {
    if !path.starts_with('/') { return false; }
    forms(path, resolver).iter().any(|path| {
        if matches!(path.as_str(), "/" | "/users" | "/volumes" | "/private" | "/private/var" | "/private/etc" | "/applications" | "/system" | "/library" | "/usr" | "/bin" | "/sbin" | "/etc" | "/var" | "/opt" | "/cores" | "/dev") { return true; }
        let parts: Vec<_> = path.split('/').filter(|part| !part.is_empty()).collect();
        if parts.len() == 2 && matches!(parts[0], "users" | "volumes") { return true; }
        if parts.len() == 3 && parts[0] == "users" && parts[2] == "library" { return true; }
        resolver.home_directories().iter().any(|home| {
            forms(home, resolver).iter().any(|home| home != "/" && (canonical_eq(path, home) || canonical_eq(path, &format!("{home}/library"))))
        })
    })
}

pub fn is_broad(rule: &LifetimeRule, resolver: &impl PathResolver) -> bool {
    if is_very_broad(&rule.scope.path, resolver) { return true; }
    let recursive = match rule.match_mode { RuleMatchMode::Scoped => rule.scope.recursive, RuleMatchMode::Template => true, _ => false };
    recursive && ((rule.matcher.exact_names.is_empty() && rule.matcher.glob_patterns.is_empty()) || rule.expiry_basis == ExpiryBasis::ProjectActivity)
}

pub fn validate_root(name: &str, path: &str, bookmark: &[u8], resolver: &impl PathResolver) -> Result<(), &'static str> {
    if is_blank(name) { return Err("emptyName"); }
    if !path.starts_with('/') || path == "/" || !canonical_eq(path, &normalize_path(path)) { return Err("invalidPath"); }
    const PROTECTED: &[&str] = &["/applications", "/system", "/library", "/bin", "/sbin", "/usr", "/etc", "/var", "/private/etc", "/private/var/db", "/dev", "/cores"];
    if forms(path, resolver).iter().any(|path| path.ends_with("/library") || PROTECTED.iter().any(|root| path == root || path.starts_with(&format!("{root}/")))) { return Err("dangerousPath"); }
    if bookmark.is_empty() { return Err("emptyBookmark"); }
    Ok(())
}

/// Platform-specific root validation. POSIX retains the Swift-reference contract.
pub fn validate_root_with_flavor(name: &str, path: &str, bookmark: &[u8], resolver: &impl PathResolver, flavor: PathFlavor) -> Result<(), &'static str> {
    if flavor == PathFlavor::Posix { return validate_root(name, path, bookmark, resolver); }
    if is_blank(name) { return Err("emptyName"); }
    if !flavor.is_absolute(path) || path.contains('\0') { return Err("invalidPath"); }
    let forms = [flavor.normalize(path), flavor.normalize(&resolver.canonical_path(path))];
    for form in &forms {
        if !flavor.is_absolute(form) { return Err("invalidPath"); }
        if form.split('/').enumerate().any(|(index, part)| part.ends_with('.') || part.ends_with(' ') || (part.contains(':') && index != 0)) { return Err("invalidPath"); }
        if flavor.is_root(form) { return Err("dangerousPath"); }
        // Reject system trees on every drive, including their resolved aliases.
        if let Some((drive, _)) = form.split_once(':') {
            for suffix in ["Windows", "Program Files", "Program Files (x86)", "ProgramData"] {
                let root = format!("{drive}:/{suffix}");
                if flavor.equal(form, &root) || flavor.is_descendant(form, &root) { return Err("dangerousPath"); }
            }
        }
        if resolver.home_directories().iter().any(|home| {
            [flavor.normalize(home), flavor.normalize(&resolver.canonical_path(home))].iter().any(|home| flavor.equal(form, home))
        }) { return Err("dangerousPath"); }
    }
    if bookmark.is_empty() { return Err("emptyBookmark"); }
    Ok(())
}
