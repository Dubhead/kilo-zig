// kilo.zig

const std = @import("std");
const fmt = std.fmt;
const os = std.os;
const c = @import("c_imports.zig").c;
const allocator = std.heap.c_allocator;

const buffer = @import("buffer.zig");
const config = @import("config.zig");
const Config = config.Config;
const EditorSyntax = @import("syntax.zig").EditorSyntax;
const HLDB = @import("syntax.zig").HLDB;

// static variables in the original BYOTE
var quit_times: usize = KILO_QUIT_TIMES; // in editorProcessKeypress()
var efc_last_match: isize = -1; // in editorFindCallback()
var efc_direction: i16 = 1; // in editorFindCallback()
var efc_saved_hl_line: usize = undefined; // in editorFindCallback()
var efc_saved_hl: ?[]EditorHighlight = null; // in editorFindCallback()

//// defines ////

const KILO_VERSION = @import("defines.zig").KILO_VERSION;
const KILO_QUIT_TIMES = @import("defines.zig").KILO_QUIT_TIMES;
const EditorKey = @import("defines.zig").EditorKey;
const EditorHighlight = @import("defines.zig").EditorHighlight;

//// data ////

const TerminalError = error {
    Tcsetattr,
    Tcgetattr,
    Termcap,
    TerminalRead,
    TerminalWrite,
};

//// prototypes - unnecessary for Zig ////

//// terminal ////

fn ctrl(k: u8) u8 { return k & 0x1F; }

fn disableRawMode(cfg: *Config) void {
    _ = c.tcsetattr(os.STDIN_FILENO, c.TCSAFLUSH, &cfg.orig_termios);

    // TODO return error.Tcgetattr;
}

fn enableRawMode(cfg: *Config) TerminalError!void {
    var ret = c.tcgetattr(os.STDIN_FILENO, &(cfg.orig_termios));
    if (ret == -1) { return error.Tcgetattr; }
    var raw: c.termios = cfg.orig_termios;

    raw.c_iflag &= ~u16(c.BRKINT | c.ICRNL | c.INPCK | c.ISTRIP | c.IXON);
    raw.c_oflag &= ~u16(c.OPOST);
    raw.c_cflag |= u16(c.CS8);
    raw.c_lflag &= ~u16(c.ECHO | c.ICANON | c.IEXTEN | c.ISIG);
    raw.c_cc[c.VMIN] = 0;
    raw.c_cc[c.VTIME] = 1;
    ret = c.tcsetattr(os.STDIN_FILENO, c.TCSAFLUSH, &raw);
    if (ret == -1) { return error.Tcsetattr; }
}

fn editorReadKey() !u16 {
    const stdin_file = try std.io.getStdIn();
    var keybuf: [32]u8 = undefined;

    // TODO stdin_file.read() is a blocking I/O call,
    // so this loop shouldn't be necessary.
    var num_chars_read: usize = 0;
    while (num_chars_read == 0) {
        num_chars_read = try stdin_file.read(keybuf[0..1]);
    }

    if (keybuf[0] == '\x1b') {
        _ = stdin_file.read(keybuf[1..2]) catch return '\x1b';
        _ = stdin_file.read(keybuf[2..3]) catch return '\x1b';
        if (keybuf[1] == '[') {
            if (keybuf[2] >= '0' and keybuf[2] <= '9') {
                _ = stdin_file.read(keybuf[3..4]) catch return '\x1b';
                if (keybuf[3] == '~') {
                    switch (keybuf[2]) {
                        '1' => return @enumToInt(EditorKey.Home),
                        '3' => return @enumToInt(EditorKey.Delete),
                        '4' => return @enumToInt(EditorKey.End),
                        '5' => return @enumToInt(EditorKey.PgUp),
                        '6' => return @enumToInt(EditorKey.PgDn),
                        '7' => return @enumToInt(EditorKey.Home),
                        '8' => return @enumToInt(EditorKey.End),
                        else => {},
                    }
                }
            } else {
                switch (keybuf[2]) {
                    'A' => return @enumToInt(EditorKey.ArrowUp),
                    'B' => return @enumToInt(EditorKey.ArrowDown),
                    'C' => return @enumToInt(EditorKey.ArrowRight),
                    'D' => return @enumToInt(EditorKey.ArrowLeft),
                    'H' => return @enumToInt(EditorKey.Home),
                    'F' => return @enumToInt(EditorKey.End),
                    else => {},
                }
            }
        } else if (keybuf[1] == 'O') {
            switch (keybuf[2]) {
                'H' => return @enumToInt(EditorKey.Home),
                'F' => return @enumToInt(EditorKey.End),
                else => {},
            }
        }

        return '\x1b';
    } else {
        return u16(keybuf[0]);
    }
}

fn getCursorPosition() TerminalError![2]u16 {
    var ret = c.write(c.STDOUT_FILENO, c"\x1b[6n", 4);
    if (ret != 4)
        return error.TerminalWrite;

    // The terminal answers with something like "\x1b[24;80\x00".  Read it.
    var buf: [32]u8 = undefined;
    for (buf) |*value, i| {
        var ret2 = c.read(c.STDIN_FILENO, value, 1);
        if (ret2 != 1 or value.* == 'R') {
            buf[i + 1] = '\x00';
            break;
        }
    }

    // Parse buf.
    if (buf[0] != '\x1b' or buf[1] != '[')
        return error.Termcap;
    var rowPos: c_int = undefined;
    var colPos: c_int = undefined;
    ret = c.sscanf(buf[2..].ptr, c"%d;%d", &rowPos, &colPos);
    if (ret != 2) {
        return error.Termcap;
    }

    return [2]u16{@intCast(u16, colPos), @intCast(u16, rowPos)};
}

fn getWindowSize() TerminalError![2]u16 {
    var ws: c.winsize = undefined;
    var ret = c.ioctl(c.STDOUT_FILENO, c.TIOCGWINSZ, &ws);
    if (ret != -1 and ws.ws_col != 0) {
        var result = [2]u16{ws.ws_col, ws.ws_row};
        return result;
    }

    // ioctl didn't work.  Now, move the cursor to bottom right of the screen,
    // then return the cursor position as the screen size.

    var ret2 = c.write(c.STDOUT_FILENO, c"\x1b[999C\x1b[999B", 12);
    if (ret2 != 12) {
        // return error.TerminalWrite; // WORKAROUND This kills compiler.
    }
    return getCursorPosition();
}

//// syntax highlighting ////

// is_separator -- see buffer.is_separator()

// editorUpdateSyntax -- see buffer.Row.updateSyntax()

// editorSyntaxToColor -- see defines.EditorHighlight.color()

fn editorSelectSyntaxHighlight(cfg: *Config) !void {
    cfg.syntax = null;
    const filename = cfg.filename orelse return;

    for (HLDB) |hldb| {
        for (hldb.fileMatch) |fm| {
            if (std.mem.endsWith(u8, filename, fm)) {
                cfg.syntax = &hldb;

                for (cfg.rows.toSlice()) |row| {
                    try row.updateSyntax();
                }

                return;
            }
        }
    }
}

//// row operations ////

// editorRowCxToRx -- see buffer.Row.screenColumn()

// editorRowRxToCx -- see buffer.Row.screenColToCharsIndex()

// editorUpdateRow -- see buffer.Row.render()

fn editorInsertRow(cfg: *Config, at: usize, s: []const u8) !void {
    if (at > cfg.numRows) return;

    var r: *buffer.Row = try buffer.Row.initFromString(cfg, &s[0..]);
    for (cfg.rows.toSlice()[at..]) |row| {
        row.idx += 1;
    }

    r.idx = at;

    try r.render();
    try cfg.rows.insert(at, r);
    cfg.numRows += 1;
    cfg.dirty += 1;
}

fn editorFreeRow(row: *buffer.Row) void {
    row.deinit();
}

fn editorDelRow(cfg: *Config, at: usize) void {
    if (at >= cfg.numRows)
        return;
    editorFreeRow(cfg.rows.at(at));
    _ = cfg.rows.orderedRemove(at);
    for (cfg.rows.toSlice()) |row| {
        row.idx -= 1;
    }
    cfg.numRows -= 1;
    cfg.dirty += 1;
}

fn editorRowInsertChar(
    cfg: *Config,
    row: *buffer.Row,
    insert_at: usize,
    ch: u8
) !void {
    try row.insertChar(insert_at, ch);
    cfg.dirty += 1;
}

fn editorRowAppendString(cfg: *Config, row: *buffer.Row, s: []u8) !void {
    try row.appendString(s);
    cfg.dirty += 1;
}

fn editorRowDelChar(cfg: *Config, row: *buffer.Row, at: usize) !void {
    try row.delChar(at);
    cfg.dirty += 1;
}

//// editor operations ////

fn editorInsertChar(cfg: *Config, ch: u8) !void {
    if (cfg.cursorY == cfg.numRows) {
        try editorInsertRow(cfg, cfg.numRows, "");
    }
    try editorRowInsertChar(cfg,
        cfg.rows.at(cfg.cursorY),
        cfg.cursorX,
        ch);
    cfg.cursorX += 1;
}

fn editorInsertNewline(cfg: *Config) !void {
    if (cfg.cursorX == 0) {
        try editorInsertRow(cfg, cfg.cursorY, "");
    } else {
        var row = cfg.rows.at(cfg.cursorY);
        try editorInsertRow(cfg, cfg.cursorY + 1, row.chars[cfg.cursorX ..]);
        row = cfg.rows.at(cfg.cursorY);
        row.chars = row.chars[0 .. cfg.cursorX];
        try row.render();
    }
    cfg.cursorY += 1;
    cfg.cursorX = 0;
}

fn editorDelChar(cfg: *Config) !void {
    if (cfg.cursorY == cfg.numRows)
        return;
    if (cfg.cursorX == 0 and cfg.cursorY == 0)
        return;

    const row = cfg.rows.at(cfg.cursorY);
    if (cfg.cursorX > 0) {
        try editorRowDelChar(cfg, row, cfg.cursorX - 1);
        cfg.cursorX -= 1;
    } else {
        cfg.cursorX = cfg.rows.at(cfg.cursorY - 1).len();
        try editorRowAppendString(cfg,
            cfg.rows.at(cfg.cursorY - 1),
            row.chars);
        editorDelRow(cfg, cfg.cursorY);
        cfg.cursorY -= 1;
    }
}

//// file i/o ////

// Caller must free the result.
fn editorRowsToString(cfg: *Config) ![]u8 {
    var totalLen: usize = 0;
    var idx_row: usize = 0;
    while (idx_row < cfg.numRows): (idx_row += 1) {
        totalLen += cfg.rows.at(idx_row).len() + 1;
    }

    var result: []u8 = try allocator.alloc(u8, totalLen);
    var idx_result: usize = 0;
    for (cfg.rows.toSlice()) |row| {
        std.mem.copy(u8,
            result[idx_result .. idx_result + row.len()],
            row.chars[0..]);
        idx_result += row.len();
        result[idx_result] = '\n';
        idx_result += 1;
    }

    return result;
}

fn editorOpen(cfg: *Config, filename: []u8) !void {
    if (cfg.filename) |f| {
        allocator.free(f);
    }
    cfg.filename = try std.mem.dupe(allocator, u8, filename);

    try editorSelectSyntaxHighlight(cfg);

    var file: std.fs.File = try std.fs.File.openRead(filename);
    defer file.close();
    var line_buf = try std.Buffer.initSize(allocator, 0);
    defer line_buf.deinit();

    while (file.inStream().stream
        .readUntilDelimiterBuffer(&line_buf, '\n', c.LINE_MAX))
    {
        try editorInsertRow(cfg, cfg.numRows, line_buf.toSlice());
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
    cfg.dirty = 0;
}

fn editorSave(cfg: *Config) !void {
    var filename: []u8 = undefined;
    if (cfg.filename) |f| {
        filename = f;
    } else {
        var resp = try editorPrompt(cfg, "Save as: {s} (ESC to cancel)", null);
        if (resp) |f| {
            filename = f;
            cfg.filename = f;
            try editorSelectSyntaxHighlight(cfg);
        } else {
            try editorSetStatusMessage(cfg, "Save aborted");
            return;
        }
    }

    const buf = try editorRowsToString(cfg);
    defer allocator.free(buf);
    if (std.io.writeFile(filename, buf)) |_| {
        cfg.dirty = 0;
        try editorSetStatusMessage(cfg,
            "{} bytes written to disk",
            buf.len);
    } else |err| {
        try editorSetStatusMessage(cfg,
            "Can't save! I/O error: {}",
            err);
    }
}

//// find ////

fn editorFindCallback(cfg: *Config,
    query: []u8,
    ch: u16
) anyerror!void {
    // This function in the origital BYOTE has some static variables.
    // They are global variables in this Zig version.
    //
    // efc_last_match -- index of the row that the last match was on,
    // or -1 if there was no last match
    // efc_direction -- 1 for searching forward, -1 backward
    // efc_saved_hl_line -- copy of Row.hl before highlighting
    // efc_saved_hl -- line number for efc_saved_hl_line

    if (efc_saved_hl) |shl| {
        const row = cfg.rows.at(efc_saved_hl_line);
        for (shl) |v, idx| {
            row.hl[idx] = v;
        }
        allocator.free(shl);
        efc_saved_hl = null;
    }

    if (ch == '\r' or ch == '\x1b') {
        efc_last_match = -1;
        efc_direction = 1;
        return;
    } else if (ch == @enumToInt(EditorKey.ArrowRight) or
            ch == @enumToInt(EditorKey.ArrowDown)) {
        efc_direction = 1;
    } else if (ch == @enumToInt(EditorKey.ArrowLeft) or
            ch == @enumToInt(EditorKey.ArrowUp)) {
        efc_direction = -1;
    } else {
        efc_last_match = -1;
        efc_direction = 1;
    }

    if (efc_last_match == -1)
        efc_direction = 1;
    var current: i16 = @intCast(i16, efc_last_match); // current row
    var idx: u16 = 0;
    while (idx < cfg.rows.count()): (idx += 1) {
        current += efc_direction;
        if (current == -1) {
            // wrap to bottom of file
            current = @intCast(i16, cfg.numRows) - 1;
        } else if (current == @intCast(i16, cfg.numRows)) {
            // wrap to beginning of file
            current = 0;
        }

        var row = cfg.rows.at(@intCast(usize, current));
        if (row.find(query, 0)) |col| {
            efc_last_match = current;
            cfg.cursorY = @intCast(u16, current);
            cfg.cursorX = row.screenColToCharsIndex(col);
            cfg.rowOffset = cfg.numRows;

            efc_saved_hl_line = @intCast(usize, current);
            efc_saved_hl = try allocator.alloc(EditorHighlight, row.len());
            for (row.hl) |v, i| {
                efc_saved_hl.?[i] = v;
            }
            std.mem.set(EditorHighlight,
                row.hl[col .. col + query.len],
                EditorHighlight.Match);
            break;
        }
    }
}

fn editorFind(cfg: *Config) !void {
    const saved_cursorX = cfg.cursorX;
    const saved_cursorY = cfg.cursorY;
    const saved_colOffset = cfg.colOffset;
    const saved_rowOffset = cfg.rowOffset;

    const query = try editorPrompt(cfg,
        "Search: {s} (Use ESC/Arrows/Enter)",
        editorFindCallback);

    if (query) |q| {
        allocator.free(q);
    } else {
        cfg.cursorX = saved_cursorX;
        cfg.cursorY = saved_cursorY;
        cfg.colOffset = saved_colOffset;
        cfg.rowOffset = saved_rowOffset;
    }
}

//// append buffer ////

const AppendBuffer = struct {
    buf: []u8,

    pub fn init(cfg: *const Config) !AppendBuffer {
        const initial_size: usize = 32;
        return AppendBuffer {
            .buf = try allocator.alloc(u8, initial_size),
        };
    }

    pub fn free(self: AppendBuffer) void {
        allocator.free(self.buf);
    }

    pub fn append(self: *AppendBuffer, s: []const u8) !void {
        const oldlen = self.buf.len;
        self.buf = try allocator.realloc(self.buf, oldlen + s.len);
        for (s) |data, index| {
            self.buf[oldlen + index] = data;
        }
    }
};

//// output ////

fn editorScroll(cfg: *Config) void {
    cfg.cursorX_rendered = 0;
    if (cfg.cursorY < cfg.numRows) {
        cfg.cursorX_rendered =
            cfg.rows.at(cfg.cursorY).screenColumn(cfg.cursorX);
    }

    // Is cursor above the visible window?
    if (cfg.cursorY < cfg.rowOffset) {
        cfg.rowOffset = cfg.cursorY;
    }

    // Is cursor past the bottom of the visible window?
    if (cfg.cursorY >= cfg.rowOffset + cfg.screenRows) {
        cfg.rowOffset = cfg.cursorY - cfg.screenRows + 1;
    }

    if (cfg.cursorX_rendered < cfg.colOffset) {
        cfg.colOffset = cfg.cursorX_rendered;
    }

    if (cfg.cursorX_rendered >= cfg.colOffset + cfg.screenCols) {
        cfg.colOffset = cfg.cursorX_rendered - cfg.screenCols + 1;
    }
}

fn editorDrawRows(cfg: *const Config, abuf: *AppendBuffer) !void {
    var y: u32 = 0;
    while (y < cfg.screenRows): (y += 1) {
        var filerow: u32 = y + cfg.rowOffset;
        if (filerow >= cfg.numRows) {
            if (cfg.numRows == 0 and y == cfg.screenRows / 3) {
                var welcome: [80]u8 = undefined;
                var output = try std.fmt.bufPrint(welcome[0..],
                    "Kilo editor -- version {}", KILO_VERSION);
                if (output.len > cfg.screenRows)
                    output = output[0..cfg.screenRows];
                var padding: usize = (cfg.screenCols - output.len) / 2;
                if (padding > 0) {
                    try abuf.append("~");
                    padding -= 1;
                }
                while (padding > 0): (padding -= 1) {
                    try abuf.append(" ");
                }
                try abuf.append(output);
            } else {
                try abuf.append("~");
            }
        } else {
            const renderedChars: []u8 = cfg.rows.at(filerow).renderedChars;
            var len = renderedChars.len;
            if (len < cfg.colOffset) {
                // Cursor is past EoL; show nothing.
                len = 0;
            } else { len -= cfg.colOffset; }
            len = std.math.min(len, cfg.screenCols);

            const hl = cfg.rows.at(filerow).hl;
            var current_color: ?u8 = null; // null == Normal
            var j: usize = 0;
            while (j < len): (j += 1) {
                const ch: []u8 =
                    renderedChars[cfg.colOffset + j .. cfg.colOffset + j + 1];
                if (std.ascii.isCntrl(ch[0])) {
                    const sym = [1]u8{ if (ch[0] <= 26) '@' + ch[0] else '?' };
                    try abuf.append("\x1b[7m");
                    try abuf.append(sym);
                    try abuf.append("\x1b[m");
                    if (current_color) |cc| {
                        var buf: [16]u8 = undefined;
                        const clen = try std.fmt.bufPrint(buf[0..],
                            "\x1b[{d}m",
                            cc);
                        try abuf.append(clen);
                    }
                } else if (hl[cfg.colOffset + j] == EditorHighlight.Normal) {
                    if (current_color) |_| {
                        try abuf.append("\x1b[39m"); // normal color text
                        current_color = null;
                    }
                    try abuf.append(ch);
                } else {
                    const color = hl[cfg.colOffset + j].color();
                    if (current_color == null or current_color.? != color) {
                        current_color = color;
                        const clen = try std.fmt.allocPrint(allocator,
                            "\x1b[{d}m",
                            color);
                        defer allocator.free(clen);
                        try abuf.append(clen);
                    }
                    try abuf.append(ch);
                }
            }
            try abuf.append("\x1b[39m");
        }

        try abuf.append("\x1b[K"); // Erase to EOL
        try abuf.append("\r\n");
    }
}

fn editorDrawStatusBar(cfg: *const Config, abuf: *AppendBuffer) !void {
    try abuf.append("\x1b[7m"); // inverted color

    // file name to show in the status line, up to 20 chars
    var filename: []const u8 = undefined;
    if (cfg.filename) |f| {
        if (f.len > 20) { filename = f[0..20]; }
        else filename = f;
    } else { filename = "[No Name]"[0..]; }

    var status = try std.fmt.allocPrint(allocator, "{} - {} lines {}",
        filename,
        cfg.numRows,
        if (cfg.dirty > 0) "(modified)" else ""
    );
    defer allocator.free(status);
    var right_status = try std.fmt.allocPrint(allocator, "{} | {}/{}",
        if (cfg.syntax) |s| s.fileType else "no ft",
        cfg.cursorY + 1,
        cfg.numRows);
    defer allocator.free(right_status);

    var len = @intCast(u16, status.len);
    len = std.math.min(len, cfg.screenCols);
    try abuf.append(status);
    while (len < cfg.screenCols) {
        if (cfg.screenCols - len == @intCast(u16, right_status.len)) {
            try abuf.append(right_status);
            break;
        } else {
            try abuf.append(" ");
            len += 1;
        }
    }
    try abuf.append("\x1b[m"); // back to normal text formatting
    try abuf.append("\r\n");
}

fn editorDrawMessageBar(cfg: *Config, abuf: *AppendBuffer) !void {
    var sm = cfg.statusMsg orelse return;
    try abuf.append("\x1b[K");
    var msglen = std.math.min(sm.len, cfg.screenCols);
    if ((msglen > 0) and ((std.time.timestamp() - cfg.statusMsgTime) < 5)) {
        try abuf.append(sm);
    }
}

fn editorRefreshScreen(cfg: *Config) !void {
    editorScroll(cfg);

    const abuf: *AppendBuffer = &(try AppendBuffer.init(cfg));
    defer abuf.free();
    try abuf.append("\x1b[?25l");
    try abuf.append("\x1b[H");

    try editorDrawRows(cfg, abuf);
    try editorDrawStatusBar(cfg, abuf);
    try editorDrawMessageBar(cfg, abuf);

    var buf: [32]u8 = undefined;
    var output = try std.fmt.bufPrint(buf[0..], "\x1b[{};{}H",
        (cfg.cursorY - cfg.rowOffset) + 1,
        cfg.cursorX_rendered + 1);
    try abuf.append(output);

    try abuf.append("\x1b[?25h");
    _ = c.write(c.STDOUT_FILENO, abuf.buf.ptr, abuf.buf.len);
}

fn editorSetStatusMessage(
    cfg: *Config,
    comptime format: []const u8,
    args: ...
) !void {
    if (cfg.statusMsg) |sm| {
        allocator.free(sm);
    }
    cfg.statusMsg = try std.fmt.allocPrint(allocator, format, args);
    cfg.statusMsgTime = std.time.timestamp();
}

//// input ////

// Caller must free the result.
fn editorPrompt(
    cfg: *Config,
    comptime prompt: []const u8,
    callback: ?fn (cfg: *Config, prompt: []u8, ch: u16) anyerror!void
) !?[]u8 {
    var buf = try std.Buffer.init(allocator, "");
    while (true) {
        try editorSetStatusMessage(cfg, prompt, buf.toSlice()[0..]);
        try editorRefreshScreen(cfg);

        const ch = try editorReadKey();
        if (ch == @enumToInt(EditorKey.Delete) or ch == ctrl('h') or
                ch == @enumToInt(EditorKey.Backspace) or
                ch == @enumToInt(EditorKey.Backspace2)) {
            if (buf.len() != 0) {
                buf.shrink(buf.len() - 1);
            }
        } else if (ch == '\x1b') { // input is cancelled
            try editorSetStatusMessage(cfg, "");
            if (callback) |cb| {
                try cb(cfg, buf.toSlice(), ch);
            }
            buf.deinit();
            return null;
        } else if (ch == '\r') {
            if (buf.len() != 0) {
                try editorSetStatusMessage(cfg, "");
                if (callback) |cb| {
                    try cb(cfg, buf.toSlice(), ch);
                }
                return buf.toSlice();
            }
        } else if (ch < 128 and !std.ascii.isCntrl(@intCast(u8, ch))) {
            try buf.appendByte(@intCast(u8, ch));
        }

        if (callback) |cb| {
            try cb(cfg, buf.toSlice(), ch);
        }
    }
}

fn editorMoveCursor(cfg: *Config, key: u16) void {
    // buffer.Row that the cursor is at.  null means past-EoF.
    var row: ?*(buffer.Row) =
        if (cfg.cursorY >= cfg.rows.len) null
        else cfg.rows.at(cfg.cursorY);

    switch (key) {
        @enumToInt(EditorKey.ArrowLeft) => {
            if (cfg.cursorX > 0) {
                cfg.cursorX -= 1;
            } else if (cfg.cursorY > 0) {
                cfg.cursorY -= 1;
                cfg.cursorX = cfg.rows.at(cfg.cursorY).len();
            }
        },
        @enumToInt(EditorKey.ArrowRight) => {
            if (row != null and cfg.cursorX < row.?.len()) {
                cfg.cursorX += 1;
            }
            else if (row != null and cfg.cursorX == row.?.len()) {
                cfg.cursorY += 1;
                cfg.cursorX = 0;
            }
        },
        @enumToInt(EditorKey.ArrowUp) => {
            if (cfg.cursorY > 0)
                cfg.cursorY -= 1;
        },
        @enumToInt(EditorKey.ArrowDown) => {
            if (cfg.cursorY < cfg.numRows)
                cfg.cursorY += 1;
        },
        else => {},
    }

    // If the cursor is past EoL, correct it.
    row = if (cfg.cursorY >= cfg.numRows) null
        else cfg.rows.at(cfg.cursorY);
    var rowlen = if (row == null) u16(0)
        else row.?.len();
    if (cfg.cursorX > rowlen) {
        cfg.cursorX = rowlen;
    }
}

fn editorProcessKeypress(cfg: *Config) !void {
    // quit_times = ...; // variable of static int in the original BYOTE

    var key = try editorReadKey();
    switch (key) {
        '\r' => try editorInsertNewline(cfg),

        comptime ctrl('q') => {
            if (cfg.dirty > 0 and quit_times > 0) {
                try editorSetStatusMessage(cfg,
                    "WARNING! File has unsaved changes. Press Ctrl-Q {} more times to quit.",
                    quit_times);
                quit_times -= 1;
                return;
            }

            const stdout_file = try std.io.getStdOut();
            _ = c.write(c.STDOUT_FILENO, c"\x1b[2J", 4);
            _ = c.write(c.STDOUT_FILENO, c"\x1b[H", 3);
            c.exit(0);    // TODO
        },

        comptime ctrl('s') => try editorSave(cfg),

        @enumToInt(EditorKey.Home) => {
            cfg.cursorX = 0;
        },

        @enumToInt(EditorKey.End) => {
            if (cfg.cursorY < cfg.numRows)
                cfg.cursorX = cfg.rows.at(cfg.cursorY).len();
        },

        comptime ctrl('f') => try editorFind(cfg),

        @enumToInt(EditorKey.Backspace),
        @enumToInt(EditorKey.Backspace2),
        @enumToInt(EditorKey.Delete) => {
            if (key == @enumToInt(EditorKey.Delete)) {
                editorMoveCursor(cfg, @enumToInt(EditorKey.ArrowRight));
            }
            try editorDelChar(cfg);
        },

        @enumToInt(EditorKey.PgUp),
        @enumToInt(EditorKey.PgDn) => {
            if (key == @enumToInt(EditorKey.PgUp)) {
                cfg.cursorY = cfg.rowOffset;
            } else if (key == @enumToInt(EditorKey.PgDn)) {
                cfg.cursorY = cfg.rowOffset + cfg.screenRows - 1;
                if (cfg.cursorY > cfg.numRows)
                    cfg.cursorY = cfg.numRows;
            }

            var times = cfg.screenRows;
            while (times > 0): (times -= 1) {
                editorMoveCursor(cfg,
                    if (key == @enumToInt(EditorKey.PgUp))
                        @enumToInt(EditorKey.ArrowUp)
                    else @enumToInt(EditorKey.ArrowDown));
            }
        },

        @enumToInt(EditorKey.ArrowUp),
        @enumToInt(EditorKey.ArrowDown),
        @enumToInt(EditorKey.ArrowLeft),
        @enumToInt(EditorKey.ArrowRight) => editorMoveCursor(cfg, key),

        comptime ctrl('l'),
        @enumToInt(EditorKey.Esc) => {}, // TODO

        else => {
            try editorInsertChar(cfg, @intCast(u8, key));
        },
    }

    quit_times = KILO_QUIT_TIMES;
}

//// init ////

fn initEditor(cfg: *Config) !void {
    cfg.cursorX = 0;
    cfg.cursorY = 0;
    cfg.cursorX_rendered = 0;
    cfg.rowOffset = 0;
    cfg.colOffset = 0;
    cfg.numRows = 0;

    var ret = try getWindowSize();
    cfg.screenCols = ret[0];
    cfg.screenRows = ret[1];
    cfg.screenRows -= 2; // for status line
}

fn main_sub() !u8 {
    // command line args
    var args_it = std.process.args();
    const ego = try args_it.next(allocator).?;
    const filename_opt: ?[]u8 =
        if (args_it.next(allocator)) |foo| blk: {
            break :blk try foo;
        } else null;

    var cfg = Config.init();
    try enableRawMode(&cfg);
    defer disableRawMode(&cfg);
    try initEditor(&cfg);
    if (filename_opt) |filename| {
        try editorOpen(&cfg, filename);
    }

    try editorSetStatusMessage(&cfg,
        "HELP: Ctrl-S = save | Ctrl-Q = quit | Ctrl-F = find");

    while (true) {
        try editorRefreshScreen(&cfg);
        try editorProcessKeypress(&cfg);
    }

    return 0;
}

pub fn main() u8 {
    if (main_sub()) |v| {
        return 0;
    } else |err| {
        return 1;
    }
}

// eof
