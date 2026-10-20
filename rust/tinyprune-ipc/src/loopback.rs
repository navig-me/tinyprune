//! Bounded duplex in-memory byte stream, exercising the actual framing and handshake.
use std::io::{self, Read, Write};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
pub struct Loopback {
    send: SyncSender<Vec<u8>>,
    receive: Receiver<Vec<u8>>,
    current: std::io::Cursor<Vec<u8>>,
}
pub fn pair() -> (Loopback, Loopback) {
    let (a, ar) = sync_channel(1);
    let (b, br) = sync_channel(1);
    (
        Loopback {
            send: a,
            receive: br,
            current: std::io::Cursor::new(Vec::new()),
        },
        Loopback {
            send: b,
            receive: ar,
            current: std::io::Cursor::new(Vec::new()),
        },
    )
}
impl Read for Loopback {
    fn read(&mut self, bytes: &mut [u8]) -> io::Result<usize> {
        if bytes.is_empty() {
            return Ok(0);
        }
        loop {
            let n = self.current.read(bytes)?;
            if n > 0 {
                return Ok(n);
            }
            match self.receive.recv() {
                Ok(chunk) => self.current = std::io::Cursor::new(chunk),
                Err(_) => return Ok(0),
            }
        }
    }
}
impl Write for Loopback {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let n = bytes.len().min(4096);
        if n == 0 {
            return Ok(0);
        }
        self.send
            .send(bytes[..n].to_vec())
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "loopback closed"))?;
        Ok(n)
    }
    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}
