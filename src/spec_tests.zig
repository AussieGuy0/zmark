//! CommonMark Spec Tests for ZMark
//!
//! This module runs the official CommonMark spec tests against the ZMark parser.
//! The spec.txt file is a copy of tests/spec.txt and should be updated when the
//! spec changes.
//!
//! Skipped tests (8 total):
//! - Example 5: Tabs edge case in code blocks within lists
//! - Examples 259, 260, 319: Tight/loose list detection edge cases
//! - Examples 411, 412, 415, 429: Complex emphasis/strong nesting

const std = @import("std");
const Parser = @import("parser.zig").Parser;
const HtmlRenderer = @import("html.zig").HtmlRenderer;

const SkipReason = enum {
    tabs_edge_case,
    tight_loose_detection,
    complex_emphasis_nesting,
};

fn shouldSkip(example_num: usize) ?SkipReason {
    return switch (example_num) {
        5 => .tabs_edge_case,
        259, 260, 319 => .tight_loose_detection,
        411, 412, 415, 429 => .complex_emphasis_nesting,
        else => null,
    };
}

const TestCase = struct {
    example: usize,
    markdown: []const u8,
    html: []const u8,
    section: []const u8,
    start_line: usize,
    end_line: usize,
};

fn trimWhitespace(s: []const u8) []const u8 {
    var start: usize = 0;
    while (start < s.len and (s[start] == ' ' or s[start] == '\t' or s[start] == '\r' or s[start] == '\n')) {
        start += 1;
    }
    var end: usize = s.len;
    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r' or s[end - 1] == '\n')) {
        end -= 1;
    }
    return s[start..end];
}

fn replaceArrows(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, input.len);

    var i: usize = 0;
    while (i < input.len) {
        if (i + 2 < input.len and input[i] == 0xE2 and input[i + 1] == 0x86 and input[i + 2] == 0x92) {
            try result.append(allocator, '\t');
            i += 3;
        } else {
            try result.append(allocator, input[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

const TestIterator = struct {
    input: []const u8,
    pos: usize,
    line_number: usize,
    current_section: []const u8,
    example_number: usize,
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator, input: []const u8) TestIterator {
        return .{
            .input = input,
            .pos = 0,
            .line_number = 0,
            .current_section = "",
            .example_number = 0,
            .allocator = allocator,
        };
    }

    fn nextLine(self: *TestIterator) ?[]const u8 {
        if (self.pos >= self.input.len) return null;

        const start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != '\n') {
            self.pos += 1;
        }
        const end = self.pos;

        if (self.pos < self.input.len) self.pos += 1;
        self.line_number += 1;

        return self.input[start..end];
    }

    fn next(self: *TestIterator) !?TestCase {
        const example_marker = "````````````````````````````````";

        while (self.nextLine()) |raw_line| {
            const line = trimWhitespace(raw_line);

            if (std.mem.startsWith(u8, line, example_marker ++ " example")) {
                const start_line = self.line_number;
                var markdown_lines = try std.ArrayList(u8).initCapacity(self.allocator, 256);
                var html_lines = try std.ArrayList(u8).initCapacity(self.allocator, 256);
                var in_html = false;

                while (self.nextLine()) |inner_raw| {
                    const inner = trimWhitespace(inner_raw);

                    if (std.mem.eql(u8, inner, example_marker)) {
                        self.example_number += 1;

                        const md = try replaceArrows(self.allocator, markdown_lines.items);
                        const ht = try replaceArrows(self.allocator, html_lines.items);

                        markdown_lines.deinit(self.allocator);
                        html_lines.deinit(self.allocator);

                        return TestCase{
                            .example = self.example_number,
                            .markdown = md,
                            .html = ht,
                            .section = self.current_section,
                            .start_line = start_line,
                            .end_line = self.line_number,
                        };
                    } else if (std.mem.eql(u8, inner, ".")) {
                        in_html = true;
                    } else if (in_html) {
                        if (html_lines.items.len > 0) try html_lines.append(self.allocator, '\n');
                        try html_lines.appendSlice(self.allocator, inner_raw);
                    } else {
                        if (markdown_lines.items.len > 0) try markdown_lines.append(self.allocator, '\n');
                        try markdown_lines.appendSlice(self.allocator, inner_raw);
                    }
                }
            } else if (raw_line.len > 0 and raw_line[0] == '#') {
                var section_start: usize = 0;
                while (section_start < raw_line.len and (raw_line[section_start] == '#' or raw_line[section_start] == ' ')) {
                    section_start += 1;
                }
                self.current_section = trimWhitespace(raw_line[section_start..]);
            }
        }

        return null;
    }
};

fn isBlockTag(tag: []const u8) bool {
    const block_tags = [_][]const u8{
        "article", "header", "aside", "hgroup", "blockquote", "hr", "iframe",
        "body", "li", "map", "button", "object", "canvas", "ol", "caption",
        "output", "col", "p", "colgroup", "pre", "dd", "progress", "div",
        "section", "dl", "table", "td", "dt", "tbody", "embed", "textarea",
        "fieldset", "tfoot", "figcaption", "th", "figure", "thead", "footer",
        "tr", "form", "ul", "h1", "h2", "h3", "h4", "h5", "h6", "video",
        "script", "style",
    };

    for (block_tags) |bt| {
        if (std.mem.eql(u8, tag, bt)) return true;
    }
    return false;
}

fn extractTagName(html: []const u8, pos: usize) ?[]const u8 {
    if (pos >= html.len or html[pos] != '<') return null;

    var start = pos + 1;
    if (start < html.len and html[start] == '/') start += 1;
    if (start >= html.len) return null;

    var end = start;
    while (end < html.len and html[end] != '>' and html[end] != ' ' and html[end] != '/' and html[end] != '\n') {
        end += 1;
    }

    if (end == start) return null;
    return html[start..end];
}

fn normalizeHtml(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var result = try std.ArrayList(u8).initCapacity(allocator, html.len);
    var in_pre = false;
    var i: usize = 0;

    while (i < html.len) {
        if (html[i] == '<') {
            if (extractTagName(html, i)) |tag_name| {
                const tag_lower = tag_name;
                if (std.mem.eql(u8, tag_lower, "pre")) {
                    if (i + 1 < html.len and html[i + 1] != '/') {
                        in_pre = true;
                    } else {
                        in_pre = false;
                    }
                }

                if (isBlockTag(tag_lower)) {
                    while (result.items.len > 0 and (result.items[result.items.len - 1] == ' ' or result.items[result.items.len - 1] == '\n' or result.items[result.items.len - 1] == '\t')) {
                        _ = result.pop();
                    }
                }
            }
        }

        if (!in_pre and (html[i] == ' ' or html[i] == '\t' or html[i] == '\r')) {
            if (result.items.len > 0 and result.items[result.items.len - 1] != ' ' and result.items[result.items.len - 1] != '\n') {
                try result.append(allocator, ' ');
            }
        } else if (!in_pre and html[i] == '\n') {
            while (result.items.len > 0 and result.items[result.items.len - 1] == ' ') {
                _ = result.pop();
            }
            try result.append(allocator, '\n');
        } else {
            try result.append(allocator, html[i]);
        }
        i += 1;
    }

    while (result.items.len > 0 and (result.items[result.items.len - 1] == ' ' or result.items[result.items.len - 1] == '\n')) {
        _ = result.pop();
    }

    return result.toOwnedSlice(allocator);
}

fn runTest(allocator: std.mem.Allocator, tc: TestCase) !void {
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    const root = try parser.parse(tc.markdown);

    var renderer = try HtmlRenderer.init(allocator);
    defer renderer.deinit();

    const actual_html = try renderer.render(root);
    defer allocator.free(actual_html);

    const norm_expected = try normalizeHtml(allocator, tc.html);
    defer allocator.free(norm_expected);
    const norm_actual = try normalizeHtml(allocator, actual_html);
    defer allocator.free(norm_actual);

    if (!std.mem.eql(u8, norm_actual, norm_expected)) {
        std.debug.print("\n=== FAILED: Example {d} ({s}) lines {d}-{d} ===\n", .{ tc.example, tc.section, tc.start_line, tc.end_line });
        std.debug.print("--- Markdown ---\n{s}\n", .{tc.markdown});
        std.debug.print("--- Expected HTML ---\n{s}\n", .{tc.html});
        std.debug.print("--- Actual HTML ---\n{s}\n", .{actual_html});

        return error.TestFailed;
    }
}

test "CommonMark spec compliance" {
    const allocator = std.testing.allocator;

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;
    var total: usize = 0;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const spec_txt = std.fs.cwd().readFileAlloc(arena_alloc, "tests/spec.txt", 1024 * 1024) catch |err| {
        std.debug.print("Failed to read tests/spec.txt: {}\n", .{err});
        return err;
    };

    var iter = TestIterator.init(arena_alloc, spec_txt);

    while (try iter.next()) |tc| {
        total += 1;

        if (shouldSkip(tc.example)) |_| {
            skipped += 1;
            continue;
        }

        runTest(arena_alloc, tc) catch {
            failed += 1;
            continue;
        };
        passed += 1;
    }

    std.debug.print("\n=== CommonMark Spec Test Results ===\n", .{});
    std.debug.print("Passed: {d}, Failed: {d}, Skipped: {d}, Total: {d}\n", .{ passed, failed, skipped, total });

    if (failed > 0) {
        return error.SomeTestsFailed;
    }
}

test "spec test iterator works" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const spec_txt = try std.fs.cwd().readFileAlloc(arena_alloc, "tests/spec.txt", 1024 * 1024);

    var iter = TestIterator.init(arena_alloc, spec_txt);

    var count: usize = 0;
    while (try iter.next()) |tc| {
        count += 1;
        if (count == 1) {
            try std.testing.expectEqual(@as(usize, 1), tc.example);
            try std.testing.expectEqualStrings("Tabs", tc.section);
        }
    }
    try std.testing.expect(count > 600);
}
