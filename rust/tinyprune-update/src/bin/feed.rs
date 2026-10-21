//! `tinyprune-feed`: build and verify the signed update feed (release tooling; runs in CI).
//!
//! ```text
//! tinyprune-feed generate --out feed.json [--existing old.json] --version V --build N --base-url https://…/ \
//!     [--notes-url URL] [--published ISO8601] --artifact linux-x86_64=path.tar.gz [--artifact windows-x86_64=path.zip]
//! tinyprune-feed verify --feed feed.json --sig feed.json.sig --public-key BASE64 [--artifact-dir DIR]
//! ```
//! Signing is NOT done here in production: the workflow signs `feed.json` with Sparkle's `sign_update`
//! and the ADR 0009 private key (stdin), then runs `verify` with the public key. The `test-keygen` and
//! `test-sign` subcommands exist only when built with `--features test-overrides`, for the throwaway key
//! of the end-to-end test.

use std::collections::BTreeMap;
use std::process::exit;
use tinyprune_update::crypto::{sha256_hex, PublicKey};
use tinyprune_update::manifest::{
    verify_and_parse, Artifact, Feed, Release, FORMAT, MAX_ARTIFACT_BYTES,
};
use tinyprune_update::transport::is_acceptable_url;

fn die(message: impl AsRef<str>) -> ! {
    eprintln!("tinyprune-feed: {}", message.as_ref());
    exit(1);
}

struct Opts(Vec<(String, String)>);
impl Opts {
    fn parse(args: &[String]) -> Self {
        let mut pairs = vec![];
        let mut it = args.iter();
        while let Some(flag) = it.next() {
            let Some(name) = flag.strip_prefix("--") else {
                die(format!("unexpected argument {flag:?}"))
            };
            pairs.push((
                name.to_owned(),
                it.next()
                    .unwrap_or_else(|| die(format!("--{name} needs a value")))
                    .clone(),
            ));
        }
        Self(pairs)
    }
    fn one(&self, name: &str) -> Option<&str> {
        self.0
            .iter()
            .rev()
            .find(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
    }
    fn need(&self, name: &str) -> &str {
        self.one(name)
            .unwrap_or_else(|| die(format!("--{name} is required")))
    }
    fn all(&self, name: &str) -> Vec<&str> {
        self.0
            .iter()
            .filter(|(k, _)| k == name)
            .map(|(_, v)| v.as_str())
            .collect()
    }
}

fn generate(o: &Opts) {
    let version = o.need("version").to_owned();
    let build: u64 = o
        .need("build")
        .parse()
        .unwrap_or_else(|_| die("--build must be a number"));
    let base = o.need("base-url");
    if !is_acceptable_url(base) || !base.ends_with('/') {
        die("--base-url must be an https URL ending in '/'");
    }
    let mut artifacts = BTreeMap::new();
    for spec in o.all("artifact") {
        let (platform, path) = spec
            .split_once('=')
            .unwrap_or_else(|| die("--artifact is PLATFORM=PATH"));
        let bytes = std::fs::read(path).unwrap_or_else(|e| die(format!("{path}: {e}")));
        if bytes.is_empty() || bytes.len() as u64 > MAX_ARTIFACT_BYTES {
            die(format!(
                "{path}: size {} is outside 1..={MAX_ARTIFACT_BYTES}",
                bytes.len()
            ));
        }
        let file = std::path::Path::new(path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or_else(|| die("bad artifact path"));
        // Only characters that need no URL escaping, so the URL is exactly base + name.
        if !file
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_' | b'+'))
        {
            die(format!("{file}: unsupported characters in file name"));
        }
        artifacts.insert(
            platform.to_owned(),
            Artifact {
                url: format!("{base}{file}"),
                sha256: sha256_hex(&bytes),
                size: bytes.len() as u64,
            },
        );
    }
    if artifacts.is_empty() {
        die("at least one --artifact is required");
    }
    let mut releases = match o.one("existing") {
        Some(path) => {
            let existing: Feed = serde_json::from_slice(
                &std::fs::read(path).unwrap_or_else(|e| die(format!("{path}: {e}"))),
            )
            .unwrap_or_else(|e| die(format!("{path}: {e}")));
            if existing.format != FORMAT {
                die("existing feed has a different format");
            }
            existing.releases
        }
        None => vec![],
    };
    // Monotonic build numbers: a new entry must exceed everything already published.
    if let Some(max) = releases.iter().map(|r| r.build).max() {
        if build <= max {
            die(format!(
                "build {build} is not greater than the newest published build {max}"
            ));
        }
    }
    releases.push(Release {
        version,
        build,
        notes_url: o.one("notes-url").map(str::to_owned),
        published: o.one("published").map(str::to_owned),
        artifacts,
    });
    let feed = Feed {
        format: FORMAT.into(),
        generated: o.one("published").map(str::to_owned),
        releases,
    };
    let mut bytes = serde_json::to_vec_pretty(&feed).unwrap_or_else(|e| die(e.to_string()));
    bytes.push(b'\n');
    std::fs::write(o.need("out"), bytes).unwrap_or_else(|e| die(e.to_string()));
}

fn verify(o: &Opts) {
    let feed_bytes = std::fs::read(o.need("feed")).unwrap_or_else(|e| die(format!("feed: {e}")));
    let sig = std::fs::read_to_string(o.need("sig")).unwrap_or_else(|e| die(format!("sig: {e}")));
    let key = PublicKey::from_base64(o.need("public-key")).unwrap_or_else(|e| die(e.to_string()));
    let feed = verify_and_parse(&feed_bytes, &sig, &key).unwrap_or_else(|e| die(e.to_string()));
    if let Some(dir) = o.one("artifact-dir") {
        for release in &feed.releases {
            for (platform, artifact) in &release.artifacts {
                let name = artifact.url.rsplit('/').next().unwrap_or_default();
                let path = std::path::Path::new(dir).join(name);
                // Older releases are not re-downloaded for every run; verify what is present.
                if let Ok(bytes) = std::fs::read(&path) {
                    if sha256_hex(&bytes) != artifact.sha256 || bytes.len() as u64 != artifact.size
                    {
                        die(format!(
                            "{} ({platform}, build {}) does not match the signed feed",
                            path.display(),
                            release.build
                        ));
                    }
                    println!("ok {name}");
                }
            }
        }
    }
    println!(
        "feed ok: {} release(s), newest build {}",
        feed.releases.len(),
        feed.releases.iter().map(|r| r.build).max().unwrap_or(0)
    );
}

#[cfg(feature = "test-overrides")]
fn test_keygen(o: &Opts) {
    use std::io::Write;
    use tinyprune_update::crypto::testing::TestKey;
    let seed = TestKey::random_seed();
    std::fs::write(o.need("seed-file"), seed).unwrap_or_else(|e| die(e.to_string()));
    let public = TestKey::from_seed(seed).public();
    std::io::stdout()
        .write_all(public.to_base64().as_bytes())
        .unwrap();
    println!();
}
#[cfg(feature = "test-overrides")]
fn test_sign(o: &Opts) {
    use tinyprune_update::crypto::testing::TestKey;
    let seed: [u8; 32] = std::fs::read(o.need("seed-file"))
        .unwrap_or_else(|e| die(e.to_string()))
        .try_into()
        .unwrap_or_else(|_| die("seed file must be 32 bytes"));
    let message = std::fs::read(o.need("file")).unwrap_or_else(|e| die(e.to_string()));
    println!("{}", TestKey::from_seed(seed).sign_b64(&message));
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let Some((command, rest)) = args.split_first() else {
        die("usage: tinyprune-feed generate|verify ...")
    };
    let opts = Opts::parse(rest);
    match command.as_str() {
        "generate" => generate(&opts),
        "verify" => verify(&opts),
        #[cfg(feature = "test-overrides")]
        "test-keygen" => test_keygen(&opts),
        #[cfg(feature = "test-overrides")]
        "test-sign" => test_sign(&opts),
        other => die(format!("unknown command {other:?}")),
    }
}
