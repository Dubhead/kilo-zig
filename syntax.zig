// syntax.zig

pub const SyntaxFlags = enum(u16) {
    HighlightNumbers = 1<<0,
    HighlightStrings = 1<<1,
};

pub const EditorSyntax = struct {
    pub fileType: []const u8,
    pub fileMatch: [][]const u8,
    pub keywords: [][]const u8,
    pub singlelineCommentStart: []const u8,
    pub multilineCommentStart: []const u8,
    pub multilineCommentEnd: []const u8,
    pub flags: usize,
};

// HLDB (highlight database)
pub const HLDB = [_]EditorSyntax {
    EditorSyntax {
        .fileType = "c",
        .fileMatch = [_][]u8{ ".c", ".h", ".cpp", },
        .keywords = [_][]u8{
            "switch", "if", "while", "for", "break", "continue", "return",
            "else", "struct", "union", "typedef", "static", "enum", "class",
            "case",

            "int|", "long|", "double|", "float|", "char|", "unsigned|",
            "signed|", "void|",
        },
        .singlelineCommentStart = "//",
        .multilineCommentStart = "/*",
        .multilineCommentEnd = "*/",
        .flags = @enumToInt(SyntaxFlags.HighlightNumbers) |
            @enumToInt(SyntaxFlags.HighlightStrings),
    },
};

// eof
