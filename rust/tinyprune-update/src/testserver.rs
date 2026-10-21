//! Static loopback HTTP server for the end-to-end tests (feature `test-overrides` only; never part of a
//! released artifact). It lets the Windows end-to-end run without Python or any extra tool: it serves
//! files below one directory, `GET` only, bound to 127.0.0.1, one short-lived connection per request.

use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::Arc;

fn respond(stream: &mut TcpStream, status: &str, body: &[u8]) {
    let head = format!(
        "HTTP/1.1 {status}\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        body.len()
    );
    let _ = stream.write_all(head.as_bytes());
    let _ = stream.write_all(body);
}

/// Maps a request target to a file below `root`; anything that is not a plain relative path is refused.
fn resolve(root: &Path, target: &str) -> Option<PathBuf> {
    let rest = target.strip_prefix('/')?;
    if rest.is_empty()
        || rest.contains(['\\', ':', '?', '#', '%', '\0'])
        || rest
            .split('/')
            .any(|p| p.is_empty() || p == "." || p == "..")
    {
        return None;
    }
    Some(rest.split('/').fold(root.to_owned(), |p, c| p.join(c)))
}

fn handle(mut stream: TcpStream, root: &Path) {
    let mut head = Vec::new();
    let mut buf = [0u8; 1024];
    while !head.windows(4).any(|w| w == b"\r\n\r\n") && head.len() < 8192 {
        match stream.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => head.extend_from_slice(&buf[..n]),
        }
    }
    let text = String::from_utf8_lossy(&head);
    let mut line = text.lines().next().unwrap_or_default().split(' ');
    let (method, target) = (
        line.next().unwrap_or_default(),
        line.next().unwrap_or_default(),
    );
    if method != "GET" {
        return respond(&mut stream, "405 Method Not Allowed", b"");
    }
    match resolve(root, target).map(std::fs::read) {
        Some(Ok(bytes)) => respond(&mut stream, "200 OK", &bytes),
        _ => respond(&mut stream, "404 Not Found", b""),
    }
}

/// Serve `root` on `listener` until the process ends.
pub fn serve(root: PathBuf, listener: TcpListener) {
    let root = Arc::new(root);
    for stream in listener.incoming().flatten() {
        let root = Arc::clone(&root);
        std::thread::spawn(move || handle(stream, &root));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::TempDir;

    fn get(port: u16, request: &str) -> (String, Vec<u8>) {
        let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
        stream.write_all(request.as_bytes()).unwrap();
        let mut raw = Vec::new();
        stream.read_to_end(&mut raw).unwrap();
        let split = raw.windows(4).position(|w| w == b"\r\n\r\n").unwrap() + 4;
        (
            String::from_utf8_lossy(&raw[..split])
                .lines()
                .next()
                .unwrap()
                .to_owned(),
            raw[split..].to_vec(),
        )
    }

    #[test]
    fn serves_files_below_the_root_only() {
        let dir = TempDir::new();
        std::fs::create_dir_all(dir.path().join("good")).unwrap();
        std::fs::write(dir.path().join("good/feed.json"), b"hello").unwrap();
        std::fs::write(
            dir.path().parent().unwrap().join("tp-outside.txt"),
            b"secret",
        )
        .ok();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let root = dir.path().to_owned();
        std::thread::spawn(move || serve(root, listener));

        let (status, body) = get(port, "GET /good/feed.json HTTP/1.1\r\nHost: x\r\n\r\n");
        assert_eq!(
            (status.as_str(), body.as_slice()),
            ("HTTP/1.1 200 OK", &b"hello"[..])
        );
        for target in [
            "/good/missing",
            "/",
            "/../tp-outside.txt",
            "/good/../good/feed.json",
            "/good\\feed.json",
            "/good/feed.json?x=1",
        ] {
            let (status, body) = get(port, &format!("GET {target} HTTP/1.1\r\n\r\n"));
            assert_eq!(status, "HTTP/1.1 404 Not Found", "{target}");
            assert!(body.is_empty());
        }
        let (status, _) = get(port, "POST /good/feed.json HTTP/1.1\r\n\r\n");
        assert_eq!(status, "HTTP/1.1 405 Method Not Allowed");
        let _ = std::fs::remove_file(dir.path().parent().unwrap().join("tp-outside.txt"));
    }
}
