const std = @import("std");

pub fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, &std.ascii.whitespace);
}

pub fn trimLeft(s: []const u8) []const u8 {
    return std.mem.trimLeft(u8, s, &std.ascii.whitespace);
}

pub fn trimRight(s: []const u8) []const u8 {
    return std.mem.trimRight(u8, s, &std.ascii.whitespace);
}

pub fn startsWith(haystack: []const u8, needle: []const u8) bool {
    return std.mem.startsWith(u8, haystack, needle);
}

pub fn endsWith(haystack: []const u8, needle: []const u8) bool {
    return std.mem.endsWith(u8, haystack, needle);
}

pub fn countLeadingSpaces(s: []const u8) usize {
    var count: usize = 0;
    for (s) |ch| {
        if (ch != ' ') break;
        count += 1;
    }
    return count;
}

pub fn countLeadingChar(s: []const u8, ch: u8) usize {
    var count: usize = 0;
    for (s) |c| {
        if (c != ch) break;
        count += 1;
    }
    return count;
}

pub fn isBlankLine(s: []const u8) bool {
    for (s) |ch| {
        if (ch != ' ' and ch != '\t') return false;
    }
    return true;
}

// Calculate indentation taking into account tabs (tab = 4 spaces)
pub fn calculateIndentation(s: []const u8) usize {
    var indent: usize = 0;
    for (s) |ch| {
        if (ch == ' ') {
            indent += 1;
        } else if (ch == '\t') {
            // Tabs are treated as a fixed 4-column indentation unit.
            indent += 4;
        } else {
            break;
        }
    }
    return indent;
}

// Skip n columns of indentation (handling tabs)
pub fn skipIndentation(s: []const u8, columns: usize) []const u8 {
    var col: usize = 0;
    var i: usize = 0;

    while (i < s.len and col < columns) {
        if (s[i] == ' ') {
            col += 1;
            i += 1;
        } else if (s[i] == '\t') {
            col += 4;
            i += 1;
        } else {
            break;
        }
    }

    return s[i..];
}

// Skip n columns of indentation and return number of bytes consumed
pub fn skipSpaces(s: []const u8, columns: usize) usize {
    var col: usize = 0;
    var i: usize = 0;

    while (i < s.len and col < columns) {
        if (s[i] == ' ') {
            col += 1;
            i += 1;
        } else if (s[i] == '\t') {
            col += 4;
            i += 1;
        } else {
            break;
        }
    }

    return i;
}

test "trim" {
    try std.testing.expectEqualStrings("hello", trim("  hello  "));
    try std.testing.expectEqualStrings("hello", trim("hello"));
    try std.testing.expectEqualStrings("", trim("   "));
}

test "countLeadingSpaces" {
    try std.testing.expectEqual(@as(usize, 3), countLeadingSpaces("   hello"));
    try std.testing.expectEqual(@as(usize, 0), countLeadingSpaces("hello"));
}

test "isBlankLine" {
    try std.testing.expect(isBlankLine("   "));
    try std.testing.expect(isBlankLine(""));
    try std.testing.expect(!isBlankLine("  a  "));
}

test "calculateIndentation" {
    try std.testing.expectEqual(@as(usize, 4), calculateIndentation("    hello"));
    try std.testing.expectEqual(@as(usize, 4), calculateIndentation("\thello"));
    try std.testing.expectEqual(@as(usize, 5), calculateIndentation(" \thello"));
}
