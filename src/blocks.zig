const std = @import("std");
const Node = @import("node.zig").Node;
const NodeType = @import("node.zig").NodeType;
const ListData = @import("node.zig").ListData;
const ListType = @import("node.zig").ListType;
const RefDef = @import("node.zig").RefDef;
const utils = @import("utils.zig");
const scanner = @import("scanner.zig");
const entities = @import("entities.zig");

pub const BlockParser = struct {
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    lines: std.ArrayList([]const u8),
    line_number: usize,
    offset: usize,
    column: usize,
    tip: *Node,
    root: *Node,
    last_matched_container: *Node,
    in_fenced_code: bool,
    fence_char: u8,
    fence_length: usize,
    fence_indent: usize,
    in_html_block: bool,
    html_block_type: u8,
    refmap: std.StringHashMap(RefDef),
    // State for tracking partial link reference definitions
    partial_refdef: ?PartialRefDef,
    // Store the original line with indentation (before stripping)
    current_line_remaining: []const u8,
    // Store the completely original line (before any processing)
    current_line_original: []const u8,
    // Track if current line is a lazy continuation (no container markers)
    is_lazy_continuation: bool,
    // Track if we've seen a blank line at the list level (between items)
    blank_line_before_next_item: bool,

    const PartialRefDef = struct {
        label: []const u8,
        url: ?[]const u8,
        title: ?[]const u8,
        title_delimiter: u8,
        expecting: enum { label_continuation, url, title_or_end, title_continuation, end },
        accumulated: std.ArrayList(u8),
        // Track consumed lines so we can output them if refdef is invalid
        consumed_lines: std.ArrayList([]const u8),
    };

    pub fn init(allocator: std.mem.Allocator, arena_allocator: std.mem.Allocator, root: *Node) !BlockParser {
        return BlockParser{
            .allocator = allocator,
            .arena_allocator = arena_allocator,
            // Important: don't allocate a backing buffer here.
            // `parse()` assigns `self.lines = splitLines(...)`, and we don't want to leak
            // an initial buffer by overwriting it without deinit.
            .lines = .{},
            .line_number = 0,
            .offset = 0,
            .column = 0,
            .tip = root,
            .root = root,
            .last_matched_container = root,
            .in_fenced_code = false,
            .fence_char = 0,
            .fence_length = 0,
            .fence_indent = 0,
            .in_html_block = false,
            .html_block_type = 0,
            .refmap = std.StringHashMap(RefDef).init(allocator),
            .partial_refdef = null,
            .current_line_remaining = "",
            .current_line_original = "",
            .is_lazy_continuation = false,
            .blank_line_before_next_item = false,
        };
    }

    pub fn deinit(self: *BlockParser) void {
        // Free the lines array
        self.lines.deinit(self.allocator);
        // Free the reference map
        self.refmap.deinit();
        // Free partial refdef if present
        if (self.partial_refdef) |*partial| {
            partial.accumulated.deinit(self.allocator);
            partial.consumed_lines.deinit(self.allocator);
        }
    }

    pub fn parse(self: *BlockParser, input: []const u8) !void {
        // Normalize line endings and split into lines
        const normalized = try scanner.normalizeLineEndings(self.allocator, input);
        defer self.allocator.free(normalized);

        self.lines = try scanner.splitLines(self.allocator, normalized);

        // Process each line
        for (self.lines.items) |line| {
            self.line_number += 1;
            try self.incorporateLine(line);
        }

        // Finalize any partial link reference definition
        if (self.partial_refdef) |*partial| {
            if (partial.url != null) {
                try self.finalizePartialRefDef();
            } else {
                try self.abandonPartialRefDef();
            }
        }

        // Finalize all code blocks (trim trailing newlines)
        try self.finalizeCodeBlocks(self.root);

        // Close all open blocks
        while (self.tip != self.root) {
            self.tip = self.tip.parent.?;
        }
    }

    fn incorporateLine(self: *BlockParser, line: []const u8) !void {
        self.offset = 0;
        self.column = 0;
        self.is_lazy_continuation = false; // Reset at start of each line
        self.current_line_original = line; // Store original line for refdef tracking

        const is_blank = utils.isBlankLine(line);

        // Check if line is blank
        if (is_blank) {
            // Blank lines within fenced code blocks are preserved and handled later
            // Blank lines within indented code blocks need container matching first
            // to determine if they're still within the same containers

            // Blank line terminates any partial link reference definition
            if (self.partial_refdef) |*partial| {
                // Blank lines are not allowed within titles
                if (partial.expecting == .title_continuation) {
                    // Invalid - title can't span blank lines
                    try self.abandonPartialRefDef();
                } else if (partial.url != null) {
                    // Finalize if we have at least a URL
                    try self.finalizePartialRefDef();
                } else {
                    // Invalid partial refdef, discard it
                    try self.abandonPartialRefDef();
                }
            }

            // Blank line closes paragraph
            if (self.tip.type == .paragraph) {
                self.tip = self.tip.parent.?;
            }

            // Blank line also closes block quote
            if (self.tip.type == .block_quote) {
                self.tip = self.tip.parent.?;
            }

            // Mark empty list items as having seen a blank line
            if (self.tip.type == .list_item and self.tip.is_empty_item) {
                self.tip.seen_blank_after_item = true;
            }

            // Mark list items with trailing blanks
            // But NOT if we're in a fenced code block (those blanks don't count)
            if (!self.in_fenced_code) {
                // Walk up the tree and mark ALL ancestor list items
                // This handles nested lists correctly
                var ancestor = self.tip;
                while (ancestor != self.root) {
                    if (ancestor.type == .list_item) {
                        ancestor.has_trailing_blank = true;
                    }
                    ancestor = ancestor.parent orelse break;
                }
            }
        }

        // Match existing containers (block quotes, list items)
        // Build a path from root to tip
        var path = try std.ArrayList(*Node).initCapacity(self.allocator, 10);
        defer path.deinit(self.allocator);

        var node = self.tip;
        while (node != self.root) {
            try path.append(self.allocator, node);
            node = node.parent.?;
        }

        // Reverse to get root-to-tip order
        std.mem.reverse(*Node, path.items);

        // Try to match each container on the path
        var current_offset: usize = 0;
        var current_column: usize = 0;
        var matched_container = self.root;

        for (path.items) |container| {
            const matched = try self.matchContainer(container, line, &current_offset, &current_column, is_blank);
            if (!matched) break;
            matched_container = container;
        }

        // Calculate the actual column position where remaining content starts
        // This accounts for tabs in the consumed portion
        var actual_column: usize = 0;
        for (line[0..current_offset]) |ch| {
            if (ch == '\t') {
                actual_column += 4 - (actual_column % 4);
            } else {
                actual_column += 1;
            }
        }

        // If we consumed partial tabs, we need to prepend spaces for the unused portion
        const partial_tab_spaces = if (actual_column > current_column) actual_column - current_column else 0;

        // The column offset for indentation processing
        // After prepending spaces, content effectively starts at (actual_column - partial_tab_spaces)
        const content_column = if (partial_tab_spaces > 0) actual_column - partial_tab_spaces else actual_column;

        // Store the column for use in indentation processing
        self.column = content_column;

        // Close unmatched containers
        while (self.tip != matched_container) {
            // If we're closing a fenced code block, update the flag
            if (self.tip.type == .code_block and self.in_fenced_code) {
                self.in_fenced_code = false;
            }
            // If we're closing an HTML block, update the flag
            if (self.tip.type == .html_block and self.in_html_block) {
                self.in_html_block = false;
            }
            self.tip = self.tip.parent.?;
        }

        self.last_matched_container = matched_container;

        // Track blank lines at list level (between items) - makes list loose
        // This must be after closing unmatched containers
        if (is_blank and self.tip.type == .list) {
            self.blank_line_before_next_item = true;
        }

        // Get remaining line content after container markers
        var remaining = if (current_offset < line.len) line[current_offset..] else "";

        // If we consumed partial tabs, prepend spaces for the unused portion
        // but keep the rest of the content (including tabs) intact
        if (partial_tab_spaces > 0 and remaining.len > 0) {
            var buffer = try std.ArrayList(u8).initCapacity(self.arena_allocator, partial_tab_spaces + remaining.len);
            var i: usize = 0;
            while (i < partial_tab_spaces) : (i += 1) {
                try buffer.append(self.arena_allocator, ' ');
            }
            try buffer.appendSlice(self.arena_allocator, remaining);
            remaining = try buffer.toOwnedSlice(self.arena_allocator);
        }

        // If we're in an HTML block, handle it after matching containers
        if (self.in_html_block) {
            try self.addToHtmlBlock(remaining);
            if (self.checkHtmlBlockEnd(remaining)) {
                self.in_html_block = false;
                self.tip = self.tip.parent.?;
            }
            return;
        }

        // If we're in a fenced code block, handle it after matching containers
        if (self.in_fenced_code) {
            if (try self.checkClosingFence(remaining)) {
                self.in_fenced_code = false;
                self.tip = self.tip.parent.?;
                return;
            }
            // Add line to fenced code block (use remaining after container matching)
            try self.addToFencedCodeBlock(remaining);
            return;
        }

        // Don't process blank lines further (but add them to indented code blocks if still inside one)
        if (is_blank) {
            if (self.tip.type == .code_block and !self.in_fenced_code) {
                // Still in an indented code block after container matching - add blank line
                try self.addToCodeBlock(line);
            }
            return;
        }

        // Store the remaining line before stripping indentation
        self.current_line_remaining = remaining;

        // Check indentation of remaining content
        const indent = utils.calculateIndentation(remaining);

        // Determine if we're in a list item (walk up the tree)
        var in_list_item = false;
        var check_node = self.tip;
        while (check_node != self.root) {
            if (check_node.type == .list_item) {
                in_list_item = true;
                break;
            }
            check_node = check_node.parent.?;
        }

        // Track how much indentation we're going to strip
        const indent_to_strip = if (!in_list_item) @min(indent, 3) else 0;

        // Only strip up to 3 spaces of indentation if NOT in a list item
        const content = if (indent_to_strip > 0)
            utils.skipIndentation(remaining, indent_to_strip)
        else
            remaining;

        // Store the stripped indent for use by parseListItem
        self.offset = current_offset + indent_to_strip;

        // If we're in a code block but line is not indented enough, close it
        if (self.tip.type == .code_block and indent < 4) {
            // Trim trailing newlines from code block literal
            if (self.tip.literal) |lit| {
                var end = lit.len;
                // Remove all trailing newlines
                while (end > 0 and lit[end - 1] == '\n') {
                    end -= 1;
                }
                self.tip.literal = lit[0..end];
            }
            self.tip = self.tip.parent.?;
        }

        // If we're in a list but not in a list item, we need to check if this line
        // can start a new list item. If not, close the list.
        if (self.tip.type == .list) {
            // Check if content starts a list item
            const looks_like_list = blk: {
                if (content.len == 0) break :blk false;
                const ch = content[0];
                // Check for bullet list markers
                if (ch == '-' or ch == '+' or ch == '*') {
                    // Empty list item (just the marker)
                    if (content.len == 1) break :blk true;
                    // List item with content (marker + space/tab)
                    if (content.len >= 2 and (content[1] == ' ' or content[1] == '\t')) break :blk true;
                }
                // Check for ordered list markers
                if (ch >= '0' and ch <= '9') {
                    var i: usize = 1;
                    while (i < content.len and content[i] >= '0' and content[i] <= '9') : (i += 1) {}
                    if (i < content.len and (content[i] == '.' or content[i] == ')')) {
                        // Empty list item (just marker and delimiter)
                        if (i + 1 >= content.len) break :blk true;
                        // List item with content (marker + delimiter + space/tab)
                        if (i + 1 < content.len and (content[i + 1] == ' ' or content[i + 1] == '\t')) {
                            break :blk true;
                        }
                    }
                }
                break :blk false;
            };

            if (!looks_like_list) {
                self.tip = self.tip.parent.?;
            }
        }

        // Indented code block (4+ spaces and not in paragraph)
        if (indent >= 4 and self.tip.type != .paragraph and self.partial_refdef == null) {
            // Pass remaining (not content) so addToCodeBlock can remove the correct amount
            try self.addToCodeBlock(remaining);
            return;
        }

        // Process the line content
        try self.processLineContent(content);
    }

    fn looksLikeStructuralElement(line: []const u8) bool {
        // Check if line looks like it would start a structural element
        // This is a simplified check for common cases

        // Strip up to 3 spaces of indentation
        const indent_count = utils.calculateIndentation(line);
        const content = if (indent_count <= 3) utils.skipIndentation(line, @min(indent_count, 3)) else line;
        if (content.len == 0) return false;

        const ch = content[0];

        // Thematic break: ---, ***, ___
        if (ch == '-' or ch == '*' or ch == '_') {
            var count: usize = 0;
            for (content) |c| {
                if (c == ch) {
                    count += 1;
                } else if (c != ' ' and c != '\t') {
                    break;
                }
            }
            if (count >= 3) return true; // Likely thematic break
        }

        // ATX heading: #
        if (ch == '#') {
            return true;
        }

        // List items: -, +, *, or digits followed by . or )
        if (ch == '-' or ch == '+' or ch == '*') {
            // Empty list item (just marker, no space)
            if (content.len == 1) return true;
            // Regular list item (marker + space)
            if (content.len >= 2 and (content[1] == ' ' or content[1] == '\t')) {
                return true;
            }
        }
        if (ch >= '0' and ch <= '9') {
            var i: usize = 1;
            while (i < content.len and content[i] >= '0' and content[i] <= '9') : (i += 1) {}
            if (i < content.len and (content[i] == '.' or content[i] == ')')) {
                // Empty list item (just number + delimiter)
                if (i + 1 >= content.len) return true;
                // Regular list item (number + delimiter + space)
                if (i + 1 < content.len and (content[i + 1] == ' ' or content[i + 1] == '\t')) {
                    return true;
                }
            }
        }

        // Block quote: >
        if (ch == '>') {
            return true;
        }

        // Fenced code block: ``` or ~~~
        if (ch == '`' or ch == '~') {
            var count: usize = 0;
            for (content) |c| {
                if (c == ch) {
                    count += 1;
                } else {
                    break;
                }
            }
            if (count >= 3) return true;
        }

        // HTML block: <
        if (ch == '<') {
            return true;
        }

        return false;
    }

    fn matchContainer(self: *BlockParser, container: *Node, line: []const u8, offset: *usize, column: *usize, is_blank: bool) !bool {
        switch (container.type) {
            .block_quote => {
                // Blank lines don't match block quotes (they close them)
                if (is_blank) return false;

                // Save offset and column before skipping spaces (in case of lazy continuation)
                const saved_offset = offset.*;
                const saved_column = column.*;

                // Skip up to 3 spaces
                const indent = utils.calculateIndentation(line[offset.*..]);
                const to_skip = @min(indent, 3);
                const bytes_skipped = utils.skipSpaces(line[offset.*..], to_skip);
                offset.* += bytes_skipped;
                column.* += to_skip;

                if (offset.* >= line.len or line[offset.*] != '>') {
                    // No '>' marker - check if we can do lazy continuation
                    // Lazy continuation only works if we're currently in a paragraph
                    // and the line doesn't look like a structural element
                    if (self.tip.type == .paragraph) {
                        // Check if line looks like a structural element that would interrupt the paragraph
                        // Use the saved offset to check the original line content
                        const remaining_line = if (saved_offset < line.len) line[saved_offset..] else "";
                        if (looksLikeStructuralElement(remaining_line)) {
                            offset.* = saved_offset; // Restore offset before failing
                            column.* = saved_column;
                            return false;
                        }

                        var check = self.tip.parent;
                        while (check) |node| {
                            if (node == container) {
                                // We're in a paragraph inside this block quote
                                // Allow lazy continuation (don't consume anything - restore offset)
                                offset.* = saved_offset;
                                column.* = saved_column;
                                self.is_lazy_continuation = true;
                                return true;
                            }
                            check = node.parent;
                        }
                    }
                    // No lazy continuation possible - restore offset and fail
                    offset.* = saved_offset;
                    column.* = saved_column;
                    return false;
                }

                // Consume '>'
                offset.* += 1;
                column.* += 1;

                // Consume optional space after '>'
                // Per CommonMark spec: "the character > together with a following optional space of indentation"
                // For tabs, we consume 1 column worth but don't consume the tab byte itself
                // (partial tab handling is done later in content processing)
                if (offset.* < line.len) {
                    if (line[offset.*] == ' ') {
                        offset.* += 1;
                        column.* += 1;
                    } else if (line[offset.*] == '\t') {
                        // Consume 1 column from the tab, but don't consume the tab byte
                        // The remaining columns from the tab will be handled during content processing
                        column.* += 1;
                    }
                }

                return true;
            },
            .list_item => {
                // Empty list items that have seen a blank line can't continue
                if (container.is_empty_item and container.seen_blank_after_item) {
                    return false;
                }

                // Blank lines always match list items (they can be part of the item)
                if (is_blank) return true;

                // Check if line is indented enough to be part of this list item
                const item_indent = container.indent;
                const line_indent = utils.calculateIndentationFrom(line[offset.*..], column.*);
                const absolute_indent = column.* + line_indent;

                if (absolute_indent >= item_indent) {
                    // Consume the required indentation (in columns, not bytes)
                    // We need to consume (item_indent - column.*) columns
                    // If we've already consumed more than needed, don't consume more
                    if (column.* < item_indent) {
                        const columns_to_consume = item_indent - column.*;
                        const skip_result = utils.skipSpacesFrom(line[offset.*..], columns_to_consume, column.*);
                        offset.* += skip_result.bytes_consumed;
                        column.* += skip_result.columns_consumed;
                    }
                    return true;
                }

                // Check for lazy continuation
                // Lazy continuation only works if we're currently in a paragraph
                // and the line doesn't look like a structural element
                if (self.tip.type == .paragraph) {
                    // Check if line looks like a structural element that would interrupt the paragraph
                    const remaining_line = if (offset.* < line.len) line[offset.*..] else "";
                    if (looksLikeStructuralElement(remaining_line)) {
                        return false;
                    }

                    var check = self.tip.parent;
                    while (check) |node| {
                        if (node == container) {
                            // We're in a paragraph inside this list item
                            // Allow lazy continuation (don't consume anything)
                            self.is_lazy_continuation = true;
                            return true;
                        }
                        check = node.parent;
                    }
                }

                return false;
            },
            .list => {
                // Lists always match (they're containers for list items)
                return true;
            },
            else => return true,
        }
    }

    fn processLineContent(self: *BlockParser, content: []const u8) anyerror!void {
        // Lazy continuation lines should just be added to the paragraph
        // Don't try to parse them as structural elements
        if (self.is_lazy_continuation) {
            try self.addTextToParagraph(content);
            return;
        }

        // Check if content is blank (after container markers have been stripped)
        const is_blank_content = utils.isBlankLine(content);

        if (is_blank_content) {
            // Blank line within a container - close paragraph if open
            if (self.tip.type == .paragraph) {
                self.tip = self.tip.parent.?;
            }
            // Mark list items with trailing blanks
            if (self.tip.type == .list_item) {
                self.tip.has_trailing_blank = true;
            }
            // Blank lines within code blocks are handled elsewhere
            return;
        }

        // Check for indented code block (4+ spaces and not in paragraph)
        const content_indent = utils.calculateIndentation(content);
        if (content_indent >= 4 and self.tip.type != .paragraph and self.partial_refdef == null) {
            try self.addToCodeBlock(content);
            return;
        }

        // If we have a partial link reference definition, try to continue it
        if (self.partial_refdef != null) {
            if (try self.continuePartialRefDef(content)) {
                return;
            }
        }

        // Try to match link reference definition (must be at start, not in paragraph)
        if (self.tip.type != .paragraph) {
            if (try self.parseLinkReferenceDefinition(content)) {
                return;
            }
        }

        // Try to match block quote
        if (try self.parseBlockQuote(content)) {
            return;
        }

        // Try to match HTML block (pass both stripped and original for indentation preservation)
        if (try self.parseHtmlBlock(content, self.current_line_remaining)) {
            return;
        }

        // Try to match fenced code block opening
        // Calculate the original indent from current_line_remaining
        const original_indent = utils.calculateIndentation(self.current_line_remaining);
        const fence_indent = @min(original_indent, 3); // We strip up to 3 spaces
        if (try self.parseFencedCodeBlock(content, fence_indent)) {
            return;
        }

        // Try to match ATX heading
        if (try self.parseAtxHeading(content)) {
            return;
        }

        // Try to match setext heading underline
        if (try self.parseSetextHeading(content)) {
            return;
        }

        // Try to match thematic break (before list, as - can be both)
        // Thematic breaks have higher precedence than lists per CommonMark spec
        if (try self.parseThematicBreak(content)) {
            return;
        }

        // Try to match list item
        if (try self.parseListItem(content)) {
            return;
        }

        // Default: add to paragraph
        try self.addTextToParagraph(content);
    }

    fn parseBlockQuote(self: *BlockParser, line: []const u8) anyerror!bool {
        if (line.len == 0 or line[0] != '>') return false;

        // Close paragraph if open
        if (self.tip.type == .paragraph) {
            self.tip = self.tip.parent.?;
        }

        self.markParentListAsLooseIfNeeded();

        // Create block quote
        const quote = try Node.create(self.arena_allocator, .block_quote);
        quote.start_line = self.line_number;
        self.tip.appendChild(quote);
        self.tip = quote;

        // Remove the > and optional following space (up to 1 column)
        // Use column-based skipping to handle tabs correctly
        const after_marker = line[1..];
        const skip_result = try utils.skipIndentationAllocFrom(self.arena_allocator, after_marker, 1, 1);
        const content = skip_result.content;

        // If content is now empty, just return
        if (content.len == 0) {
            return true;
        }

        // Update column position for recursive processing
        // We've consumed '>' (1 column) and up to 1 more column for optional space
        // The prepended spaces from partial tab consumption are part of the content now
        const saved_column = self.column;
        const columns_consumed = 2; // '>' plus optional space (1 column each)
        self.column = saved_column + columns_consumed;

        // Update current_line_remaining for recursive call
        const saved_line = self.current_line_remaining;
        self.current_line_remaining = content;

        // Process the rest of the line recursively
        try self.processLineContent(content);

        // Restore for safety (though it shouldn't matter)
        self.current_line_remaining = saved_line;
        self.column = saved_column;

        return true;
    }

    fn parseThematicBreak(self: *BlockParser, line: []const u8) !bool {
        // Thematic breaks can only have 0-3 spaces of indentation
        // Since we've already stripped up to 3 spaces in incorporateLine,
        // if there's ANY leading whitespace here, it means there were 4+ spaces
        if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
            return false;
        }

        const s = line;
        if (s.len == 0) return false;

        const ch = s[0];
        if (ch != '-' and ch != '*' and ch != '_') return false;

        var count: usize = 0;
        for (s) |c| {
            if (c == ch) {
                count += 1;
            } else if (c != ' ' and c != '\t') {
                return false;
            }
        }

        if (count >= 3) {
            // Close any open paragraph
            if (self.tip.type == .paragraph) {
                self.tip = self.tip.parent.?;
            }

            // Close any open list (thematic breaks can't be in lists)
            if (self.tip.type == .list) {
                self.tip = self.tip.parent.?;
            }

            self.markParentListAsLooseIfNeeded();

            // Create thematic break
            const hr = try Node.create(self.arena_allocator, .thematic_break);
            hr.start_line = self.line_number;
            hr.end_line = self.line_number;
            self.tip.appendChild(hr);
            return true;
        }

        return false;
    }

    fn parseSetextHeading(self: *BlockParser, line: []const u8) !bool {
        // Setext headings don't work via lazy continuation
        if (self.is_lazy_continuation) {
            return false;
        }

        // Setext heading underlines can only have 0-3 spaces of indentation
        // Since we've already stripped up to 3 spaces, if there's leading whitespace,
        // it means there were 4+ spaces
        if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
            return false;
        }

        const s = line;
        if (s.len == 0) return false;

        const ch = s[0];
        if (ch != '=' and ch != '-') return false;

        // Check if all characters are marker, followed by optional trailing whitespace
        // Once we see whitespace, we can only see whitespace (no more markers)
        var seen_whitespace = false;
        var has_marker = false;
        for (s) |c| {
            if (c == ch) {
                if (seen_whitespace) {
                    // Markers after whitespace are not allowed
                    return false;
                }
                has_marker = true;
            } else if (c == ' ' or c == '\t') {
                seen_whitespace = true;
            } else {
                // Invalid character
                return false;
            }
        }

        if (!has_marker) return false;

        // Convert last paragraph to heading
        if (self.tip.type == .paragraph) {
            const level: u8 = if (ch == '=') 1 else 2;
            self.tip.type = .heading;
            self.tip.heading_level = level;
            self.tip.end_line = self.line_number;
            self.tip = self.tip.parent.?;
            return true;
        }

        return false;
    }

    fn parseAtxHeading(self: *BlockParser, line: []const u8) !bool {
        // ATX headings can only have 0-3 spaces of indentation
        // Since we've already stripped up to 3 spaces, if there's leading whitespace,
        // it means there were 4+ spaces
        if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
            return false;
        }

        var s = line;
        if (s.len == 0 or s[0] != '#') return false;

        // Count leading # characters
        var level: usize = 0;
        for (s) |ch| {
            if (ch == '#') {
                level += 1;
            } else {
                break;
            }
        }

        if (level > 6) return false;

        // Must be followed by space or end of line
        if (level < s.len) {
            const next = s[level];
            if (next != ' ' and next != '\t') return false;
        }

        // Extract heading text
        var text = if (level < s.len) s[level..] else "";
        text = utils.trim(text);

        // Remove optional closing # sequence
        if (text.len > 0 and text[text.len - 1] == '#') {
            var end = text.len;
            while (end > 0 and text[end - 1] == '#') {
                end -= 1;
            }
            // Only remove if preceded by space (or if everything is #)
            if (end == 0) {
                // All # characters - remove them (they're the closing sequence)
                text = "";
            } else if (text[end - 1] == ' ' or text[end - 1] == '\t') {
                text = text[0..end];
                text = utils.trimRight(text);
            }
        }

        // Close any open paragraph
        if (self.tip.type == .paragraph) {
            self.tip = self.tip.parent.?;
        }

        self.markParentListAsLooseIfNeeded();

        // Create heading
        const heading = try Node.create(self.arena_allocator, .heading);
        heading.heading_level = @intCast(level);
        heading.start_line = self.line_number;
        heading.end_line = self.line_number;
        self.tip.appendChild(heading);

        // Add text content (inlines will be parsed later)
        if (text.len > 0) {
            const text_node = try Node.create(self.arena_allocator, .text);
            text_node.literal = try self.arena_allocator.dupe(u8, text);
            heading.appendChild(text_node);
        }

        return true;
    }

    fn markParentListAsLooseIfNeeded(self: *BlockParser) void {
        // Check if we're adding a second block-level element to a list item
        // that already has content and had a trailing blank - this makes the list loose
        if (self.tip.type == .list_item and self.tip.has_trailing_blank and self.tip.first_child != null) {
            // Find the parent list and mark it as loose
            if (self.tip.parent) |list| {
                if (list.type == .list and list.list_data != null) {
                    list.list_data.?.tight = false;
                }
            }
        }
    }

    fn addTextToParagraph(self: *BlockParser, line: []const u8) !void {
        // If tip is not a paragraph, create one
        if (self.tip.type != .paragraph) {
            self.markParentListAsLooseIfNeeded();

            const para = try Node.create(self.arena_allocator, .paragraph);
            para.start_line = self.line_number;
            self.tip.appendChild(para);
            self.tip = para;
        } else {
            // Add a softbreak between lines in the same paragraph
            if (self.tip.first_child != null) {
                const softbreak = try Node.create(self.arena_allocator, .softbreak);
                self.tip.appendChild(softbreak);
            }
        }

        // Add line to paragraph
        const text_node = try Node.create(self.arena_allocator, .text);
        const content = utils.trimLeft(line); // Trim leading but preserve trailing spaces
        text_node.literal = try self.arena_allocator.dupe(u8, content);
        self.tip.appendChild(text_node);

        // Update end line
        self.tip.end_line = self.line_number;
    }

    fn addToCodeBlock(self: *BlockParser, line: []const u8) !void {
        // If tip is not a code block, create one
        if (self.tip.type != .code_block) {
            self.markParentListAsLooseIfNeeded();

            const code = try Node.create(self.arena_allocator, .code_block);
            code.start_line = self.line_number;
            self.tip.appendChild(code);
            self.tip = code;
            code.literal = try self.arena_allocator.dupe(u8, "");
        }

        // Remove 4 spaces of indentation, accounting for column offset from container matching
        const result = try utils.skipIndentationAllocFrom(self.arena_allocator, line, 4, self.column);
        const content = result.content;

        // Append line to code block literal
        const current_literal = self.tip.literal orelse "";
        const new_literal = if (current_literal.len > 0)
            try std.fmt.allocPrint(self.arena_allocator, "{s}\n{s}", .{ current_literal, content })
        else
            try self.arena_allocator.dupe(u8, content);

        self.tip.literal = new_literal;
        self.tip.end_line = self.line_number;
    }

    fn parseFencedCodeBlock(self: *BlockParser, line: []const u8, indent: usize) !bool {
        // Can't have more than 3 spaces of indentation
        if (indent > 3) return false;

        const content = utils.skipIndentation(line, indent);
        if (content.len < 3) return false;

        const ch = content[0];
        if (ch != '`' and ch != '~') return false;

        // Count fence characters
        var fence_len: usize = 0;
        for (content) |c| {
            if (c == ch) {
                fence_len += 1;
            } else {
                break;
            }
        }

        if (fence_len < 3) return false;

        // Extract info string (everything after the fence)
        var info = content[fence_len..];

        // For backtick fences, info string cannot contain backticks
        if (ch == '`') {
            for (info) |c| {
                if (c == '`') return false;
            }
        }

        info = utils.trim(info);

        // Close any open paragraph
        if (self.tip.type == .paragraph) {
            self.tip = self.tip.parent.?;
        }

        self.markParentListAsLooseIfNeeded();

        // Create fenced code block
        const code = try Node.create(self.arena_allocator, .code_block);
        code.start_line = self.line_number;
        code.literal = null; // Will be set when first line is added

        // Store info string (with backslash escapes and entities processed)
        // Always set code_info for fenced code blocks (even if empty)
        // This allows us to distinguish fenced from indented code blocks
        if (info.len > 0) {
            const processed_info = try self.processEscapesAndEntities(info);
            code.code_info = processed_info;
        } else {
            code.code_info = "";
        }

        self.tip.appendChild(code);
        self.tip = code;

        // Track fence info
        self.in_fenced_code = true;
        self.fence_char = ch;
        self.fence_length = fence_len;
        self.fence_indent = indent;

        return true;
    }

    fn checkClosingFence(self: *BlockParser, line: []const u8) !bool {
        const indent = utils.calculateIndentation(line);

        // Can't be more indented than opening fence
        if (indent > self.fence_indent + 3) return false;

        const content = utils.skipIndentation(line, indent);
        if (content.len == 0) return false;

        const ch = content[0];
        if (ch != self.fence_char) return false;

        // Count fence characters
        var fence_len: usize = 0;
        for (content) |c| {
            if (c == ch) {
                fence_len += 1;
            } else if (c == ' ' or c == '\t') {
                // Spaces are allowed after closing fence
                continue;
            } else {
                // Other characters mean this is not a closing fence
                return false;
            }
        }

        // Closing fence must be at least as long as opening fence
        return fence_len >= self.fence_length;
    }

    fn addToFencedCodeBlock(self: *BlockParser, line: []const u8) !void {
        // For fenced code blocks, we don't remove indentation
        // Just append the line as-is (but remove up to fence_indent spaces)
        const indent = utils.calculateIndentation(line);
        const to_remove = @min(indent, self.fence_indent);
        const content = utils.skipIndentation(line, to_remove);

        // Append line to code block literal
        const current_literal = self.tip.literal;
        const new_literal = if (current_literal) |lit|
            try std.fmt.allocPrint(self.arena_allocator, "{s}\n{s}", .{ lit, content })
        else
            try self.arena_allocator.dupe(u8, content);

        self.tip.literal = new_literal;
        self.tip.end_line = self.line_number;
    }

    fn parseListItem(self: *BlockParser, line: []const u8) !bool {
        if (line.len == 0) return false;

        const ch = line[0];
        var marker_end: usize = 0;
        var marker_type: ListType = undefined;
        var bullet_char: u8 = 0;
        var delimiter: u8 = 0;
        var start_num: u32 = 1;
        var is_empty: bool = false;

        // Check for unordered list marker: -, +, or *
        if (ch == '-' or ch == '+' or ch == '*') {
            // Must be followed by at least one space/tab, or end of line
            if (line.len >= 2) {
                if (line[1] != ' ' and line[1] != '\t') return false;
            } else {
                // line.len == 1, it's just the marker (empty list item)
                is_empty = true;
            }

            marker_type = .bullet;
            bullet_char = ch;
            marker_end = 1;
        }
        // Check for ordered list marker: digits followed by . or )
        else if (ch >= '0' and ch <= '9') {
            var num_end: usize = 0;
            var num_val: u32 = 0;
            for (line, 0..) |c, i| {
                if (c >= '0' and c <= '9') {
                    num_val = num_val * 10 + (c - '0');
                    num_end = i + 1;
                    // Per CommonMark spec, start numbers must be <= 999999999
                    if (num_val > 999999999) return false;
                } else {
                    break;
                }
            }

            if (num_end == 0 or num_end >= line.len) return false;

            const delim = line[num_end];
            if (delim != '.' and delim != ')') return false;

            // Must be followed by at least one space/tab, or end of line
            if (num_end + 1 < line.len) {
                const after = line[num_end + 1];
                if (after != ' ' and after != '\t') return false;
            } else {
                // num_end + 1 >= line.len, it's just the marker (empty list item)
                is_empty = true;
            }

            marker_type = .ordered;
            delimiter = delim;
            start_num = num_val;
            marker_end = num_end + 1;
        } else {
            return false;
        }

        // Empty list items cannot interrupt a paragraph
        if (is_empty and self.tip.type == .paragraph) {
            return false;
        }

        // Ordered lists can only interrupt a paragraph if they start with 1
        // Per CommonMark spec: "we allow only lists starting with `1` to interrupt paragraphs"
        if (marker_type == .ordered and start_num != 1 and self.tip.type == .paragraph) {
            return false;
        }

        // Calculate marker width and content indent
        const marker_width = marker_end + 1; // +1 for the required space

        // Skip the marker and the required space (up to 1 column)
        // Use column-based skipping to handle tabs correctly
        const after_marker = line[marker_end..];
        const skip_required = try utils.skipIndentationAllocFrom(self.arena_allocator, after_marker, 1, marker_end);
        var after_required = skip_required.content;

        // Count additional spaces/tabs after the required space
        var spaces_count: usize = 0;
        var temp_pos: usize = 0;
        while (temp_pos < after_required.len) {
            const c = after_required[temp_pos];
            if (c == ' ') {
                spaces_count += 1;
                temp_pos += 1;
            } else if (c == '\t') {
                // Tab counts as moving to next tab stop
                // We're now at column (marker_width + spaces_count), but need to account for partial tab
                const current_col = marker_width + spaces_count;
                spaces_count += 4 - (current_col % 4);
                temp_pos += 1;
                break;
            } else {
                break;
            }
        }

        // Determine how many spaces to actually consume
        // If there are 4+ spaces, it's an indented code block - don't consume the extra spaces
        // Otherwise, consume up to 3 additional spaces (N can be 1-4 total)
        var spaces_after_marker: usize = 0;
        var content: []const u8 = "";
        if (spaces_count >= 4) {
            // Leave all extra spaces for indented code block processing
            spaces_after_marker = 0;
            content = after_required;
        } else {
            // Consume these spaces (up to 3 additional)
            spaces_after_marker = spaces_count;
            content = if (temp_pos < after_required.len) after_required[temp_pos..] else "";
        }

        // Content indent calculation:
        // If there's no content on this line, use marker + 1 space as the required indentation
        // Otherwise, use marker + all spaces consumed (up to 4 after the required space)
        const content_indent = if (content.len == 0)
            self.offset + marker_width
        else
            self.offset + marker_width + @min(spaces_after_marker, 4);

        // Close paragraph if open
        if (self.tip.type == .paragraph) {
            self.tip = self.tip.parent.?;
        }

        self.markParentListAsLooseIfNeeded();

        // Create or find list
        var list_node: *Node = undefined;
        if (self.tip.type == .list) {
            // Check if previous item (last child) had trailing blanks
            var previous_item_had_trailing_blank = false;
            if (self.tip.last_child) |last_item| {
                if (last_item.type == .list_item and last_item.has_trailing_blank) {
                    previous_item_had_trailing_blank = true;
                }
            }

            const list_data = self.tip.list_data orelse return error.MissingListData;
            const matches = if (marker_type == .bullet)
                list_data.type == .bullet and list_data.bullet_char == bullet_char
            else
                list_data.type == .ordered and list_data.delimiter == delimiter;

            if (matches) {
                // Continue existing list
                list_node = self.tip;
                // If we saw a blank line before this item, make the list loose
                if (self.blank_line_before_next_item or previous_item_had_trailing_blank) {
                    list_node.list_data.?.tight = false;
                    self.blank_line_before_next_item = false;
                }
            } else {
                // Different list type, close and create new
                self.tip = self.tip.parent.?;
                list_node = try Node.create(self.arena_allocator, .list);
                list_node.start_line = self.line_number;
                list_node.list_data = ListData{
                    .type = marker_type,
                    .tight = true,
                    .bullet_char = bullet_char,
                    .delimiter = delimiter,
                    .start = start_num,
                    .padding = 1,
                };
                self.tip.appendChild(list_node);
                self.blank_line_before_next_item = false;
            }
        } else {
            // Create new list
            list_node = try Node.create(self.arena_allocator, .list);
            list_node.start_line = self.line_number;
            list_node.list_data = ListData{
                .type = marker_type,
                .tight = true,
                .bullet_char = bullet_char,
                .delimiter = delimiter,
                .start = start_num,
                .padding = 1,
            };
            self.tip.appendChild(list_node);
            self.blank_line_before_next_item = false;
        }

        // Create list item with proper indent
        const item = try Node.create(self.arena_allocator, .list_item);
        item.start_line = self.line_number;
        item.indent = content_indent;
        item.is_empty_item = (content.len == 0); // Mark as empty if no content on first line
        list_node.appendChild(item);
        self.tip = item;

        // Add content if present
        if (content.len > 0) {
            // Update column position for recursive processing
            // We've consumed the marker + required space + any additional spaces
            // The partial_tab_spaces are prepended to content, so they don't reduce columns consumed
            const saved_column = self.column;
            const columns_consumed = marker_width + spaces_after_marker;
            self.column = saved_column + columns_consumed;

            // Update current_line_remaining for recursive call
            const saved_line = self.current_line_remaining;
            self.current_line_remaining = content;

            // Process the content through normal block parsing
            // This allows headings, nested lists, block quotes, etc. to be recognized
            try self.processLineContent(content);

            // Restore for safety (though it shouldn't matter)
            self.current_line_remaining = saved_line;
            self.column = saved_column;
        }

        return true;
    }

    fn parseHtmlBlock(self: *BlockParser, line: []const u8, original_line: []const u8) !bool {
        if (line.len == 0 or line[0] != '<') return false;

        // Detect HTML block type using stripped line
        const html_type = detectHtmlBlockType(line);
        if (html_type == 0) return false;

        // Type 7 HTML blocks cannot interrupt a paragraph
        if (html_type == 7 and self.tip.type == .paragraph) {
            return false;
        }

        // Close paragraph if open (types 1-6 can interrupt)
        if (self.tip.type == .paragraph) {
            self.tip = self.tip.parent.?;
        }

        self.markParentListAsLooseIfNeeded();

        // Create HTML block - use original line to preserve indentation
        const html_block = try Node.create(self.arena_allocator, .html_block);
        html_block.start_line = self.line_number;
        html_block.literal = try self.arena_allocator.dupe(u8, original_line);
        self.tip.appendChild(html_block);
        self.tip = html_block;

        self.in_html_block = true;
        self.html_block_type = html_type;

        // Check if block ends on same line (use stripped version for detection)
        if (self.checkHtmlBlockEnd(line)) {
            self.in_html_block = false;
            self.tip = self.tip.parent.?;
        }

        return true;
    }

    fn detectHtmlBlockType(line: []const u8) u8 {
        if (line.len < 2) return 0;

        // Type 1: <script, <pre, <style, <textarea (case-insensitive)
        if (startsWithTag(line, "script") or startsWithTag(line, "pre") or
            startsWithTag(line, "style") or startsWithTag(line, "textarea")) {
            return 1;
        }

        // Type 2: <!--
        if (line.len >= 4 and std.mem.startsWith(u8, line, "<!--")) {
            return 2;
        }

        // Type 3: <?
        if (line.len >= 2 and std.mem.startsWith(u8, line, "<?")) {
            return 3;
        }

        // Type 4: <!X where X is uppercase letter
        if (line.len >= 3 and line[0] == '<' and line[1] == '!') {
            if (line[2] >= 'A' and line[2] <= 'Z') {
                return 4;
            }
        }

        // Type 5: <![CDATA[
        if (line.len >= 9 and std.mem.startsWith(u8, line, "<![CDATA[")) {
            return 5;
        }

        // Type 6: Block-level tags (simplified check)
        const block_tags = [_][]const u8{
            "address", "article", "aside", "base", "basefont", "blockquote", "body",
            "caption", "center", "col", "colgroup", "dd", "details", "dialog", "dir",
            "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form",
            "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header",
            "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem",
            "nav", "noframes", "ol", "optgroup", "option", "p", "param", "section",
            "source", "summary", "table", "tbody", "td", "tfoot", "th", "thead",
            "title", "tr", "track", "ul",
        };

        for (block_tags) |tag| {
            if (startsWithTag(line, tag) or startsWithClosingTag(line, tag)) {
                return 6;
            }
        }

        // Type 7: Complete opening or closing tag
        // Must be a complete open tag (not just a tag name, must have > and be on its own line)
        if (isCompleteHTMLTag(line)) {
            return 7;
        }

        return 0;
    }

    fn isCompleteHTMLTag(line: []const u8) bool {
        // Must start with <
        if (line.len == 0 or line[0] != '<') return false;

        // Check for closing tag
        if (line.len >= 2 and line[1] == '/') {
            var i: usize = 2;
            // Tag name must start with letter
            if (i >= line.len or !isAlpha(line[i])) return false;
            i += 1;

            // Continue tag name (letters, digits, hyphens)
            while (i < line.len and (isAlphaNum(line[i]) or line[i] == '-')) : (i += 1) {}

            // Skip whitespace
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

            // Must end with >
            if (i >= line.len or line[i] != '>') return false;
            i += 1;

            // Rest of line must be whitespace
            while (i < line.len) : (i += 1) {
                if (line[i] != ' ' and line[i] != '\t' and line[i] != '\n') {
                    return false;
                }
            }
            return true;
        }

        // Check for opening tag
        var i: usize = 1;
        // Tag name must start with letter
        if (i >= line.len or !isAlpha(line[i])) return false;
        i += 1;

        // Continue tag name (only letters, digits, hyphens allowed)
        while (i < line.len and (isAlphaNum(line[i]) or line[i] == '-')) : (i += 1) {}

        // After tag name, we need either whitespace, /, or >
        // If we see : or + or @ here, it's likely an autolink, not an HTML tag
        if (i < line.len) {
            const ch = line[i];
            if (ch == ':' or ch == '+' or ch == '.' or ch == '@') {
                return false; // This is an autolink like <http://...>, <foo@bar.com>, not an HTML tag
            }
        }

        // Parse attributes with proper validation
        // Note: HTML tags can span multiple lines (newlines count as whitespace)
        while (i < line.len) {
            const whitespace_start = i;
            // Skip whitespace (including newlines per CommonMark spec)
            while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\n')) : (i += 1) {}

            if (i >= line.len) return false;

            // Check for end of tag
            if (line[i] == '>') {
                i += 1; // Skip >
                // Rest of line must be whitespace
                while (i < line.len) : (i += 1) {
                    if (line[i] != ' ' and line[i] != '\t' and line[i] != '\n') {
                        return false;
                    }
                }
                return true;
            }

            // Check for self-closing tag
            if (line[i] == '/' and i + 1 < line.len and line[i + 1] == '>') {
                i += 2;
                // Rest of line must be whitespace
                while (i < line.len) : (i += 1) {
                    if (line[i] != ' ' and line[i] != '\t' and line[i] != '\n') {
                        return false;
                    }
                }
                return true;
            }

            // If we're about to parse an attribute, we MUST have consumed whitespace
            if (i == whitespace_start) {
                // No whitespace before attribute - invalid
                return false;
            }

            // Parse attribute name - must start with ASCII letter, _, or :
            if (!isAlpha(line[i]) and line[i] != '_' and line[i] != ':') {
                return false;
            }

            // Attribute name can contain ASCII letters, digits, _, :, ., or -
            while (i < line.len and (isAlphaNum(line[i]) or line[i] == '_' or line[i] == ':' or line[i] == '.' or line[i] == '-')) : (i += 1) {}

            if (i >= line.len) return false;

            // Skip whitespace after attribute name (including newlines)
            while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\n')) : (i += 1) {}

            if (i >= line.len) return false;

            // Check for attribute value
            if (line[i] == '=') {
                i += 1;

                // Skip whitespace after = (including newlines)
                while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\n')) : (i += 1) {}

                if (i >= line.len) return false;

                // Parse attribute value
                if (line[i] == '"') {
                    // Double-quoted value - can span lines
                    i += 1;
                    while (i < line.len and line[i] != '"') {
                        // Backslash before quote is invalid in HTML
                        if (line[i] == '\\' and i + 1 < line.len and line[i + 1] == '"') {
                            return false;
                        }
                        i += 1;
                    }
                    if (i >= line.len or line[i] != '"') return false;
                    i += 1; // Skip closing quote
                } else if (line[i] == '\'') {
                    // Single-quoted value - can span lines
                    i += 1;
                    while (i < line.len and line[i] != '\'') {
                        // Backslash before quote is invalid in HTML
                        if (line[i] == '\\' and i + 1 < line.len and line[i + 1] == '\'') {
                            return false;
                        }
                        i += 1;
                    }
                    if (i >= line.len or line[i] != '\'') return false;
                    i += 1; // Skip closing quote
                } else {
                    // Unquoted value - must not contain space, tab, newline, ", ', =, <, >, or `
                    const val_start = i;
                    while (i < line.len and line[i] != ' ' and line[i] != '\t' and line[i] != '\n' and
                           line[i] != '>' and line[i] != '"' and line[i] != '\'' and
                           line[i] != '=' and line[i] != '<' and line[i] != '`') : (i += 1) {}
                    // Must have at least one character
                    if (i == val_start) return false;
                }
            }
        }

        return false;
    }

    fn isAlpha(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
    }

    fn isAlphaNum(ch: u8) bool {
        return isAlpha(ch) or (ch >= '0' and ch <= '9');
    }

    fn startsWithTag(line: []const u8, tag: []const u8) bool {
        if (line.len < tag.len + 1) return false;  // Need at least <tag
        if (line[0] != '<') return false;

        var i: usize = 1;
        for (tag) |ch| {
            if (i >= line.len) return false;
            const line_ch = std.ascii.toLower(line[i]);
            if (line_ch != ch) return false;
            i += 1;
        }

        // For type 1 HTML blocks, must be followed by space, tab, >, or end of line
        if (i >= line.len) return true;
        const next = line[i];
        return next == ' ' or next == '\t' or next == '>';
    }

    fn startsWithClosingTag(line: []const u8, tag: []const u8) bool {
        if (line.len < tag.len + 3) return false;
        if (!std.mem.startsWith(u8, line, "</")) return false;

        var i: usize = 2;
        for (tag) |ch| {
            if (i >= line.len) return false;
            const line_ch = std.ascii.toLower(line[i]);
            if (line_ch != ch) return false;
            i += 1;
        }

        // Must be followed by space, >, or end of line
        if (i >= line.len) return false;
        const next = line[i];
        return next == ' ' or next == '\t' or next == '>';
    }

    fn checkHtmlBlockEnd(self: *BlockParser, line: []const u8) bool {
        switch (self.html_block_type) {
            1 => {
                // Ends when we see </script>, </pre>, </style>, or </textarea>
                const lower = std.ascii.allocLowerString(self.allocator, line) catch return false;
                defer self.allocator.free(lower);
                return std.mem.indexOf(u8, lower, "</script>") != null or
                       std.mem.indexOf(u8, lower, "</pre>") != null or
                       std.mem.indexOf(u8, lower, "</style>") != null or
                       std.mem.indexOf(u8, lower, "</textarea>") != null;
            },
            2 => {
                // Ends when we see -->
                return std.mem.indexOf(u8, line, "-->") != null;
            },
            3 => {
                // Ends when we see ?>
                return std.mem.indexOf(u8, line, "?>") != null;
            },
            4 => {
                // Ends when we see >
                return std.mem.indexOf(u8, line, ">") != null;
            },
            5 => {
                // Ends when we see ]]>
                return std.mem.indexOf(u8, line, "]]>") != null;
            },
            6 => {
                // Ends on blank line
                return utils.isBlankLine(line);
            },
            7 => {
                // Type 7 ends on blank line
                return utils.isBlankLine(line);
            },
            else => return false,
        }
    }

    fn addToHtmlBlock(self: *BlockParser, line: []const u8) !void {
        const current_literal = self.tip.literal orelse "";
        const new_literal = if (current_literal.len > 0)
            try std.fmt.allocPrint(self.arena_allocator, "{s}\n{s}", .{ current_literal, line })
        else
            try self.arena_allocator.dupe(u8, line);

        self.tip.literal = new_literal;
        self.tip.end_line = self.line_number;
    }

    fn parseLinkReferenceDefinition(self: *BlockParser, line: []const u8) !bool {
        if (line.len == 0 or line[0] != '[') return false;

        // Find closing ] (first unescaped ])
        // According to spec: "ends with the first right bracket (]) that is not backslash-escaped"
        var i: usize = 1;
        var found_close = false;
        while (i < line.len) : (i += 1) {
            if (line[i] == '\\' and i + 1 < line.len) {
                i += 1; // Skip escaped character
            } else if (line[i] == ']') {
                found_close = true;
                i += 1; // Move past the ]
                break;
            } else if (line[i] == '[') {
                // Unescaped [ inside label is not allowed
                return false;
            }
        }

        // If no closing ], label might continue on next line
        if (!found_close) {
            var consumed_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
            try consumed_lines.append(self.allocator, self.current_line_original);
            var accumulated = try std.ArrayList(u8).initCapacity(self.allocator, line.len);
            try accumulated.appendSlice(self.allocator, line[1..]); // Skip the opening [
            self.partial_refdef = PartialRefDef{
                .label = &[_]u8{}, // Empty for now
                .url = null,
                .title = null,
                .title_delimiter = 0,
                .expecting = .label_continuation,
                .accumulated = accumulated,
                .consumed_lines = consumed_lines,
            };
            return true;
        }

        // Extract label (i now points one past the closing ])
        const label = line[1..i-1];
        if (label.len == 0) return false;

        // Must be followed by :
        if (i >= line.len or line[i] != ':') return false;
        i += 1;

        // Skip whitespace (spaces and tabs)
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

        // Check if URL is on this line or next
        if (i >= line.len) {
            // URL must be on next line
            const normalized_label = try self.normalizeLabel(label);
            if (normalized_label.len == 0) return false; // Empty label after normalization
            var consumed_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
            try consumed_lines.append(self.allocator, self.current_line_original);
            self.partial_refdef = PartialRefDef{
                .label = normalized_label,
                .url = null,
                .title = null,
                .title_delimiter = 0,
                .expecting = .url,
                .accumulated = try std.ArrayList(u8).initCapacity(self.allocator, 0),
                .consumed_lines = consumed_lines,
            };
            return true;
        }

        // Parse URL
        const url_result = try self.parseUrl(line, i);
        if (url_result.url == null) return false;

        const url = url_result.url.?;
        i = url_result.next_pos;

        // Track position before skipping whitespace to check if title has required whitespace
        const pos_before_ws = i;

        // Skip whitespace
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

        // Check if we're at end of line
        if (i >= line.len) {
            // Title might be on next line, or definition might be complete
            const normalized_label = try self.normalizeLabel(label);
            if (normalized_label.len == 0) return false; // Empty label after normalization
            const processed_url = try self.processEscapes(url);
            var consumed_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
            try consumed_lines.append(self.allocator, self.current_line_original);
            self.partial_refdef = PartialRefDef{
                .label = normalized_label,
                .url = processed_url,
                .title = null,
                .title_delimiter = 0,
                .expecting = .title_or_end,
                .accumulated = try std.ArrayList(u8).initCapacity(self.allocator, 0),
                .consumed_lines = consumed_lines,
            };
            return true;
        }

        // Try to parse title on same line (requires at least one whitespace before title)
        const has_whitespace = (i > pos_before_ws);
        if (!has_whitespace) {
            // Content after URL without whitespace - invalid
            return false;
        }
        const title_result = try self.parseTitle(line, i);
        if (title_result.complete) {
            // Title is complete on this line
            i = title_result.next_pos;

            // Skip trailing whitespace
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

            // Must be at end of line
            if (i < line.len) return false;

            // Store complete definition
            const normalized_label = try self.normalizeLabel(label);
            if (normalized_label.len == 0) return false; // Empty label after normalization
            const processed_url = try self.processEscapesAndEntities(url);
            const processed_title = if (title_result.title) |t| try self.processEscapesAndEntities(t) else null;
            const ref_def = RefDef{
                .url = processed_url,
                .title = processed_title,
            };
            // Only add if not already present (first definition wins)
            const gop = try self.refmap.getOrPut(normalized_label);
            if (!gop.found_existing) {
                gop.value_ptr.* = ref_def;
            }
            return true;
        } else if (title_result.started) {
            // Title started but not complete - need more lines
            const normalized_label = try self.normalizeLabel(label);
            if (normalized_label.len == 0) return false; // Empty label after normalization
            const processed_url = try self.processEscapesAndEntities(url);
            var consumed_lines = try std.ArrayList([]const u8).initCapacity(self.allocator, 0);
            try consumed_lines.append(self.allocator, self.current_line_original);
            self.partial_refdef = PartialRefDef{
                .label = normalized_label,
                .url = processed_url,
                .title = null,
                .title_delimiter = title_result.delimiter,
                .expecting = .title_continuation,
                .accumulated = try std.ArrayList(u8).initCapacity(self.allocator, 0),
                .consumed_lines = consumed_lines,
            };
            // Store the partial title content
            try self.partial_refdef.?.accumulated.appendSlice(self.allocator, title_result.partial_content.?);
            return true;
        } else {
            // No title found, but there's content after URL - invalid
            return false;
        }
    }

    const UrlParseResult = struct {
        url: ?[]const u8,
        next_pos: usize,
    };

    fn parseUrl(self: *BlockParser, line: []const u8, start: usize) !UrlParseResult {
        _ = self;
        var i = start;

        // Check for angle-bracket URL
        if (i < line.len and line[i] == '<') {
            const url_start = i + 1;
            i += 1;
            while (i < line.len and line[i] != '>') : (i += 1) {
                if (line[i] == '\n' or line[i] == '<') {
                    return UrlParseResult{ .url = null, .next_pos = start };
                }
            }
            if (i >= line.len) {
                return UrlParseResult{ .url = null, .next_pos = start };
            }
            const url = line[url_start..i];
            i += 1; // Skip >
            return UrlParseResult{ .url = url, .next_pos = i };
        } else {
            // Bare URL (no whitespace allowed)
            const url_start = i;
            while (i < line.len and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
            const url = line[url_start..i];
            if (url.len == 0) {
                return UrlParseResult{ .url = null, .next_pos = start };
            }
            return UrlParseResult{ .url = url, .next_pos = i };
        }
    }

    const TitleParseResult = struct {
        title: ?[]const u8,
        complete: bool,
        started: bool,
        delimiter: u8,
        partial_content: ?[]const u8,
        next_pos: usize,
    };

    fn parseTitle(self: *BlockParser, line: []const u8, start: usize) !TitleParseResult {
        _ = self;
        var i = start;

        if (i >= line.len) {
            return TitleParseResult{
                .title = null,
                .complete = false,
                .started = false,
                .delimiter = 0,
                .partial_content = null,
                .next_pos = i,
            };
        }

        const quote = line[i];
        if (quote != '"' and quote != '\'' and quote != '(') {
            return TitleParseResult{
                .title = null,
                .complete = false,
                .started = false,
                .delimiter = 0,
                .partial_content = null,
                .next_pos = i,
            };
        }

        const closing_quote = if (quote == '(') ')' else quote;
        i += 1;
        const title_start = i;

        // Look for closing delimiter
        while (i < line.len and line[i] != closing_quote) : (i += 1) {
            if (line[i] == '\\' and i + 1 < line.len) {
                i += 1; // Skip escaped character
            }
        }

        if (i >= line.len) {
            // Title not complete on this line
            return TitleParseResult{
                .title = null,
                .complete = false,
                .started = true,
                .delimiter = closing_quote,
                .partial_content = line[title_start..],
                .next_pos = i,
            };
        }

        // Found closing quote
        const title = line[title_start..i];
        i += 1; // Skip closing quote
        return TitleParseResult{
            .title = title,
            .complete = true,
            .started = true,
            .delimiter = closing_quote,
            .partial_content = null,
            .next_pos = i,
        };
    }

    fn continuePartialRefDef(self: *BlockParser, line: []const u8) !bool {
        var partial = &self.partial_refdef.?;
        const content = utils.trimLeft(line);

        // Add this line to consumed lines (use original line, not processed)
        try partial.consumed_lines.append(self.allocator, self.current_line_original);

        switch (partial.expecting) {
            .label_continuation => {
                // Continue looking for the closing ]
                var i: usize = 0;
                while (i < line.len) : (i += 1) {
                    if (line[i] == '\\' and i + 1 < line.len) {
                        i += 1; // Skip escaped character
                    } else if (line[i] == ']') {
                        // Found closing ], now check for :
                        try partial.accumulated.append(self.allocator, '\n');
                        try partial.accumulated.appendSlice(self.allocator, line[0..i]);
                        i += 1; // Move past ]

                        // Must be followed by :
                        if (i >= line.len or line[i] != ':') {
                            // Not a valid ref def
                            // Remove the current line from consumed_lines since it will be processed normally
                            _ = partial.consumed_lines.pop();
                            try self.abandonPartialRefDef();
                            return false;
                        }
                        i += 1; // Move past :

                        // Normalize the label
                        const label = try self.normalizeLabel(partial.accumulated.items);
                        if (label.len == 0) {
                            // Empty label after normalization - invalid
                            // Remove the current line from consumed_lines since it will be processed normally
                            _ = partial.consumed_lines.pop();
                            try self.abandonPartialRefDef();
                            return false;
                        }

                        // Skip whitespace
                        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

                        // Check if URL is on this line or next
                        if (i >= line.len) {
                            // URL must be on next line
                            partial.label = label;
                            partial.expecting = .url;
                            partial.accumulated.clearRetainingCapacity();
                            return true;
                        }

                        // Parse URL
                        const url_result = try self.parseUrl(line, i);
                        if (url_result.url == null) {
                            // Remove the current line from consumed_lines since it will be processed normally
                            _ = partial.consumed_lines.pop();
                            try self.abandonPartialRefDef();
                            return false;
                        }

                        const url = url_result.url.?;
                        i = url_result.next_pos;

                        // Track position before skipping whitespace
                        const pos_before_ws = i;

                        // Skip whitespace
                        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

                        // Check if we're at end of line
                        if (i >= line.len) {
                            // Title might be on next line, or definition might be complete
                            const processed_url = try self.processEscapes(url);
                            partial.label = label;
                            partial.url = processed_url;
                            partial.expecting = .title_or_end;
                            partial.accumulated.clearRetainingCapacity();
                            return true;
                        }

                        // Try to parse title on same line (requires at least one whitespace before title)
                        const has_whitespace = (i > pos_before_ws);
                        if (!has_whitespace) {
                            // Content after URL without whitespace - invalid
                            _ = partial.consumed_lines.pop();
                            try self.abandonPartialRefDef();
                            return false;
                        }
                        const title_result = try self.parseTitle(line, i);
                        if (title_result.complete) {
                            // Title is complete on this line
                            i = title_result.next_pos;

                            // Skip trailing whitespace
                            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

                            // Must be at end of line
                            if (i < line.len) {
                                _ = partial.consumed_lines.pop();
                                try self.abandonPartialRefDef();
                                return false;
                            }

                            // Store complete definition
                            const processed_url = try self.processEscapesAndEntities(url);
                            const processed_title = if (title_result.title) |t| try self.processEscapesAndEntities(t) else null;
                            const ref_def = RefDef{
                                .url = processed_url,
                                .title = processed_title,
                            };
                            // Only add if not already present (first definition wins)
                            const gop = try self.refmap.getOrPut(label);
                            if (!gop.found_existing) {
                                gop.value_ptr.* = ref_def;
                            }
                            partial.accumulated.deinit(self.allocator);
                            partial.consumed_lines.deinit(self.allocator);
                            self.partial_refdef = null;
                            return true;
                        } else if (title_result.started) {
                            // Title started but not complete - need more lines
                            const processed_url = try self.processEscapesAndEntities(url);
                            partial.label = label;
                            partial.url = processed_url;
                            partial.title_delimiter = title_result.delimiter;
                            partial.expecting = .title_continuation;
                            partial.accumulated.clearRetainingCapacity();
                            try partial.accumulated.appendSlice(self.allocator, title_result.partial_content.?);
                            return true;
                        } else {
                            // No title found, but there's content after URL - invalid
                            _ = partial.consumed_lines.pop();
                            try self.abandonPartialRefDef();
                            return false;
                        }
                    } else if (line[i] == '[') {
                        // Unescaped [ inside label is not allowed
                        _ = partial.consumed_lines.pop();
                        try self.abandonPartialRefDef();
                        return false;
                    }
                }

                // Didn't find closing ], continue accumulating
                try partial.accumulated.append(self.allocator, '\n');
                try partial.accumulated.appendSlice(self.allocator, line);
                return true;
            },
            .url => {
                // Parse URL
                const url_result = try self.parseUrl(content, 0);
                if (url_result.url == null) {
                    // Invalid, abandon partial refdef
                    _ = partial.consumed_lines.pop();
                    try self.abandonPartialRefDef();
                    return false;
                }

                partial.url = try self.arena_allocator.dupe(u8, url_result.url.?);
                var i = url_result.next_pos;

                // Skip whitespace
                while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}

                if (i >= content.len) {
                    // Title might be on next line
                    partial.expecting = .title_or_end;
                    return true;
                }

                // Try to parse title
                const title_result = try self.parseTitle(content, i);
                if (title_result.complete) {
                    i = title_result.next_pos;
                    // Skip trailing whitespace
                    while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
                    if (i < content.len) {
                        // Extra content, invalid
                        _ = partial.consumed_lines.pop();
                        try self.abandonPartialRefDef();
                        return false;
                    }
                    // Complete!
                    try self.finalizePartialRefDefWithTitle(title_result.title);
                    return true;
                } else if (title_result.started) {
                    // Title started but not complete
                    partial.title_delimiter = title_result.delimiter;
                    partial.expecting = .title_continuation;
                    try partial.accumulated.appendSlice(self.allocator, title_result.partial_content.?);
                    return true;
                } else {
                    // Invalid content after URL
                    _ = partial.consumed_lines.pop();
                    try self.abandonPartialRefDef();
                    return false;
                }
            },
            .title_or_end => {
                // Could be title or another refdef
                const title_result = try self.parseTitle(content, 0);
                if (title_result.complete) {
                    var i = title_result.next_pos;
                    // Skip trailing whitespace
                    while (i < content.len and (content[i] == ' ' or content[i] == '\t')) : (i += 1) {}
                    if (i < content.len) {
                        // Extra content - finalize without title and let this line be processed
                        try self.finalizePartialRefDef();
                        return false;
                    }
                    // Complete with title!
                    try self.finalizePartialRefDefWithTitle(title_result.title);
                    return true;
                } else if (title_result.started) {
                    // Title started but not complete
                    partial.title_delimiter = title_result.delimiter;
                    partial.expecting = .title_continuation;
                    try partial.accumulated.appendSlice(self.allocator, title_result.partial_content.?);
                    return true;
                } else {
                    // No title, finalize and let this line be processed normally
                    try self.finalizePartialRefDef();
                    return false;
                }
            },
            .title_continuation => {
                // Continue accumulating title until we find the closing delimiter
                var i: usize = 0;
                while (i < line.len and line[i] != partial.title_delimiter) : (i += 1) {
                    if (line[i] == '\\' and i + 1 < line.len) {
                        i += 1; // Skip escaped character
                    }
                }

                if (i >= line.len) {
                    // Still not complete, accumulate and add newline
                    try partial.accumulated.append(self.allocator, '\n');
                    try partial.accumulated.appendSlice(self.allocator, line);
                    return true;
                } else {
                    // Found closing delimiter
                    try partial.accumulated.append(self.allocator, '\n');
                    try partial.accumulated.appendSlice(self.allocator, line[0..i]);
                    i += 1; // Skip closing delimiter

                    // Skip trailing whitespace
                    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

                    if (i < line.len) {
                        // Extra content, invalid
                        _ = partial.consumed_lines.pop();
                        try self.abandonPartialRefDef();
                        return false;
                    }

                    // Complete!
                    const title = try self.arena_allocator.dupe(u8, partial.accumulated.items);
                    try self.finalizePartialRefDefWithTitle(title);
                    return true;
                }
            },
            .end => {
                // Should not happen
                return false;
            },
        }
    }

    fn finalizePartialRefDef(self: *BlockParser) !void {
        var partial = &self.partial_refdef.?;

        if (partial.url) |url| {
            const ref_def = RefDef{
                .url = url,
                .title = null,
            };
            // Only add if not already present (first definition wins)
            const gop = try self.refmap.getOrPut(partial.label);
            if (!gop.found_existing) {
                gop.value_ptr.* = ref_def;
            }
        }

        partial.accumulated.deinit(self.allocator);
        partial.consumed_lines.deinit(self.allocator);
        self.partial_refdef = null;
    }

    fn finalizePartialRefDefWithTitle(self: *BlockParser, title: ?[]const u8) !void {
        var partial = &self.partial_refdef.?;

        if (partial.url) |url| {
            const processed_title = if (title) |t| try self.processEscapesAndEntities(t) else null;
            const ref_def = RefDef{
                .url = url,
                .title = processed_title,
            };
            // Only add if not already present (first definition wins)
            const gop = try self.refmap.getOrPut(partial.label);
            if (!gop.found_existing) {
                gop.value_ptr.* = ref_def;
            }
        }

        partial.accumulated.deinit(self.allocator);
        partial.consumed_lines.deinit(self.allocator);
        self.partial_refdef = null;
    }

    fn abandonPartialRefDef(self: *BlockParser) !void {
        var partial = &self.partial_refdef.?;

        // When we abandon a partial ref def, we need to output the consumed lines as normal paragraph content
        if (partial.consumed_lines.items.len > 0) {
            // Create a paragraph if we don't have one
            if (self.tip.type != .paragraph) {
                const para = try Node.create(self.arena_allocator, .paragraph);
                para.start_line = self.line_number;
                self.tip.appendChild(para);
                self.tip = para;
            }

            // Add each consumed line as text nodes (like addTextToParagraph does)
            for (partial.consumed_lines.items, 0..) |line, i| {
                // Add softbreak between lines (except before first line)
                if (i > 0 or self.tip.first_child != null) {
                    const softbreak = try Node.create(self.arena_allocator, .softbreak);
                    self.tip.appendChild(softbreak);
                }

                // Add text node
                const text_node = try Node.create(self.arena_allocator, .text);
                text_node.literal = try self.arena_allocator.dupe(u8, line);
                self.tip.appendChild(text_node);
            }

            self.tip.end_line = self.line_number;
        }

        partial.accumulated.deinit(self.allocator);
        partial.consumed_lines.deinit(self.allocator);
        self.partial_refdef = null;
    }

    fn normalizeLabel(self: *BlockParser, label: []const u8) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, label.len);
        defer result.deinit(self.allocator);

        var in_whitespace = false;
        var i: usize = 0;
        while (i < label.len) {
            const ch = label[i];

            // According to CommonMark spec, backslash escapes are NOT processed during label normalization
            // Only case-folding, whitespace collapsing, and trimming are performed

            if (ch == ' ' or ch == '\t' or ch == '\n') {
                if (!in_whitespace) {
                    try result.append(self.allocator, ' ');
                    in_whitespace = true;
                }
                i += 1;
            } else if (ch < 128) {
                // ASCII character - simple case folding
                try result.append(self.allocator, std.ascii.toLower(ch));
                in_whitespace = false;
                i += 1;
            } else {
                // Multi-byte UTF-8 character - handle Unicode case-folding

                // Check for Latin Capital Letter Sharp S (U+1E9E: ẞ) - case-folds to "ss"
                // UTF-8 encoding: 0xE1 0xBA 0x9E
                if (i + 2 < label.len and label[i] == 0xE1 and label[i+1] == 0xBA and label[i+2] == 0x9E) {
                    try result.append(self.allocator, 's');
                    try result.append(self.allocator, 's');
                    in_whitespace = false;
                    i += 3;
                    continue;
                }

                // Check for Latin Small Letter Sharp S (U+00DF: ß) - case-folds to "ss"
                // UTF-8 encoding: 0xC3 0x9F
                if (i + 1 < label.len and label[i] == 0xC3 and label[i+1] == 0x9F) {
                    try result.append(self.allocator, 's');
                    try result.append(self.allocator, 's');
                    in_whitespace = false;
                    i += 2;
                    continue;
                }

                // For other multi-byte characters, decode and apply case-folding
                const bytes_len = std.unicode.utf8ByteSequenceLength(ch) catch {
                    // Invalid UTF-8, just copy the byte
                    try result.append(self.allocator, ch);
                    in_whitespace = false;
                    i += 1;
                    continue;
                };

                if (i + bytes_len > label.len) {
                    // Incomplete UTF-8 sequence, just copy the byte
                    try result.append(self.allocator, ch);
                    in_whitespace = false;
                    i += 1;
                    continue;
                }

                const codepoint = std.unicode.utf8Decode(label[i..i+bytes_len]) catch {
                    // Invalid UTF-8, just copy the bytes
                    try result.appendSlice(self.allocator, label[i..i+bytes_len]);
                    in_whitespace = false;
                    i += bytes_len;
                    continue;
                };

                // Simple Unicode case-folding: convert to uppercase then to lowercase
                // This handles most cases correctly
                const upper = unicodeToUpper(codepoint);
                const lower = unicodeToLower(upper);

                // Encode back to UTF-8
                var utf8_buf: [4]u8 = undefined;
                const utf8_len = std.unicode.utf8Encode(lower, &utf8_buf) catch {
                    // If encoding fails, use original bytes
                    try result.appendSlice(self.allocator, label[i..i+bytes_len]);
                    in_whitespace = false;
                    i += bytes_len;
                    continue;
                };
                try result.appendSlice(self.allocator, utf8_buf[0..utf8_len]);
                in_whitespace = false;
                i += bytes_len;
            }
        }

        // Trim
        var s = result.items;
        var start: usize = 0;
        while (start < s.len and s[start] == ' ') {
            start += 1;
        }
        var end: usize = s.len;
        while (end > start and s[end - 1] == ' ') {
            end -= 1;
        }

        return self.arena_allocator.dupe(u8, s[start..end]);
    }

    // Simple Unicode uppercase conversion (handles common cases)
    fn unicodeToUpper(codepoint: u21) u21 {
        // ASCII range
        if (codepoint >= 'a' and codepoint <= 'z') {
            return codepoint - 32;
        }
        // Latin-1 Supplement (common accented characters)
        if (codepoint >= 0xE0 and codepoint <= 0xFE and codepoint != 0xF7) {
            return codepoint - 32;
        }
        // Greek lowercase to uppercase (U+03B1-U+03C9 -> U+0391-U+03A9)
        if (codepoint >= 0x03B1 and codepoint <= 0x03C9) {
            return codepoint - 0x20;
        }
        return codepoint;
    }

    // Simple Unicode lowercase conversion (handles common cases)
    fn unicodeToLower(codepoint: u21) u21 {
        // ASCII range
        if (codepoint >= 'A' and codepoint <= 'Z') {
            return codepoint + 32;
        }
        // Latin-1 Supplement (common accented characters)
        if (codepoint >= 0xC0 and codepoint <= 0xDE and codepoint != 0xD7) {
            return codepoint + 32;
        }
        // Greek uppercase to lowercase (U+0391-U+03A9 -> U+03B1-U+03C9)
        if (codepoint >= 0x0391 and codepoint <= 0x03A9) {
            return codepoint + 0x20;
        }
        return codepoint;
    }

    fn processEscapes(self: *BlockParser, text: []const u8) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, text.len);
        defer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\\' and i + 1 < text.len) {
                const next = text[i + 1];
                if (scanner.isAsciiPunctuation(next)) {
                    try result.append(self.allocator, next);
                    i += 1; // Skip the escaped character
                    continue;
                }
            }
            try result.append(self.allocator, text[i]);
        }

        return self.arena_allocator.dupe(u8, result.items);
    }

    // Process both backslash escapes and HTML entities in a string
    // Used for URLs and titles in link reference definitions
    fn processEscapesAndEntities(self: *BlockParser, text: []const u8) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, text.len);
        defer result.deinit(self.allocator);

        var i: usize = 0;
        while (i < text.len) {
            // Process backslash escapes first
            if (text[i] == '\\' and i + 1 < text.len and scanner.isAsciiPunctuation(text[i + 1])) {
                try result.append(self.allocator, text[i + 1]);
                i += 2;
                continue;
            }

            // Process HTML entities
            if (text[i] == '&') {
                if (entities.decodeEntity(text, i)) |decoded| {
                    try result.appendSlice(self.allocator, decoded.str);
                    i += decoded.len;
                    continue;
                }
            }

            try result.append(self.allocator, text[i]);
            i += 1;
        }

        return self.arena_allocator.dupe(u8, result.items);
    }

    // Recursively finalize all code blocks in the tree
    fn finalizeCodeBlocks(self: *BlockParser, node: *Node) !void {
        // Process children first
        var child = node.first_child;
        while (child) |c| {
            try self.finalizeCodeBlocks(c);
            child = c.next;
        }

        // Trim trailing blank lines from INDENTED code blocks only
        // The spec says to remove trailing blank lines for indented code blocks
        // Fenced code blocks preserve all content including trailing blank lines
        // We can distinguish them: fenced code blocks have code_info set, indented don't
        if (node.type == .code_block and node.code_info == null) {
            // This is an indented code block - trim trailing blank lines
            if (node.literal) |lit| {
                // Find the last non-newline character
                var last_content: usize = 0;
                for (lit, 0..) |ch, i| {
                    if (ch != '\n') {
                        last_content = i + 1; // Position after this char
                    }
                }
                // Strip everything after the last content character
                node.literal = lit[0..last_content];
            }
        }
    }
};
