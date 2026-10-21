use crate::RawKind;
use std::io;

/// Decode one FILE_NOTIFY_INFORMATION record without alignment assumptions.
/// The returned offset is relative to this record; zero ends the completion.
pub(crate) fn record(bytes: &[u8]) -> io::Result<(u32, Vec<u16>, usize)> {
    let invalid = || {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "malformed directory notification",
        )
    };
    let header = bytes.get(..12).ok_or_else(invalid)?;
    let word = |at| u32::from_le_bytes(header[at..at + 4].try_into().unwrap());
    let next = word(0) as usize;
    let action = word(4);
    let length = word(8) as usize;
    let end = 12usize.checked_add(length).ok_or_else(invalid)?;
    if !(1..=5).contains(&action)
        || length == 0
        || !length.is_multiple_of(2)
        || (next != 0 && (!next.is_multiple_of(4) || next < end || next >= bytes.len()))
    {
        return Err(invalid());
    }
    let name: Vec<u16> = bytes
        .get(12..end)
        .ok_or_else(invalid)?
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| u16::from_le_bytes(*pair))
        .collect();
    // Notifications must be relative child paths, never escape the managed root.
    if name.contains(&0)
        || name.contains(&58)
        || matches!(name.first(), Some(47 | 92))
        || name
            .split(|unit| matches!(unit, 47 | 92))
            .any(|part| part.is_empty() || part == [46] || part == [46, 46])
    {
        return Err(invalid());
    }
    Ok((action, name, next))
}

/// Windows supplies adjacent old/new names rather than a kernel rename cookie.
#[derive(Default)]
pub(crate) struct RenamePairing {
    next: u32,
    pending: Option<u32>,
}

impl RenamePairing {
    pub(crate) fn kind(&mut self, action: u32) -> RawKind {
        let old = self.pending.take();
        match action {
            1 => RawKind::Created,
            2 => RawKind::Removed,
            3 => RawKind::Modified,
            4 => {
                self.next = self.next.wrapping_add(1).max(1);
                self.pending = Some(self.next);
                RawKind::RenameFrom(self.next)
            }
            5 => RawKind::RenameTo(old.unwrap_or(0)),
            _ => unreachable!("parser validates actions"),
        }
    }

    pub(crate) fn reset(&mut self) {
        self.pending = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Coalescer, EventKind, RawEvent};
    use std::path::PathBuf;

    pub(super) fn notification(action: u32, name: &[u16], next: u32) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.extend(next.to_le_bytes());
        bytes.extend(action.to_le_bytes());
        bytes.extend((name.len() as u32 * 2).to_le_bytes());
        for unit in name {
            bytes.extend(unit.to_le_bytes());
        }
        bytes
    }

    #[test]
    fn bounds_alignment_and_native_utf16() {
        let name = [97, 92, 0xd800]; // Preserve an unpaired surrogate, not lossy UTF-8.
        let bytes = notification(1, &name, 0);
        let mut unaligned = vec![0];
        unaligned.extend(&bytes);
        assert_eq!(record(&unaligned[1..]).unwrap(), (1, name.to_vec(), 0));
        for end in 0..bytes.len() {
            assert!(record(&bytes[..end]).is_err());
        }
        for next in [1, 12, 16, 100, u32::MAX] {
            assert!(record(&notification(1, &name, next)).is_err());
        }
        for name in [
            vec![],
            vec![0],
            vec![92, 97],
            vec![46, 46, 92, 97],
            vec![67, 58, 97],
        ] {
            assert!(record(&notification(1, &name, 0)).is_err());
        }
        assert!(record(&notification(6, &[97], 0)).is_err());
        let mut odd = bytes;
        odd[8] = 3;
        assert!(record(&odd).is_err());
    }

    #[test]
    fn chained_records_and_truncated_next_header() {
        let mut bytes = notification(4, &[97, 98], 16);
        bytes.extend(notification(5, &[99], 0));
        let (_, _, next) = record(&bytes).unwrap();
        assert_eq!(record(&bytes[next..]).unwrap().0, 5);
        bytes.truncate(17);
        assert!(record(&bytes[16..]).is_err());
    }

    #[test]
    fn pairing_survives_bounded_polls_and_resets_on_loss() {
        let mut pairing = RenamePairing::default();
        let mut coalescer = Coalescer::default();
        let mut push = |action, path: &str, pairing: &mut RenamePairing| {
            coalescer.push(RawEvent {
                root: PathBuf::from("root"),
                path: PathBuf::from(path),
                kind: pairing.kind(action),
                is_directory: false,
            });
        };
        push(4, "old", &mut pairing);
        push(5, "new", &mut pairing);
        let batch = coalescer.batch(1, false);
        assert!(
            matches!(&batch.events[0].kind, EventKind::Renamed { from, .. } if from == &PathBuf::from("old"))
        );
        assert!(matches!(pairing.kind(5), RawKind::RenameTo(0)));
        pairing.kind(4);
        pairing.reset();
        assert!(matches!(pairing.kind(5), RawKind::RenameTo(0)));
        pairing.kind(4);
        pairing.kind(3);
        assert!(matches!(pairing.kind(5), RawKind::RenameTo(0)));
    }
}
