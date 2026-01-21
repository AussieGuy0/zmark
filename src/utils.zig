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
            // Tab advances to next column that is a multiple of 4
            const spaces_to_add = 4 - (indent % 4);
            indent += spaces_to_add;
        } else {
            break;
        }
    }
    return indent;
}

// Skip n columns of indentation (handling tabs).
// This version doesn't allocate - it returns a slice of the original string.
// WARNING: If a tab is partially consumed, this will lose the unconsumed spaces!
// Only use this for contexts where partial tabs don't matter.
pub fn skipIndentation(s: []const u8, columns: usize) []const u8 {
    var col: usize = 0;
    var i: usize = 0;

    while (i < s.len and col < columns) {
        if (s[i] == ' ') {
            col += 1;
            i += 1;
        } else if (s[i] == '\t') {
            // Tab advances to next multiple of 4
            const spaces_to_add = 4 - (col % 4);
            col += spaces_to_add;
            i += 1;
        } else {
            break;
        }
    }

    return s[i..];
}

// Skip n columns of indentation, properly handling partial tabs by allocating
// Returns: slice (potentially allocated), whether it was allocated, partially consumed tab spaces
pub fn skipIndentationAlloc(allocator: std.mem.Allocator, s: []const u8, columns: usize) !struct { content: []const u8, allocated: bool, partial_tab_spaces: usize } {
    var col: usize = 0;
    var i: usize = 0;
    var partial_tab_spaces: usize = 0;

    while (i < s.len and col < columns) {
        if (s[i] == ' ') {
            col += 1;
            i += 1;
        } else if (s[i] == '\t') {
            // Tab advances to next multiple of 4
            const spaces_to_add = 4 - (col % 4);
            if (col + spaces_to_add <= columns) {
                // Consume the entire tab
                col += spaces_to_add;
                i += 1;
            } else {
                // Partially consume the tab
                const consumed = columns - col;
                partial_tab_spaces = spaces_to_add - consumed;
                col = columns;
                i += 1;

                // Need to prepend spaces for unconsumed part of tab
                const remaining = s[i..];
                var result = try std.ArrayList(u8).initCapacity(allocator, partial_tab_spaces + remaining.len);
                var j: usize = 0;
                while (j < partial_tab_spaces) : (j += 1) {
                    try result.append(allocator, ' ');
                }
                try result.appendSlice(allocator, remaining);
                return .{ .content = try result.toOwnedSlice(allocator), .allocated = true, .partial_tab_spaces = partial_tab_spaces };
            }
        } else {
            break;
        }
    }

    return .{ .content = s[i..], .allocated = false, .partial_tab_spaces = partial_tab_spaces };
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
            // Tab advances to next multiple of 4
            const spaces_to_add = 4 - (col % 4);
            col += spaces_to_add;
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
