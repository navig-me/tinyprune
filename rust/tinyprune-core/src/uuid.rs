use std::fmt;

/// 128-bit identifier. Displays as upper-case canonical text, like Swift's `UUID.uuidString`. Fixed-width
/// upper-case hex means numeric order equals the string order Swift uses for tie-breaking.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct Uuid(pub u128);

impl Uuid {
    pub fn parse(text: &str) -> Option<Uuid> {
        let bytes = text.as_bytes();
        if bytes.len() != 36 {
            return None;
        }
        let mut value: u128 = 0;
        for (index, byte) in bytes.iter().enumerate() {
            if matches!(index, 8 | 13 | 18 | 23) {
                if *byte != b'-' {
                    return None;
                }
                continue;
            }
            value = (value << 4) | (*byte as char).to_digit(16)? as u128;
        }
        Some(Uuid(value))
    }
}

impl fmt::Display for Uuid {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let hex = format!("{:032X}", self.0);
        write!(f, "{}-{}-{}-{}-{}", &hex[0..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..32])
    }
}
