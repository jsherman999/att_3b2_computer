//! Character -> scan code for the 630's 98-key keyboard (type 0x11).
//!
//! Verified by pressing every scan code on the emulated terminal and recording what
//! it sent to the host (`kbmap630`). Shift is scan code 0x1E, Ctrl is 0x1D.

pub const SHIFT: u8 = 0x1e;
pub const CTRL: u8 = 0x1d;
pub const RETURN: u8 = 0x5a;
pub const TAB: u8 = 0x39;
pub const BACKSPACE: u8 = 0x2e;
pub const ESCAPE: u8 = 0x53;
pub const DELETE: u8 = 0x2d;
pub const UP: u8 = 0x55;
pub const DOWN: u8 = 0x6c;
pub const RIGHT: u8 = 0x0e;
pub const LEFT: u8 = 0x3a;

/// A printable character: (scan code, needs Shift).
pub fn printable(c: char) -> Option<(u8, bool)> {
    Some(match c {
        ' ' => (0x3e, false),
        '!' => (0x0a, true),
        '"' => (0x25, true),
        '#' => (0x41, true),
        '$' => (0x01, true),
        '%' => (0x6f, true),
        '&' => (0x45, true),
        '\'' => (0x25, false),
        '(' => (0x21, true),
        ')' => (0x70, true),
        '*' => (0x33, true),
        '+' => (0x52, true),
        ',' => (0x24, false),
        '-' => (0x58, false),
        '.' => (0x2a, false),
        '/' => (0x30, false),
        '0' => (0x70, false),
        '1' => (0x27, false),
        '2' => (0x76, false),
        '3' => (0x41, false),
        '4' => (0x01, false),
        '5' => (0x6f, false),
        '6' => (0x51, false),
        '7' => (0x45, false),
        '8' => (0x33, false),
        '9' => (0x21, false),
        ':' => (0x1f, true),
        ';' => (0x1f, false),
        '<' => (0x68, false),
        '=' => (0x52, false),
        '>' => (0x68, true),
        '?' => (0x30, true),
        '@' => (0x76, true),
        'A' => (0x4a, true),
        'B' => (0x74, true),
        'C' => (0x15, true),
        'D' => (0x1c, true),
        'E' => (0x4c, true),
        'F' => (0x0f, true),
        'G' => (0x5d, true),
        'H' => (0x57, true),
        'I' => (0x14, true),
        'J' => (0x7a, true),
        'K' => (0x1a, true),
        'L' => (0x0c, true),
        'M' => (0x08, true),
        'N' => (0x02, true),
        'O' => (0x37, true),
        'P' => (0x19, true),
        'Q' => (0x44, true),
        'R' => (0x09, true),
        'S' => (0x56, true),
        'T' => (0x69, true),
        'U' => (0x3f, true),
        'V' => (0x63, true),
        'W' => (0x5c, true),
        'X' => (0x22, true),
        'Y' => (0x4b, true),
        'Z' => (0x6e, true),
        '[' => (0x0a, false),
        '\\' => (0x16, false),
        ']' => (0x27, true),
        '^' => (0x51, true),
        '_' => (0x58, true),
        '`' => (0x5f, false),
        'a' => (0x4a, false),
        'b' => (0x74, false),
        'c' => (0x15, false),
        'd' => (0x1c, false),
        'e' => (0x4c, false),
        'f' => (0x0f, false),
        'g' => (0x5d, false),
        'h' => (0x57, false),
        'i' => (0x14, false),
        'j' => (0x7a, false),
        'k' => (0x1a, false),
        'l' => (0x0c, false),
        'm' => (0x08, false),
        'n' => (0x02, false),
        'o' => (0x37, false),
        'p' => (0x19, false),
        'q' => (0x44, false),
        'r' => (0x09, false),
        's' => (0x56, false),
        't' => (0x69, false),
        'u' => (0x3f, false),
        'v' => (0x63, false),
        'w' => (0x5c, false),
        'x' => (0x22, false),
        'y' => (0x4b, false),
        'z' => (0x6e, false),
        '{' => (0x10, false),
        '|' => (0x16, true),
        '}' => (0x10, true),
        '~' => (0x5f, true),
        _ => return None,
    })
}

/// Any ASCII character as (scan code, Shift, Ctrl), including CR, tab, backspace,
/// escape, DEL and control characters (Ctrl + letter).
pub fn ascii(c: char) -> Option<(u8, bool, bool)> {
    match c {
        '\r' | '\n' => Some((RETURN, false, false)),
        '\t' => Some((TAB, false, false)),
        '\x08' => Some((BACKSPACE, false, false)),
        '\x1b' => Some((ESCAPE, false, false)),
        '\x7f' => Some((DELETE, false, false)),
        '\x01'..='\x1a' => printable((c as u8 + 0x60) as char).map(|(k, _)| (k, false, true)),
        _ => printable(c).map(|(k, s)| (k, s, false)),
    }
}
