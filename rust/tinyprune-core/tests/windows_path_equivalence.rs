//! Differential tests: the optimized Windows-flavor path code (`PathFlavor::Windows`, `WindowsKey`, `AncestorIndex`)
//! must behave exactly like the original allocating implementation, which is kept here verbatim as the reference.
use tinyprune_core::path::{AncestorIndex, ContainerIndex, PathFlavor, WindowsKey};

fn ordinal_upper(c: char) -> char {
    let mut upper = c.to_uppercase();
    let first = upper.next().unwrap_or(c);
    if upper.next().is_none() { first } else { c }
}
fn reference_equal(a: &str, b: &str) -> bool { a.chars().map(ordinal_upper).eq(b.chars().map(ordinal_upper)) }
fn reference_normalize(path: &str) -> String {
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
fn reference_is_descendant(path: &str, root: &str) -> bool {
    let path = reference_normalize(path);
    let root = reference_normalize(root);
    let prefix = format!("{}/", root.trim_end_matches('/'));
    let mut chars = path.chars().map(ordinal_upper);
    prefix.chars().map(ordinal_upper).all(|c| chars.next() == Some(c)) && chars.next().is_some()
}

struct Lcg(u64);
impl Lcg {
    fn next(&mut self, n: usize) -> usize {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        ((self.0 >> 33) as usize) % n
    }
}

const PREFIXES: &[&str] = &["", "", "", "\\\\?\\", "//?/", "\\\\?\\UNC\\", "//?/unc/", "\\\\", "//", "/", "\\", "\\\\?\\\\\\", "\\\\.\\"];
const SEPARATORS: &[&str] = &["\\", "/", "\\\\", "/./", "//", "\\.\\", "/"];
const COMPONENTS: &[&str] = &[
    "C:", "c:", "D:", "Root", "ROOT", "root", "Dir", "dir", "DIR0", "..", ".", "", "é", "É", "e\u{301}", "ß", "SS", "ss", "ς", "σ", "Σ", "ı", "I", "i", "İ",
    "ſ", "K", "\u{212a}", "x.txt", "X.TXT", "UNC", "unc", "?", "server", "SERVER", "share", "Share", "a b", "日本", "ǆ", "ǅ", "Ǆ",
];

fn spelling(rng: &mut Lcg) -> String {
    let mut text = PREFIXES[rng.next(PREFIXES.len())].to_string();
    // Bias toward drive-rooted paths so containment hits are common.
    if rng.next(3) != 0 {
        text.push_str(["C:", "c:", "D:"][rng.next(3)]);
        text.push_str(SEPARATORS[rng.next(SEPARATORS.len())]);
    }
    for index in 0..rng.next(6) {
        if index > 0 { text.push_str(SEPARATORS[rng.next(SEPARATORS.len())]); }
        text.push_str(COMPONENTS[rng.next(COMPONENTS.len())]);
    }
    if rng.next(8) == 0 { text.push_str(SEPARATORS[rng.next(SEPARATORS.len())]); }
    text
}

fn corpus(seed: u64, count: usize) -> Vec<String> {
    let mut rng = Lcg(seed);
    let mut all: Vec<String> = ["", "/", "\\", "C:", "C:\\", "c:/", "//", "//server", "//server/share", r"\\?\C:\a\..\b", r"\\?\UNC\Server\Share\x", "relative\\path", "C:\\Root", "c:/ROOT/dir"].iter().map(|s| s.to_string()).collect();
    while all.len() < count { all.push(spelling(&mut rng)); }
    all
}

#[test]
fn normalize_matches_the_reference_on_varied_spellings() {
    for path in corpus(1, 60_000) {
        assert_eq!(PathFlavor::Windows.normalize(&path), reference_normalize(&path), "{path:?}");
    }
}

#[test]
fn keys_and_pairwise_comparisons_match_the_reference() {
    let paths = corpus(2, 400);
    let keys: Vec<WindowsKey> = paths.iter().map(|p| WindowsKey::new(p)).collect();
    let mut hits = (0usize, 0usize);
    for (a, ka) in paths.iter().zip(&keys) {
        for (b, kb) in paths.iter().zip(&keys) {
            let equal = reference_equal(&reference_normalize(a), &reference_normalize(b));
            assert_eq!(ka == kb, equal, "equal {a:?} {b:?}");
            assert_eq!(PathFlavor::Windows.equal(&PathFlavor::Windows.normalize(a), &PathFlavor::Windows.normalize(b)), equal, "flavor equal {a:?} {b:?}");
            let descendant = reference_is_descendant(a, b);
            assert_eq!(ka.is_descendant_of(kb), descendant, "descendant {a:?} {b:?}");
            assert_eq!(PathFlavor::Windows.is_descendant(a, b), descendant, "flavor descendant {a:?} {b:?}");
            assert_eq!(ka.within(kb), equal || descendant, "within {a:?} {b:?}");
            hits.0 += equal as usize;
            hits.1 += descendant as usize;
        }
    }
    // The corpus must actually exercise both outcomes, otherwise the comparison proves nothing.
    assert!(hits.0 > 200 && hits.1 > 200, "equal {} descendant {}", hits.0, hits.1);
}

#[test]
fn ancestor_index_matches_any_descendant_scan() {
    let paths = corpus(3, 500);
    let mut rng = Lcg(9);
    for round in 0..8 {
        let inserted: Vec<&String> = (0..20 + round * 10).map(|_| &paths[rng.next(paths.len())]).collect();
        let mut index = AncestorIndex::new();
        for path in &inserted { index.insert(&WindowsKey::new(path)); }
        let mut protected = 0;
        for directory in &paths {
            let expected = inserted.iter().any(|path| reference_is_descendant(path, directory));
            assert_eq!(index.has_strict_descendant(&WindowsKey::new(directory)), expected, "{directory:?} over {inserted:?}");
            protected += expected as usize;
        }
        assert!(protected > 0, "round {round} protected nothing");
    }
}

#[test]
fn spellings_of_one_location_share_a_key_and_siblings_do_not() {
    let spellings = [r"C:\Users\Me\Docs\a.txt", "c:/users/me/docs/A.TXT", r"\\?\C:\Users\Me\.\Docs\x\..\a.txt", r"\\?\c:\USERS\ME\DOCS\\a.txt"];
    let keys: Vec<WindowsKey> = spellings.iter().map(|s| WindowsKey::new(s)).collect();
    assert!(keys.windows(2).all(|pair| pair[0] == pair[1]));
    let root = WindowsKey::new(r"C:\USERS\me");
    assert!(keys[0].is_descendant_of(&root) && !root.is_descendant_of(&keys[0]) && !root.is_descendant_of(&root) && root.within(&root));
    assert!(!WindowsKey::new(r"C:\Users\Meow\a").is_descendant_of(&root));
    assert!(WindowsKey::new(r"\\SERVER\Share\x").is_descendant_of(&WindowsKey::new(r"\\?\UNC\server\share")));
    // Expanding case folds stay unexpanded: ß is not SS.
    assert_ne!(WindowsKey::new("C:/ß"), WindowsKey::new("C:/SS"));
    assert_eq!(PathFlavor::default(), PathFlavor::Posix);
}

#[test]
fn container_index_matches_pairwise_within_in_order() {
    let paths = corpus(4, 500);
    let mut rng = Lcg(77);
    let mut found = 0;
    let mut scratch = Vec::new();
    for round in 0..8 {
        let entries: Vec<&String> = (0..10 + round * 12).map(|_| &paths[rng.next(paths.len())]).collect();
        let index = ContainerIndex::new(entries.iter().map(|p| WindowsKey::new(p)));
        assert_eq!(index.len(), entries.len());
        for path in &paths {
            index.containing(&WindowsKey::new(path), &mut scratch);
            let expected: Vec<usize> = (0..entries.len())
                .filter(|&i| {
                    let (a, b) = (reference_normalize(path), reference_normalize(entries[i]));
                    reference_equal(&a, &b) || reference_is_descendant(path, entries[i])
                })
                .collect();
            assert_eq!(scratch, expected, "{path:?}");
            found += expected.len();
        }
    }
    assert!(found > 150, "{found}");
}

#[test]
fn from_normalized_folds_without_renormalizing() {
    let normalized = PathFlavor::Windows.normalize(r"c:\Data\x");
    assert_eq!(WindowsKey::from_normalized(&normalized), WindowsKey::new(r"C:\DATA\X"));
    // "C:" is a parent spelling that normalization would turn into the root "C:/"; it must stay distinct.
    assert_ne!(WindowsKey::from_normalized("C:"), WindowsKey::new("C:"));
}
