// buffer.zig

const std = @import("std");
const allocator = std.heap.c_allocator;

const c = @import("c_imports.zig").c;
const Config = @import("config.zig").Config;

const EditorHighlight = @import("defines.zig").EditorHighlight;

const TAB_STOP = @import("defines.zig").TAB_STOP;

const SyntaxFlags = @import("syntax.zig").SyntaxFlags;

pub const Row = struct {
    pub config: *Config,

    pub idx: usize, // my own index within the file
    pub chars: []u8,
    pub renderedChars: []u8,
    pub hl: []EditorHighlight, // highlight
    pub hl_open_comment: bool,

    pub fn init(cfg: *Config) !*Row {
        var foo: []Row = try allocator.alloc(Row, 1);
        var result = @ptrCast(*Row, foo.ptr);
        result.config = cfg;
        result.idx = 0;
        result.chars = try allocator.alloc(u8, 1);
        result.renderedChars = try allocator.alloc(u8, 1);
        result.hl = try allocator.alloc(EditorHighlight, 1);
        result.hl_open_comment = false;
        return result;
    }

    pub fn initFromString(cfg: *Config, s: *[]const u8) !*Row {
        var foo: []Row = try allocator.alloc(Row, 1);
        var result = @ptrCast(*Row, foo.ptr);
        result.config = cfg;
        result.chars = (try allocator.alloc(u8, s.len))[0..s.len];
        for (s.*) |ch, idx| {
            result.chars[idx] = ch;
        }
        result.renderedChars = try allocator.alloc(u8, 1);
        result.hl = try allocator.alloc(EditorHighlight, 1);
        return result;
    }

    pub fn deinit(self: *Row) void {
        allocator.free(self.chars);
        allocator.free(self.renderedChars);
        allocator.free(self.hl);
    }

    // Render `self.chars` into `self.renderedChars`.
    pub fn render(self: *Row) !void {
        allocator.free(self.renderedChars);

        var numTabs: usize = 0; // number of tabs in self.chars
        for (self.chars) |ch, idx| {
            if (ch == '\t') numTabs += 1;
        }

        self.renderedChars = try allocator.alloc(u8,
            self.chars.len + numTabs * (TAB_STOP - 1));
        var idx_rchars: usize = 0;      // index into self.renderedChars
        for (self.chars) |ch, idx_chars| {
            if (ch == '\t') {
                self.renderedChars[idx_rchars] = ' ';
                idx_rchars += 1;
                while (idx_rchars % TAB_STOP != 0) {
                    self.renderedChars[idx_rchars] = ' ';
                    idx_rchars += 1;
                }
            } else {
                self.renderedChars[idx_rchars] = ch;
                idx_rchars += 1;
            }
        }

        try self.updateSyntax();
    }

    pub fn updateSyntax(self: *Row) anyerror!void {
        self.hl = try allocator.realloc(self.hl, self.renderedChars.len);
        std.mem.set(EditorHighlight,
            self.hl,
            EditorHighlight.Normal);

        const syn = self.config.syntax orelse return;

        const keywords = syn.keywords;

        const scs = syn.singlelineCommentStart;
        const mcs = syn.multilineCommentStart;
        const mce = syn.multilineCommentEnd;

        // Whether the last character was a separator. Initialized to true
        // because BoL is considered to be a separator.
        var prev_sep = true;

        var in_string: u8 = 0; // the quote char if inside strings
        var in_comment = self.idx > 0 and
            self.config.rows.at(self.idx - 1).hl_open_comment;

        var i: usize = 0;
        while (i < self.renderedChars.len) {
            const ch = self.renderedChars[i];
            const prev_hl: EditorHighlight =
                if (i > 0) self.hl[i - 1] else .Normal;

            // single-line comment
            if (scs.len > 0 and in_string == 0 and !in_comment) {
                if (std.mem.startsWith(u8, self.renderedChars[i..], scs)) {
                    std.mem.set(EditorHighlight,
                        self.hl[i..],
                        .Comment);
                    break;
                }
            }

            // multi-line comment
            if (mcs.len > 0 and mce.len > 0 and in_string == 0) {
                if (in_comment) {
                    self.hl[i] = .MLComment;
                    if (std.mem.startsWith(u8, self.renderedChars[i..], mce)) {
                        std.mem.set(EditorHighlight,
                            self.hl[i .. i + mce.len],
                            .MLComment);
                        i += mce.len;
                        in_comment = false;
                        prev_sep = true;
                        continue;
                    } else {
                        i += 1;
                        continue;
                    }
                } else if (std.mem.startsWith(u8,
                        self.renderedChars[i..],
                        mcs)) {
                    std.mem.set(EditorHighlight,
                        self.hl[i .. i + mcs.len],
                        .MLComment);
                    i += mcs.len;
                    in_comment = true;
                    continue;
                }
            }

            // strings
            if (syn.flags & @enumToInt(SyntaxFlags.HighlightStrings) > 0) {
                if (in_string > 0) {
                    self.hl[i] = .String;
                    if (ch == '\\' and i + 1 < self.renderedChars.len) {
                        self.hl[i + 1] = .String;
                        i += 2;
                        continue;
                    }
                    if (ch == in_string)
                        in_string = 0;
                    i += 1;
                    prev_sep = true;
                    continue;
                } else {
                    if (ch == '"' or ch == '\'') {
                        in_string = ch;
                        self.hl[i] = .String;
                        i += 1;
                        continue;
                    }
                }
            }

            // numbers
            if (syn.flags & @enumToInt(SyntaxFlags.HighlightNumbers) > 0) {
                if ((std.ascii.isDigit(ch) and
                        (prev_sep or prev_hl == .Number)) or
                    (ch == '.' and prev_hl == .Number)
                ) {
                    self.hl[i] = .Number;
                    i += 1;
                    prev_sep = false;
                    continue;
                }
            }

            // keywords
            if (prev_sep) {
                for (keywords) |kw| {
                    var klen = kw.len;
                    const kw2 = kw[klen - 1] == '|';
                    if (kw2) klen -= 1;

                    if (std.mem.startsWith(u8,
                            self.renderedChars[i..],
                            kw[0..klen]) and
                        (i + klen == self.renderedChars.len or
                            is_separator(self.renderedChars[i + klen])))
                    {
                        std.mem.set(EditorHighlight,
                            self.hl[i .. i + klen],
                            if (kw2) EditorHighlight.Keyword2
                                else EditorHighlight.Keyword1);
                        i += klen;
                        break;
                    }
                } else {
                    prev_sep = false;
                    continue;
                }
            }

            prev_sep = is_separator(@intCast(u8, ch));
            i += 1;
        }

        const changed = self.hl_open_comment != in_comment;
        self.hl_open_comment = in_comment;
        if (changed and self.idx + 1 < self.config.numRows) {
            try self.config.rows.at(self.idx + 1).updateSyntax();
        }
    }

    pub fn len(self: *Row) u16 {
        return @intCast(u16, self.chars.len);
    }

    // `editorRowCxToRx` in BYOTE.
    //
    // char_index: index into self.chars
    // Returns the corresponding screen column.
    pub fn screenColumn(self: *Row, char_index: usize) u16 {
        var result: u16 = 0;
        var idx: u16 = 0; // index into self.chars
        while (idx < char_index): (idx += 1) {
            if (self.chars[idx] == '\t') {
                result += (TAB_STOP - 1) - (result % TAB_STOP);
            }
            result += 1;
        }
        return result;
    }

    // `editorRowRxToCx` in BYOTE.
    //
    // scrCol: screen column
    // Returns the index into self.chars corresponding to `scrCol`
    pub fn screenColToCharsIndex(self: *Row, scrCol: usize) u16 {
        var idx: u16 = 0; // index into self.renderedChars
        var result: u16 = 0;
        while (result < self.chars.len): (result += 1) {
            if (self.chars[result] == '\t') {
                idx += (TAB_STOP - 1) - (idx % TAB_STOP);
            }
            idx += 1;

            if (idx > scrCol)
                return result;
        }
        return result;
    }

    pub fn insertChar(self: *Row, insert_at: usize, ch: u8) !void {
        const at = std.math.min(insert_at, self.chars.len);
        self.chars = try allocator.realloc(self.chars, self.chars.len + 1);
        std.mem.copyBackwards(u8,
            self.chars[at + 1 .. self.chars.len],
            self.chars[at .. self.chars.len - 1]);
        self.chars[at] = ch;
        try self.render();
    }

    pub fn appendString(self: *Row, s: []u8) !void {
        const oldLen = self.len();
        self.chars = try allocator.realloc(self.chars, oldLen + s.len);
        for (s) |ch, idx| {
            self.chars[oldLen + idx] = ch;
        }
        try self.render();
    }

    pub fn delChar(self: *Row, at: usize) !void {
        if (at > self.len()) return;
        std.mem.copy(u8,
            self.chars[at .. self.chars.len - 1],
            self.chars[at + 1 .. self.chars.len]);
        self.chars = self.chars[0 .. self.chars.len - 1];
        try self.render();
    }

    pub fn find(self: *Row, needle: []u8, screenCol: usize) ?usize {
        if (screenCol >= self.renderedChars.len)
            return null;
        return std.mem.indexOfPos(u8, self.renderedChars, screenCol, needle);
    }
};

fn is_separator(ch: u8) bool {
    return std.ascii.isSpace(ch) or
        ch == 0 or
        std.mem.indexOfScalar(u8, ",.()+-/*=~%<>[];", ch) != null;
}

// eof
