const std = @import("std");

pub const Scanner = struct {
    input: []const u8,
    pos: usize = 0,
    line_start: usize = 0,
    line_number: usize = 1,
    column: usize = 0,

    pub fn init(input: []const u8) Scanner {
        return Scanner{
            .input = input,
        };
    }

    pub fn peek(self: *Scanner) ?u8 {
        if (self.pos >= self.input.len) return null;
        return self.input[self.pos];
    }

    pub fn peekAt(self: *Scanner, offset: usize) ?u8 {
        const idx = self.pos + offset;
        if (idx >= self.input.len) return null;
        return self.input[idx];
    }

    pub fn consume(self: *Scanner) ?u8 {
        const ch = self.peek() orelse return null;
        self.pos += 1;

        if (ch == '\t') {
            // Tab stops at column 4
            self.column += 4 - (self.column % 4);
        } else if (ch == '\n') {
            self.line_number += 1;
            self.line_start = self.pos;
            self.column = 0;
        } else {
            self.column += 1;
        }

        return ch;
    }

    pub fn consumeN(self: *Scanner, n: usize) void {
        var i: usize = 0;
        while (i < n and self.consume() != null) : (i += 1) {}
    }

    pub fn skipWhitespace(self: *Scanner) void {
        while (self.peek()) |ch| {
            if (ch != ' ' and ch != '\t') break;
            _ = self.consume();
        }
    }

    pub fn skipSpaces(self: *Scanner) usize {
        var count: usize = 0;
        while (self.peek()) |ch| {
            if (ch != ' ') break;
            _ = self.consume();
            count += 1;
        }
        return count;
    }

    pub fn isAtEnd(self: *Scanner) bool {
        return self.pos >= self.input.len;
    }

    pub fn remaining(self: *Scanner) []const u8 {
        if (self.pos >= self.input.len) return "";
        return self.input[self.pos..];
    }

    pub fn slice(self: *Scanner, start: usize, end: usize) []const u8 {
        return self.input[start..end];
    }
};

pub fn isWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

pub fn isAsciiPunctuation(ch: u8) bool {
    return switch (ch) {
        '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*',
        '+', ',', '-', '.', '/', ':', ';', '<', '=', '>',
        '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|',
        '}', '~' => true,
        else => false,
    };
}

pub fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

pub fn isHexDigit(ch: u8) bool {
    return (ch >= '0' and ch <= '9') or
           (ch >= 'a' and ch <= 'f') or
           (ch >= 'A' and ch <= 'F');
}

pub fn isAlpha(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
}

pub fn isAlphanumeric(ch: u8) bool {
    return isAlpha(ch) or isDigit(ch);
}

// Tab expansion - converts tabs to spaces with tab stops at 4
pub fn expandTabs(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len);
    errdefer result.deinit(allocator);

    var column: usize = 0;
    for (input) |ch| {
        if (ch == '\t') {
            const spaces_to_add = 4 - (column % 4);
            var i: usize = 0;
            while (i < spaces_to_add) : (i += 1) {
                try result.append(allocator, ' ');
            }
            column += spaces_to_add;
        } else if (ch == '\n' or ch == '\r') {
            try result.append(allocator, ch);
            column = 0;
        } else {
            try result.append(allocator, ch);
            column += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

// Normalize line endings to \n
pub fn normalizeLineEndings(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len);
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\r') {
            if (i + 1 < input.len and input[i + 1] == '\n') {
                // CRLF -> LF
                try result.append(allocator, '\n');
                i += 2;
            } else {
                // CR -> LF
                try result.append(allocator, '\n');
                i += 1;
            }
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

// Split input into lines
pub fn splitLines(allocator: std.mem.Allocator, input: []const u8) !std.ArrayList([]const u8) {
    var lines = try std.ArrayList([]const u8).initCapacity(allocator, 64);
    errdefer lines.deinit(allocator);

    var line_start: usize = 0;
    var i: usize = 0;

    while (i < input.len) {
        if (input[i] == '\n') {
            try lines.append(allocator, input[line_start..i]);
            i += 1;
            line_start = i;
        } else {
            i += 1;
        }
    }

    // Add the last line if there's content after the last newline
    if (line_start < input.len) {
        try lines.append(allocator, input[line_start..]);
    }

    return lines;
}

test "scanner basic" {
    var scanner = Scanner.init("hello world");
    try std.testing.expectEqual(@as(?u8, 'h'), scanner.peek());
    try std.testing.expectEqual(@as(?u8, 'h'), scanner.consume());
    try std.testing.expectEqual(@as(?u8, 'e'), scanner.peek());
}

test "tab expansion" {
    const allocator = std.testing.allocator;
    const input = "a\tb\t\tc";
    const result = try expandTabs(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("a   b       c", result);
}

test "normalize line endings" {
    const allocator = std.testing.allocator;
    const input = "line1\r\nline2\rline3\n";
    const result = try normalizeLineEndings(allocator, input);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("line1\nline2\nline3\n", result);
}
