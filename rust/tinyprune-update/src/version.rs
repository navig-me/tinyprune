//! Version and build ordering. The build number is the authoritative monotonic order (ADR 0009/0012);
//! the semantic version is display plus an extra downgrade guard.

use std::cmp::Ordering;
use std::fmt;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Version {
    major: u64,
    minor: u64,
    patch: u64,
    pre: Vec<Ident>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
enum Ident {
    Num(u64),
    Text(String),
}
impl Ord for Ident {
    fn cmp(&self, other: &Self) -> Ordering {
        match (self, other) {
            (Self::Num(a), Self::Num(b)) => a.cmp(b),
            (Self::Num(_), Self::Text(_)) => Ordering::Less,
            (Self::Text(_), Self::Num(_)) => Ordering::Greater,
            (Self::Text(a), Self::Text(b)) => a.cmp(b),
        }
    }
}
impl PartialOrd for Ident {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionError(pub String);
impl fmt::Display for VersionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "invalid version {:?}", self.0)
    }
}
impl std::error::Error for VersionError {}

impl Version {
    /// `MAJOR.MINOR.PATCH[-pre.release][+metadata]`; metadata is ignored for ordering.
    pub fn parse(text: &str) -> Result<Self, VersionError> {
        let err = || VersionError(text.to_owned());
        if text.len() > 64 {
            return Err(err());
        }
        let core = text.split_once('+').map_or(text, |(core, meta)| {
            let _ = meta;
            core
        });
        let (nums, pre) = match core.split_once('-') {
            Some((n, p)) => (n, Some(p)),
            None => (core, None),
        };
        let mut parts = nums.split('.');
        let mut next = || -> Result<u64, VersionError> {
            let part = parts.next().ok_or_else(err)?;
            if part.is_empty()
                || !part.bytes().all(|b| b.is_ascii_digit())
                || (part.len() > 1 && part.starts_with('0'))
            {
                return Err(err());
            }
            part.parse().map_err(|_| err())
        };
        let (major, minor, patch) = (next()?, next()?, next()?);
        if parts.next().is_some() {
            return Err(err());
        }
        let pre = match pre {
            None => vec![],
            Some(p) => p
                .split('.')
                .map(|id| {
                    if id.is_empty() || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
                    {
                        return Err(err());
                    }
                    Ok(if id.bytes().all(|b| b.is_ascii_digit()) {
                        Ident::Num(id.parse().map_err(|_| err())?)
                    } else {
                        Ident::Text(id.to_owned())
                    })
                })
                .collect::<Result<_, _>>()?,
        };
        Ok(Self {
            major,
            minor,
            patch,
            pre,
        })
    }
}
impl Ord for Version {
    fn cmp(&self, other: &Self) -> Ordering {
        (self.major, self.minor, self.patch)
            .cmp(&(other.major, other.minor, other.patch))
            .then_with(|| match (self.pre.is_empty(), other.pre.is_empty()) {
                (true, true) => Ordering::Equal,
                (true, false) => Ordering::Greater,
                (false, true) => Ordering::Less,
                (false, false) => self.pre.cmp(&other.pre),
            })
    }
}
impl PartialOrd for Version {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// Characters allowed in a version string used to name directories. Keeps a hostile (even if signed)
/// manifest from naming a path outside `versions/`.
pub fn is_path_safe(version: &str) -> bool {
    !version.is_empty()
        && version.len() <= 64
        && !version.starts_with('.')
        && version
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'+' | b'_'))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn v(s: &str) -> Version {
        Version::parse(s).unwrap()
    }
    #[test]
    fn orders_numeric_not_lexicographic_and_prereleases_below_release() {
        assert!(v("0.10.0") > v("0.9.9"));
        assert!(v("1.0.0") > v("1.0.0-rc.1"));
        assert!(v("1.0.0-rc.2") > v("1.0.0-rc.1"));
        assert!(v("1.0.0-rc.1") > v("1.0.0-beta"));
        assert_eq!(v("1.0.0+abc").cmp(&v("1.0.0+def")), Ordering::Equal);
    }
    #[test]
    fn rejects_garbage() {
        for bad in [
            "",
            "1",
            "1.2",
            "1.2.3.4",
            "01.2.3",
            "a.b.c",
            "1.2.3-",
            "1.2.3-a..b",
            "../1.2.3",
            &"1.".repeat(40),
        ] {
            assert!(Version::parse(bad).is_err(), "{bad}");
        }
    }
    #[test]
    fn path_safety() {
        assert!(is_path_safe("0.1.0+g1234"));
        for bad in ["", "..", "../x", "a/b", "a\\b", ".hidden", "a b", "a:b"] {
            assert!(!is_path_safe(bad), "{bad}");
        }
    }
}
