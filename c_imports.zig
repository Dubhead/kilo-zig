// c_imports.zig

pub const c = @cImport({
    @cInclude("ctype.h");
    @cInclude("limits.h");
    @cInclude("sys/ioctl.h");
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

// eof
