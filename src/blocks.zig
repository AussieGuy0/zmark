const std = @import("std");
const Node = @import("node.zig").Node;
const NodeType = @import("node.zig").NodeType;
const ListData = @import("node.zig").ListData;
const ListType = @import("node.zig").ListType;
const RefDef = @import("node.zig").RefDef;
const utils = @import("utils.zig");
const scanner = @import("scanner.zig");

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

    const PartialRefDef = struct {
        label: []const u8,
        url: ?[]const u8,
        title: ?[]const u8,
        title_delimiter: u8,
        expecting: enum { url, title_or_end, title_continuation, end },
        accumulated: std.ArrayList(u8),
    };

    pub fn init(allocator: std.mem.Allocator, arena_allocator: std.mem.Allocator, root: *Node) !BlockParser {
        return BlockParser{
            .allocator = allocator,
            .arena_allocator = arena_allocator,
            .lines = try std.ArrayList([]const u8).initCapacity(allocator, 64),
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
                partial.accumulated.deinit(self.allocator);
                self.partial_refdef = null;
            }
        }

        // Close all open blocks
        while (self.tip != self.root) {
            self.tip = self.tip.parent.?;
        }
    }

    fn incorporateLine(self: *BlockParser, line: []const u8) !void {
        self.offset = 0;
        self.column = 0;

        // If we're in an HTML block, check for end condition
        if (self.in_html_block) {
            try self.addToHtmlBlock(line);
            if (self.checkHtmlBlockEnd(line)) {
                self.in_html_block = false;
                self.tip = self.tip.parent.?;
            }
            return;
        }

        // If we're in a fenced code block, check for closing fence
        if (self.in_fenced_code) {
            if (try self.checkClosingFence(line)) {
                self.in_fenced_code = false;
                self.tip = self.tip.parent.?;
                return;
            }
            // Add line to fenced code block
            try self.addToFencedCodeBlock(line);
            return;
        }

        const is_blank = utils.isBlankLine(line);

        // Check if line is blank
        if (is_blank) {
            // Blank lines within code blocks are preserved
            if (self.tip.type == .code_block) {
                try self.addToCodeBlock(line);
                return;
            }

            // Blank line terminates any partial link reference definition
            if (self.partial_refdef) |*partial| {
                // Blank lines are not allowed within titles
                if (partial.expecting == .title_continuation) {
                    // Invalid - title can't span blank lines
                    partial.accumulated.deinit(self.allocator);
                    self.partial_refdef = null;
                } else if (partial.url != null) {
                    // Finalize if we have at least a URL
                    try self.finalizePartialRefDef();
                } else {
                    // Invalid partial refdef, discard it
                    partial.accumulated.deinit(self.allocator);
                    self.partial_refdef = null;
                }
            }

            // Blank line closes paragraph
            if (self.tip.type == .paragraph) {
                self.tip = self.tip.parent.?;
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
        var matched_container = self.root;

        for (path.items) |container| {
            const matched = try self.matchContainer(container, line, &current_offset, is_blank);
            if (!matched) break;
            matched_container = container;
        }

        // Close unmatched containers
        while (self.tip != matched_container) {
            self.tip = self.tip.parent.?;
        }

        self.last_matched_container = matched_container;

        // Don't process blank lines further
        if (is_blank) {
            return;
        }

        // Get remaining line content after container markers
        const remaining = if (current_offset < line.len) line[current_offset..] else "";

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
                if ((ch == '-' or ch == '+' or ch == '*') and content.len >= 2) {
                    if (content[1] == ' ' or content[1] == '\t') break :blk true;
                }
                // Check for ordered list markers
                if (ch >= '0' and ch <= '9') {
                    var i: usize = 1;
                    while (i < content.len and content[i] >= '0' and content[i] <= '9') : (i += 1) {}
                    if (i < content.len and (content[i] == '.' or content[i] == ')')) {
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

    fn matchContainer(self: *BlockParser, container: *Node, line: []const u8, offset: *usize, is_blank: bool) !bool {
        switch (container.type) {
            .block_quote => {
                // Blank lines don't match block quotes (they close them)
                if (is_blank) return false;

                // Skip up to 3 spaces
                const indent = utils.calculateIndentation(line[offset.*..]);
                const to_skip = @min(indent, 3);
                offset.* += utils.skipSpaces(line[offset.*..], to_skip);

                if (offset.* >= line.len or line[offset.*] != '>') {
                    // No '>' marker - check if we can do lazy continuation
                    // Lazy continuation only works if we're currently in a paragraph
                    if (self.tip.type == .paragraph) {
                        var check = self.tip.parent;
                        while (check) |node| {
                            if (node == container) {
                                // We're in a paragraph inside this block quote
                                // Allow lazy continuation (don't consume anything)
                                return true;
                            }
                            check = node.parent;
                        }
                    }
                    return false;
                }

                // Consume '>'
                offset.* += 1;

                // Consume optional space after '>'
                if (offset.* < line.len and (line[offset.*] == ' ' or line[offset.*] == '\t')) {
                    offset.* += 1;
                }

                return true;
            },
            .list_item => {
                // Blank lines always match list items (they can be part of the item)
                if (is_blank) return true;

                // Check if line is indented enough to be part of this list item
                const item_indent = container.indent;
                const line_indent = utils.calculateIndentation(line[offset.*..]);

                if (line_indent >= item_indent) {
                    // Consume the required indentation
                    offset.* += utils.skipSpaces(line[offset.*..], item_indent);
                    return true;
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

        // Try to match HTML block
        if (try self.parseHtmlBlock(content)) {
            return;
        }

        // Try to match fenced code block opening
        const indent = 0; // Already stripped
        if (try self.parseFencedCodeBlock(content, indent)) {
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

        // Create block quote
        const quote = try Node.create(self.arena_allocator, .block_quote);
        quote.start_line = self.line_number;
        self.tip.appendChild(quote);
        self.tip = quote;

        // Remove the > and optional following space
        var content = line[1..];
        if (content.len > 0 and (content[0] == ' ' or content[0] == '\t')) {
            content = content[1..];
        }

        // If content is now empty, just return
        if (content.len == 0) {
            return true;
        }

        // Process the rest of the line recursively
        try self.processLineContent(content);
        return true;
    }

    fn parseThematicBreak(self: *BlockParser, line: []const u8) !bool {
        var s = line;
        s = utils.trimLeft(s);

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
        var s = line;
        s = utils.trimLeft(s);

        if (s.len == 0) return false;

        const ch = s[0];
        if (ch != '=' and ch != '-') return false;

        // Check if all remaining characters are the same (= or -)
        for (s) |c| {
            if (c != ch and c != ' ' and c != '\t') {
                return false;
            }
        }

        // Must have at least one = or -
        var has_marker = false;
        for (s) |c| {
            if (c == ch) {
                has_marker = true;
                break;
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
        var s = line;
        s = utils.trimLeft(s);

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

    fn addTextToParagraph(self: *BlockParser, line: []const u8) !void {
        // If tip is not a paragraph, create one
        if (self.tip.type != .paragraph) {
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
            const code = try Node.create(self.arena_allocator, .code_block);
            code.start_line = self.line_number;
            self.tip.appendChild(code);
            self.tip = code;
            code.literal = try self.arena_allocator.dupe(u8, "");
        }

        // Remove 4 spaces of indentation
        const content = utils.skipIndentation(line, 4);

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

        // Create fenced code block
        const code = try Node.create(self.arena_allocator, .code_block);
        code.start_line = self.line_number;
        code.literal = null; // Will be set when first line is added

        // Store info string if present (with backslash escapes processed)
        if (info.len > 0) {
            const processed_info = try self.processEscapes(info);
            code.code_info = processed_info;
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

        // Check for unordered list marker: -, +, or *
        if (ch == '-' or ch == '+' or ch == '*') {
            // Must be followed by at least one space/tab
            if (line.len < 2) return false;
            if (line[1] != ' ' and line[1] != '\t') return false;

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
                } else {
                    break;
                }
            }

            if (num_end == 0 or num_end >= line.len) return false;

            const delim = line[num_end];
            if (delim != '.' and delim != ')') return false;

            // Must be followed by at least one space/tab
            if (num_end + 1 >= line.len) return false;
            const after = line[num_end + 1];
            if (after != ' ' and after != '\t') return false;

            marker_type = .ordered;
            delimiter = delim;
            start_num = num_val;
            marker_end = num_end + 1;
        } else {
            return false;
        }

        // Calculate marker width and content indent
        const marker_width = marker_end + 1; // +1 for the required space

        // Calculate how much indentation the content has
        // Skip the marker and the required space
        var content_start = marker_end + 1;

        // Skip additional spaces/tabs after marker (up to 3 more)
        var spaces_after_marker: usize = 0;
        while (content_start < line.len and spaces_after_marker < 4) {
            const c = line[content_start];
            if (c == ' ') {
                spaces_after_marker += 1;
                content_start += 1;
            } else if (c == '\t') {
                // Tab counts as moving to next tab stop
                spaces_after_marker += 4 - (marker_width % 4);
                content_start += 1;
                break;
            } else {
                break;
            }
        }

        // Content indent is marker width + spaces after marker (max 4 total spaces after marker)
        // Plus any indentation that was already stripped before calling parseListItem
        const content_indent = self.offset + marker_width + @min(spaces_after_marker, 4);

        // Get the actual content
        const content = if (content_start < line.len) line[content_start..] else "";

        // Close paragraph if open
        if (self.tip.type == .paragraph) {
            self.tip = self.tip.parent.?;
        }

        // Create or find list
        var list_node: *Node = undefined;
        if (self.tip.type == .list) {
            const list_data = self.tip.list_data orelse return error.MissingListData;
            const matches = if (marker_type == .bullet)
                list_data.type == .bullet and list_data.bullet_char == bullet_char
            else
                list_data.type == .ordered and list_data.delimiter == delimiter;

            if (matches) {
                // Continue existing list
                list_node = self.tip;
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
        }

        // Create list item with proper indent
        const item = try Node.create(self.arena_allocator, .list_item);
        item.start_line = self.line_number;
        item.indent = content_indent;
        list_node.appendChild(item);
        self.tip = item;

        // Add content if present
        if (content.len > 0) {
            const para = try Node.create(self.arena_allocator, .paragraph);
            para.start_line = self.line_number;
            item.appendChild(para);
            self.tip = para;

            const text_node = try Node.create(self.arena_allocator, .text);
            text_node.literal = try self.arena_allocator.dupe(u8, content);
            para.appendChild(text_node);
        }

        return true;
    }

    fn parseHtmlBlock(self: *BlockParser, line: []const u8) !bool {
        if (line.len == 0 or line[0] != '<') return false;

        // Close paragraph if open
        if (self.tip.type == .paragraph) {
            self.tip = self.tip.parent.?;
        }

        // Detect HTML block type
        const html_type = detectHtmlBlockType(line);
        if (html_type == 0) return false;

        // Create HTML block
        const html_block = try Node.create(self.arena_allocator, .html_block);
        html_block.start_line = self.line_number;
        html_block.literal = try self.arena_allocator.dupe(u8, line);
        self.tip.appendChild(html_block);
        self.tip = html_block;

        self.in_html_block = true;
        self.html_block_type = html_type;

        // Check if block ends on same line
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
        // If we see : or + here, it's likely an autolink, not an HTML tag
        if (i < line.len) {
            const ch = line[i];
            if (ch == ':' or ch == '+' or ch == '.') {
                return false; // This is an autolink like <http://...> or <a+b:c>, not an HTML tag
            }
        }

        // Parse attributes (simplified - just skip to >)
        while (i < line.len and line[i] != '>') : (i += 1) {
            // If we encounter a newline before >, it's not complete
            if (line[i] == '\n') return false;
        }

        // Must end with >
        if (i >= line.len) return false;
        i += 1; // Skip >

        // Rest of line must be whitespace
        while (i < line.len) : (i += 1) {
            if (line[i] != ' ' and line[i] != '\t' and line[i] != '\n') {
                return false;
            }
        }
        return true;
    }

    fn isAlpha(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
    }

    fn isAlphaNum(ch: u8) bool {
        return isAlpha(ch) or (ch >= '0' and ch <= '9');
    }

    fn startsWithTag(line: []const u8, tag: []const u8) bool {
        if (line.len < tag.len + 2) return false;
        if (line[0] != '<') return false;

        var i: usize = 1;
        for (tag) |ch| {
            if (i >= line.len) return false;
            const line_ch = std.ascii.toLower(line[i]);
            if (line_ch != ch) return false;
            i += 1;
        }

        // Must be followed by space, >, or end of line
        if (i >= line.len) return true;
        const next = line[i];
        return next == ' ' or next == '\t' or next == '>' or next == '\n';
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

        // Find closing ]
        var i: usize = 1;
        var bracket_depth: usize = 1;
        while (i < line.len and bracket_depth > 0) : (i += 1) {
            if (line[i] == '[') {
                bracket_depth += 1;
            } else if (line[i] == ']') {
                bracket_depth -= 1;
            } else if (line[i] == '\\' and i + 1 < line.len) {
                i += 1; // Skip escaped character
            }
        }
        if (bracket_depth != 0) return false;

        // Extract label (i now points after the closing ])
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
            self.partial_refdef = PartialRefDef{
                .label = normalized_label,
                .url = null,
                .title = null,
                .title_delimiter = 0,
                .expecting = .url,
                .accumulated = try std.ArrayList(u8).initCapacity(self.allocator, 0),
            };
            return true;
        }

        // Parse URL
        const url_result = try self.parseUrl(line, i);
        if (url_result.url == null) return false;

        const url = url_result.url.?;
        i = url_result.next_pos;

        // Skip whitespace
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

        // Check if we're at end of line
        if (i >= line.len) {
            // Title might be on next line, or definition might be complete
            const normalized_label = try self.normalizeLabel(label);
            const processed_url = try self.processEscapes(url);
            self.partial_refdef = PartialRefDef{
                .label = normalized_label,
                .url = processed_url,
                .title = null,
                .title_delimiter = 0,
                .expecting = .title_or_end,
                .accumulated = try std.ArrayList(u8).initCapacity(self.allocator, 0),
            };
            return true;
        }

        // Try to parse title on same line
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
            const processed_url = try self.processEscapes(url);
            const processed_title = if (title_result.title) |t| try self.processEscapes(t) else null;
            const ref_def = RefDef{
                .url = processed_url,
                .title = processed_title,
            };
            try self.refmap.put(normalized_label, ref_def);
            return true;
        } else if (title_result.started) {
            // Title started but not complete - need more lines
            const normalized_label = try self.normalizeLabel(label);
            const processed_url = try self.processEscapes(url);
            self.partial_refdef = PartialRefDef{
                .label = normalized_label,
                .url = processed_url,
                .title = null,
                .title_delimiter = title_result.delimiter,
                .expecting = .title_continuation,
                .accumulated = try std.ArrayList(u8).initCapacity(self.allocator, 0),
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

        switch (partial.expecting) {
            .url => {
                // Parse URL
                const url_result = try self.parseUrl(content, 0);
                if (url_result.url == null) {
                    // Invalid, abandon partial refdef
                    partial.accumulated.deinit(self.allocator);
                    self.partial_refdef = null;
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
                        partial.accumulated.deinit(self.allocator);
                        self.partial_refdef = null;
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
                    partial.accumulated.deinit(self.allocator);
                    self.partial_refdef = null;
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
                        partial.accumulated.deinit(self.allocator);
                        self.partial_refdef = null;
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
            try self.refmap.put(partial.label, ref_def);
        }

        partial.accumulated.deinit(self.allocator);
        self.partial_refdef = null;
    }

    fn finalizePartialRefDefWithTitle(self: *BlockParser, title: ?[]const u8) !void {
        var partial = &self.partial_refdef.?;

        if (partial.url) |url| {
            const processed_title = if (title) |t| try self.processEscapes(t) else null;
            const ref_def = RefDef{
                .url = url,
                .title = processed_title,
            };
            try self.refmap.put(partial.label, ref_def);
        }

        partial.accumulated.deinit(self.allocator);
        self.partial_refdef = null;
    }

    fn normalizeLabel(self: *BlockParser, label: []const u8) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, label.len);
        defer result.deinit(self.allocator);

        var in_whitespace = false;
        var i: usize = 0;
        while (i < label.len) : (i += 1) {
            const ch = label[i];

            // Handle backslash escapes
            if (ch == '\\' and i + 1 < label.len) {
                const next = label[i + 1];
                if (scanner.isAsciiPunctuation(next)) {
                    try result.append(self.allocator, std.ascii.toLower(next));
                    in_whitespace = false;
                    i += 1; // Skip the escaped character
                    continue;
                }
            }

            if (ch == ' ' or ch == '\t' or ch == '\n') {
                if (!in_whitespace) {
                    try result.append(self.allocator, ' ');
                    in_whitespace = true;
                }
            } else {
                try result.append(self.allocator, std.ascii.toLower(ch));
                in_whitespace = false;
            }
        }

        // Trim
        var s = result.items;
        while (s.len > 0 and s[0] == ' ') {
            s = s[1..];
        }
        while (s.len > 0 and s[s.len - 1] == ' ') {
            s = s[0 .. s.len - 1];
        }

        return self.arena_allocator.dupe(u8, s);
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
};
