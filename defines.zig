// defines.zig

pub const KILO_VERSION = "0.0.1";
pub const KILO_QUIT_TIMES = 3;
pub const TAB_STOP = 8;

pub const EditorKey = enum(u16) {
    // values taken from
    // https://github.com/nsf/termbox/blob/57d73cea98ddc3e701064a069c1c3551880aff9b/src/termbox.h#L21

    F1 = (0xFFFF-0),
    F2 = (0xFFFF-1),
    F3 = (0xFFFF-2),
    F4 = (0xFFFF-3),
    F5 = (0xFFFF-4),
    F6 = (0xFFFF-5),
    F7 = (0xFFFF-6),
    F8 = (0xFFFF-7),
    F9 = (0xFFFF-8),
    F10 = (0xFFFF-9),
    F11 = (0xFFFF-10),
    F12 = (0xFFFF-11),
    Insert = (0xFFFF-12),
    Delete = (0xFFFF-13),
    Home = (0xFFFF-14),
    End = (0xFFFF-15),
    PgUp = (0xFFFF-16),
    PgDn = (0xFFFF-17),
    ArrowUp = (0xFFFF-18),
    ArrowDown = (0xFFFF-19),
    ArrowLeft = (0xFFFF-20),
    ArrowRight = (0xFFFF-21),

    Backspace = 0x08,
    Tab = 0x09,
    Enter = 0x0D,
    Esc = 0x1B,
    Backspace2 = 0x7F,
};

pub const EditorHighlight = enum(u8) {
    Normal = 0,
    Comment,
    MLComment,
    Keyword1,
    Keyword2,
    String,
    Number,
    Match,

    // Return the corresponding ANSI color code.
    pub fn color(self: EditorHighlight) u8 {
        return switch (self) {
            .Comment, .MLComment => u8(36), // cyan
            .Keyword1 => u8(33), // yellow
            .Keyword2 => u8(32), // green
            .String => u8(35), // magenta
            .Number => u8(31), // red
            .Match => u8(34), // blue
            else => u8(37),
        };
    }
};

// eof
