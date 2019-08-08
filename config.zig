// config.zig

const std = @import("std");
const ArrayList = std.ArrayList;
const allocator = std.heap.c_allocator;

const c = @import("c_imports.zig").c;
const buffer = @import("buffer.zig");
const syn = @import("syntax.zig");

pub const Config = struct {
    orig_termios: c.termios,
    cursorX: u16,
    cursorY: u16,
    cursorX_rendered: u16,
    rowOffset: u16,
    colOffset: u16,
    screenCols: u16,
    screenRows: u16,
    numRows: u16,
    dirty: usize, // number of unsaved changes
    filename: ?[]u8,
    statusMsg: ?[]u8,
    statusMsgTime: u64, // POSIX timestamp, UTC, in seconds
    syntax: ?*const syn.EditorSyntax,
    rows: ArrayList(*buffer.Row),

    pub fn init() Config {
        return Config{
            .orig_termios = undefined,
            .cursorX = 0,
            .cursorY = 0,
            .cursorX_rendered = 0,
            .rowOffset = 0,
            .colOffset = 0,
            .screenCols = 0,
            .screenRows = 0,
            .numRows = 0,
            .dirty = 0,
            .filename = null,
            .statusMsg = null,
            .statusMsgTime = 0,
            .syntax = null,
            .rows = ArrayList(*buffer.Row).init(allocator),
        };
    }
};

// eof
