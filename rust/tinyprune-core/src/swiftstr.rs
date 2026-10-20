//! Swift `String` semantics the reference implementation relies on.
//!
//! Swift compares strings by canonical equivalence (NFC), orders them by NFC scalar order, counts
//! `Character`s as extended grapheme clusters, and tests prefixes cluster by cluster. Rust's `str` does none
//! of that, so every comparison that the Swift domain code performs on user-visible strings goes through here.

use std::cmp::Ordering;
use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

pub fn nfc(s: &str) -> String {
    s.nfc().collect()
}

/// Swift `String ==`.
pub fn canonical_eq(a: &str, b: &str) -> bool {
    a == b || nfc(a) == nfc(b)
}

/// Swift `String <`, `<=>`: NFC scalar order (equal to NFC UTF-8 byte order).
pub fn swift_cmp(a: &str, b: &str) -> Ordering {
    nfc(a).cmp(&nfc(b))
}

/// Swift `String.count`.
pub fn char_count(s: &str) -> usize {
    s.graphemes(true).count()
}

/// Swift `String.hasPrefix`: compares `Character`s with canonical equivalence.
pub fn has_prefix(s: &str, prefix: &str) -> bool {
    let mut subject = s.graphemes(true);
    prefix.graphemes(true).all(|expected| subject.next().is_some_and(|actual| canonical_eq(actual, expected)))
}

/// Swift `String.dropFirst(n)` (by `Character`).
pub fn drop_first(s: &str, n: usize) -> String {
    s.graphemes(true).skip(n).collect()
}

/// Swift `split(separator: "/")` with the default `omittingEmptySubsequences: true`.
pub fn split_slash(s: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut current = String::new();
    for cluster in s.graphemes(true) {
        if cluster == "/" {
            if !current.is_empty() {
                parts.push(std::mem::take(&mut current));
            }
        } else {
            current.push_str(cluster);
        }
    }
    if !current.is_empty() {
        parts.push(current);
    }
    parts
}

/// `Character("/")` membership (a `/` followed by a combining mark is a different `Character`).
pub fn contains_slash(s: &str) -> bool {
    s.graphemes(true).any(|cluster| cluster == "/")
}

/// `trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`.
pub fn is_blank(s: &str) -> bool {
    s.chars().all(char::is_whitespace)
}

/// Removes canonical duplicates, keeping the first spelling (matches `Set<String>` insertion).
pub fn dedup_canonical(values: &[String]) -> Vec<String> {
    let mut seen: Vec<String> = Vec::new();
    let mut result = Vec::new();
    for value in values {
        let normalized = nfc(value);
        if !seen.contains(&normalized) {
            seen.push(normalized);
            result.push(value.clone());
        }
    }
    result
}
