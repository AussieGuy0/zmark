const std = @import("std");
const Node = @import("node.zig").Node;
const NodeType = @import("node.zig").NodeType;
const RefDef = @import("node.zig").RefDef;
const entities = @import("entities.zig");
const scanner = @import("scanner.zig");

pub const InlineParser = struct {
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    refmap: *const std.StringHashMap(RefDef),
    inside_link: bool, // Track if we're parsing inside a link (no nested links allowed)

    pub fn init(allocator: std.mem.Allocator, arena_allocator: std.mem.Allocator, refmap: *const std.StringHashMap(RefDef)) InlineParser {
        return InlineParser{
            .allocator = allocator,
            .arena_allocator = arena_allocator,
            .refmap = refmap,
            .inside_link = false,
        };
    }

    pub fn processInlines(self: *InlineParser, root: *Node) !void {
        try self.processNode(root);
    }

    fn processNode(self: *InlineParser, node: *Node) !void {
        // Process children first
        var child = node.first_child;
        while (child) |c| {
            const next = c.next;
            try self.processNode(c);
            child = next;
        }

        // Parse inlines in text-containing blocks
        switch (node.type) {
            .paragraph, .heading => {
                try self.parseInlineContent(node);
            },
            else => {},
        }
    }

    fn parseInlineContent(self: *InlineParser, block_node: *Node) !void {
        // Collect all text content from the block
        var text_buffer = try std.ArrayList(u8).initCapacity(self.allocator, 256);
        defer text_buffer.deinit(self.allocator);

        var child = block_node.first_child;
        while (child) |c| {
            if (c.type == .text) {
                if (c.literal) |lit| {
                    try text_buffer.appendSlice(self.allocator, lit);
                }
            } else if (c.type == .softbreak) {
                try text_buffer.append(self.allocator, '\n');
            }
            child = c.next;
        }

        if (text_buffer.items.len == 0) return;

        // Remove all existing children
        while (block_node.first_child) |c| {
            c.unlink();
        }

        // Parse the text content as inlines
        const text = text_buffer.items;
        try self.parseInlines(block_node, text);
    }

    // Helper struct to track delimiter runs on the stack
    const Delimiter = struct {
        char: u8, // '*' or '_'
        num: usize, // number of delimiters remaining
        orig_num: usize, // original number of delimiters
        node: *Node, // the text node containing the delimiters
        can_open: bool,
        can_close: bool,
        prev: ?*Delimiter,
        next: ?*Delimiter,

        fn canMatch(self: *const Delimiter, closer: *const Delimiter) bool {
            // Must be same character
            if (self.char != closer.char) return false;

            // Check rule 9: if both opener and closer can both open and close,
            // sum of lengths must not be multiple of 3 unless both are multiples of 3
            if (self.can_open and self.can_close and closer.can_open and closer.can_close) {
                const sum = self.orig_num + closer.orig_num;
                if (sum % 3 == 0 and (self.orig_num % 3 != 0 or closer.orig_num % 3 != 0)) {
                    return false;
                }
            }

            return true;
        }
    };

    // Check if a character is Unicode whitespace
    // Unicode whitespace: Zs category, tab, line feed, form feed, carriage return
    fn isUnicodeWhitespace(ch: u8) bool {
        return switch (ch) {
            ' ', '\t', '\n', '\r', 0x0C => true, // space, tab, LF, CR, FF
            0xA0 => true, // non-breaking space (U+00A0)
            else => false,
        };
    }

    // Check if a character is Unicode punctuation
    // Unicode punctuation: P or S general categories (approximated with ASCII punctuation)
    // For full Unicode support, we'd need to check Unicode categories, but for ASCII we can use:
    fn isUnicodePunctuation(ch: u8) bool {
        // ASCII punctuation characters
        return switch (ch) {
            '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/',
            ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
            else => false,
        };
    }

    // Check if a delimiter run is left-flanking
    // A left-flanking delimiter run is:
    // (1) not followed by Unicode whitespace, AND
    // (2a) not followed by Unicode punctuation, OR
    // (2b) followed by Unicode punctuation AND preceded by whitespace or punctuation
    fn isLeftFlanking(text: []const u8, pos: usize, length: usize) bool {
        const after_pos = pos + length;

        // Get the character after the delimiter run
        const after_char: ?u8 = if (after_pos < text.len) text[after_pos] else null;

        // Get the character before the delimiter run
        const before_char: ?u8 = if (pos > 0) text[pos - 1] else null;

        // (1) not followed by Unicode whitespace
        // Beginning and end of line count as whitespace
        if (after_char == null or isUnicodeWhitespace(after_char.?)) {
            return false;
        }

        // (2a) not followed by Unicode punctuation
        if (!isUnicodePunctuation(after_char.?)) {
            return true;
        }

        // (2b) followed by Unicode punctuation AND preceded by whitespace or punctuation
        // Beginning and end of line count as whitespace
        if (before_char == null or isUnicodeWhitespace(before_char.?) or isUnicodePunctuation(before_char.?)) {
            return true;
        }

        return false;
    }

    // Check if a delimiter run is right-flanking
    // A right-flanking delimiter run is:
    // (1) not preceded by Unicode whitespace, AND
    // (2a) not preceded by Unicode punctuation, OR
    // (2b) preceded by Unicode punctuation AND followed by whitespace or punctuation
    fn isRightFlanking(text: []const u8, pos: usize, length: usize) bool {
        const after_pos = pos + length;

        // Get the character after the delimiter run
        const after_char: ?u8 = if (after_pos < text.len) text[after_pos] else null;

        // Get the character before the delimiter run
        const before_char: ?u8 = if (pos > 0) text[pos - 1] else null;

        // (1) not preceded by Unicode whitespace
        // Beginning and end of line count as whitespace
        if (before_char == null or isUnicodeWhitespace(before_char.?)) {
            return false;
        }

        // (2a) not preceded by Unicode punctuation
        if (!isUnicodePunctuation(before_char.?)) {
            return true;
        }

        // (2b) preceded by Unicode punctuation AND followed by whitespace or punctuation
        // Beginning and end of line count as whitespace
        if (after_char == null or isUnicodeWhitespace(after_char.?) or isUnicodePunctuation(after_char.?)) {
            return true;
        }

        return false;
    }

    // Check if a delimiter run can open emphasis (rules 1-2, 5-6)
    fn canOpenEmphasis(self: *InlineParser, text: []const u8, pos: usize, length: usize, char: u8) bool {
        _ = self;
        const left_flanking = isLeftFlanking(text, pos, length);
        if (!left_flanking) return false;

        // For '*', can open if left-flanking
        if (char == '*') {
            return true;
        }

        // For '_', can open if left-flanking AND
        // (not right-flanking OR preceded by punctuation)
        if (char == '_') {
            const right_flanking = isRightFlanking(text, pos, length);
            if (!right_flanking) {
                return true;
            }
            // Check if preceded by punctuation
            const before_char: ?u8 = if (pos > 0) text[pos - 1] else null;
            if (before_char != null and isUnicodePunctuation(before_char.?)) {
                return true;
            }
            return false;
        }

        return false;
    }

    // Check if a delimiter run can close emphasis (rules 3-4, 7-8)
    fn canCloseEmphasis(self: *InlineParser, text: []const u8, pos: usize, length: usize, char: u8) bool {
        _ = self;
        const right_flanking = isRightFlanking(text, pos, length);
        if (!right_flanking) return false;

        // For '*', can close if right-flanking
        if (char == '*') {
            return true;
        }

        // For '_', can close if right-flanking AND
        // (not left-flanking OR followed by punctuation)
        if (char == '_') {
            const left_flanking = isLeftFlanking(text, pos, length);
            if (!left_flanking) {
                return true;
            }
            // Check if followed by punctuation
            const after_pos = pos + length;
            const after_char: ?u8 = if (after_pos < text.len) text[after_pos] else null;
            if (after_char != null and isUnicodePunctuation(after_char.?)) {
                return true;
            }
            return false;
        }

        return false;
    }

    // Try to match emphasis with a closer
    // Returns true if match found and updates text_start_ptr
    fn tryMatchEmphasis(self: *InlineParser, parent: *Node, text: []const u8, open_pos: usize, text_start_ptr: *usize, open_len: usize, char: u8, use_delims: usize) !bool {
        const after_open = open_pos + open_len;
        var pos = after_open;

        while (pos < text.len) {
            if (text[pos] == char) {
                // Count delimiter run
                var run_len: usize = 0;
                var k = pos;
                while (k < text.len and text[k] == char) : (k += 1) {
                    run_len += 1;
                }

                // Check if this can close
                const can_close = self.canCloseEmphasis(text, pos, run_len, char);
                if (!can_close or run_len < use_delims) {
                    pos = k;
                    continue;
                }

                // Check rule 9
                const opener_can_close = self.canCloseEmphasis(text, open_pos, open_len, char);
                const can_open_here = self.canOpenEmphasis(text, open_pos, open_len, char);
                if (!can_open_here) {
                    pos = k;
                    continue;
                }

                if (opener_can_close and can_close) {
                    const can_open_closer = self.canOpenEmphasis(text, pos, run_len, char);
                    if (can_open_closer) {
                        const sum = open_len + run_len;
                        if (sum % 3 == 0 and (open_len % 3 != 0 or run_len % 3 != 0)) {
                            pos = k;
                            continue;
                        }
                    }
                }

                // Found a match!
                // Flush any pending text before the opener
                if (open_pos > text_start_ptr.*) {
                    try self.addTextNode(parent, text[text_start_ptr.*..open_pos]);
                }

                // Extract emphasized text
                const emph_start = open_pos + use_delims;
                const emph_end = pos;
                const emph_text = text[emph_start..emph_end];

                // Create emphasis or strong node
                const emph_node = if (use_delims == 2)
                    try Node.create(self.arena_allocator, .strong)
                else
                    try Node.create(self.arena_allocator, .emph);

                // Parse emphasized text as inlines
                try self.parseInlines(emph_node, emph_text);

                parent.appendChild(emph_node);

                // Update position and text_start
                text_start_ptr.* = pos + use_delims;
                return true;
            }
            pos += 1;
        }

        return false;
    }

    // Process emphasis delimiters using the CommonMark algorithm
    // Takes the first delimiter in the stack
    fn processEmphasisStack(self: *InlineParser, parent: *Node, stack_bottom: *Delimiter) !void {
        _ = parent;

        // Process all potential closers
        var closer = stack_bottom;
        while (closer.next) |next_closer| {
            closer = next_closer;

            // Skip if can't close
            if (!closer.can_close or (closer.char != '*' and closer.char != '_')) {
                continue;
            }

            // Look for matching opener
            var opener_opt = closer.prev;
            var opener: *Delimiter = undefined;
            var opener_found = false;

            while (opener_opt) |current_opener| {
                // Skip if wrong character or can't open
                if (current_opener.char != closer.char or !current_opener.can_open) {
                    opener_opt = current_opener.prev;
                    continue;
                }

                // Check if they can match (rule 9)
                if (!current_opener.canMatch(closer)) {
                    opener_opt = current_opener.prev;
                    continue;
                }

                // Found a match!
                opener = current_opener;
                opener_found = true;
                break;
            }

            if (!opener_found) {
                continue;
            }

            // Match found! Determine number of delimiters to use
            // Prefer strong (2) over regular (1), but don't exceed what's available
            var use_delims: usize = if (opener.num >= 2 and closer.num >= 2) 2 else 1;
            // Make sure we don't use more than available
            use_delims = @min(use_delims, opener.num);
            use_delims = @min(use_delims, closer.num);
            const emph_type: NodeType = if (use_delims == 2) .strong else .emph;

            // Create the emphasis node
            const emph_node = try Node.create(self.arena_allocator, emph_type);

            // Move nodes between opener and closer into the emphasis node
            var tmp_opt = opener.node.next;
            while (tmp_opt) |tmp| {
                if (tmp == closer.node) break;
                const next = tmp.next;
                tmp.unlink();
                emph_node.appendChild(tmp);
                tmp_opt = next;
            }

            // Update delimiter text nodes
            try self.removeDelimitersFromNode(opener.node, use_delims);
            try self.removeDelimitersFromNode(closer.node, use_delims);

            // Insert emphasis node after opener node
            opener.node.insertAfter(emph_node);

            // Update delimiter counts
            opener.num -= use_delims;
            closer.num -= use_delims;

            // Remove delimiters with 0 count by making their nodes empty
            if (opener.num == 0) {
                opener.node.literal = "";
                opener.can_open = false;
            }
            if (closer.num == 0) {
                closer.node.literal = "";
                closer.can_close = false;
            }

            // Remove any delimiters between opener and closer from the stack
            // They are now inside the emphasis node
            if (opener.next) |next_delim| {
                var delim_to_remove = next_delim;
                while (delim_to_remove != closer) {
                    delim_to_remove.can_open = false;
                    delim_to_remove.can_close = false;
                    if (delim_to_remove.next) |next| {
                        delim_to_remove = next;
                    } else {
                        break;
                    }
                }
            }

            // If opener still has delimiters, continue from there to find inner matches
            if (opener.num > 0) {
                // Process inner delimiters
                // This handles cases like *(*foo*)*
                continue;
            }
        }
    }

    fn removeDelimitersFromNode(self: *InlineParser, node: *Node, count: usize) !void {
        _ = self;
        if (node.literal) |lit| {
            if (lit.len > count) {
                node.literal = lit[count..];
            } else {
                node.literal = "";
            }
        }
    }

    fn parseInlines(self: *InlineParser, parent: *Node, text: []const u8) anyerror!void {
        if (text.len == 0) return;

        // Allocate delimiter stack
        var delimiters = try std.ArrayList(*Delimiter).initCapacity(self.allocator, 8);
        defer {
            for (delimiters.items) |delim| {
                self.allocator.destroy(delim);
            }
            delimiters.deinit(self.allocator);
        }

        var pos: usize = 0;
        var text_start: usize = 0;

        while (pos < text.len) {
            const ch = text[pos];

            // Check for code span (HIGHEST PRECEDENCE)
            if (ch == '`') {
                // Count backticks
                var backtick_count: usize = 0;
                var i = pos;
                while (i < text.len and text[i] == '`') {
                    backtick_count += 1;
                    i += 1;
                }

                // Look for closing backticks
                var close_pos: ?usize = null;
                var j = i;
                while (j < text.len) {
                    if (text[j] == '`') {
                        var close_count: usize = 0;
                        var k = j;
                        while (k < text.len and text[k] == '`') {
                            close_count += 1;
                            k += 1;
                        }
                        if (close_count == backtick_count) {
                            close_pos = j;
                            break;
                        }
                        j = k;
                    } else {
                        j += 1;
                    }
                }

                if (close_pos) |cp| {
                    // Flush any pending text
                    if (pos > text_start) {
                        try self.addTextNode(parent, text[text_start..pos]);
                    }

                    // Create code span
                    const code_content = text[i..cp];
                    // Convert line endings to spaces (but don't collapse multiple spaces)
                    const processed = try self.convertLineEndingsToSpaces(code_content);
                    defer self.allocator.free(processed);

                    // Trim one space from each end if both present AND content doesn't consist entirely of spaces
                    var final_content = processed;
                    if (final_content.len >= 2 and
                        final_content[0] == ' ' and
                        final_content[final_content.len - 1] == ' ') {
                        // Check if it consists entirely of spaces
                        var all_spaces = true;
                        for (final_content) |c| {
                            if (c != ' ') {
                                all_spaces = false;
                                break;
                            }
                        }
                        // Only strip if it doesn't consist entirely of spaces
                        if (!all_spaces) {
                            final_content = final_content[1 .. final_content.len - 1];
                        }
                    }

                    const code_node = try Node.create(self.arena_allocator, .code);
                    code_node.literal = try self.arena_allocator.dupe(u8, final_content);
                    parent.appendChild(code_node);

                    pos = cp + backtick_count;
                    text_start = pos;
                    continue;
                } else {
                    // No matching code span found - treat the entire backtick run as literal text
                    // Just skip to after all the backticks (they'll be included in pending text)
                    pos = i;
                    continue;
                }
            }

            // Check for autolink or raw HTML tag (BEFORE links)
            if (ch == '<') {
                // Try autolink first
                if (try self.parseAutolink(text, pos)) |result| {
                    // Flush any pending text
                    if (pos > text_start) {
                        try self.addTextNode(parent, text[text_start..pos]);
                    }

                    // Create link node
                    const link_node = try Node.create(self.arena_allocator, .link);
                    link_node.link_url = result.url;
                    link_node.link_title = null;

                    // Add URL as text content
                    // For email autolinks, display just the email (without "mailto:")
                    const text_node = try Node.create(self.arena_allocator, .text);
                    if (std.mem.startsWith(u8, result.url, "mailto:")) {
                        text_node.literal = result.url[7..]; // Skip "mailto:"
                    } else {
                        text_node.literal = result.url;
                    }
                    link_node.appendChild(text_node);

                    parent.appendChild(link_node);

                    pos += result.len;
                    text_start = pos;
                    continue;
                }

                // Try raw HTML tag
                if (try self.parseRawHtml(text, pos)) |html_len| {
                    // Flush any pending text
                    if (pos > text_start) {
                        try self.addTextNode(parent, text[text_start..pos]);
                    }

                    // Create HTML inline node
                    const html_node = try Node.create(self.arena_allocator, .html_inline);
                    html_node.literal = try self.arena_allocator.dupe(u8, text[pos..pos + html_len]);
                    parent.appendChild(html_node);

                    pos += html_len;
                    text_start = pos;
                    continue;
                }
            }

            // Check for emphasis or strong delimiters
            if (ch == '*' or ch == '_') {
                // Count delimiter run
                var run_len: usize = 0;
                var k = pos;
                while (k < text.len and text[k] == ch) : (k += 1) {
                    run_len += 1;
                }

                // Flush any pending text before delimiters
                if (pos > text_start) {
                    try self.addTextNode(parent, text[text_start..pos]);
                }

                // Add delimiters as a text node
                const delim_text = text[pos..k];
                const delim_node = try Node.create(self.arena_allocator, .text);
                delim_node.literal = try self.arena_allocator.dupe(u8, delim_text);
                parent.appendChild(delim_node);

                // Check if this delimiter can open or close emphasis
                const can_open = self.canOpenEmphasis(text, pos, run_len, ch);
                const can_close = self.canCloseEmphasis(text, pos, run_len, ch);

                // Add to delimiter stack if it can open or close
                if (can_open or can_close) {
                    const delim = try self.allocator.create(Delimiter);
                    delim.* = Delimiter{
                        .char = ch,
                        .num = run_len,
                        .orig_num = run_len,
                        .node = delim_node,
                        .can_open = can_open,
                        .can_close = can_close,
                        .prev = if (delimiters.items.len > 0) delimiters.items[delimiters.items.len - 1] else null,
                        .next = null,
                    };

                    // Link previous delimiter
                    if (delim.prev) |prev| {
                        prev.next = delim;
                    }

                    try delimiters.append(self.allocator, delim);
                }

                pos = k;
                text_start = pos;
                continue;
            }

            // Check for link or image
            // Skip link parsing if we're already inside a link (no nested links allowed)
            if ((ch == '[' or (ch == '!' and pos + 1 < text.len and text[pos + 1] == '[')) and (!self.inside_link or ch == '!')) {
                const is_image = (ch == '!');
                const link_start = if (is_image) pos + 1 else pos;

                // Find matching ]
                // Must skip over code spans and backslash escapes
                var bracket_depth: usize = 0;
                var close_bracket: ?usize = null;
                var j = link_start + 1;
                while (j < text.len) {
                    if (text[j] == '\\' and j + 1 < text.len) {
                        j += 2; // Skip escaped character
                        continue;
                    }
                    // Skip code spans
                    if (text[j] == '`') {
                        var tick_count: usize = 0;
                        var k = j;
                        while (k < text.len and text[k] == '`') {
                            tick_count += 1;
                            k += 1;
                        }
                        // Look for closing backticks
                        var found_close = false;
                        var m = k;
                        while (m < text.len) {
                            if (text[m] == '`') {
                                var close_count: usize = 0;
                                var n = m;
                                while (n < text.len and text[n] == '`') {
                                    close_count += 1;
                                    n += 1;
                                }
                                if (close_count == tick_count) {
                                    found_close = true;
                                    j = n;
                                    break;
                                }
                                m = n;
                            } else {
                                m += 1;
                            }
                        }
                        if (!found_close) {
                            j = k; // No closing backticks, skip opening ones
                        }
                        continue;
                    }
                    if (text[j] == '[') {
                        bracket_depth += 1;
                    } else if (text[j] == ']') {
                        if (bracket_depth == 0) {
                            close_bracket = j;
                            break;
                        }
                        bracket_depth -= 1;
                    }
                    j += 1;
                }

                if (close_bracket) |cb| {
                    // Check for inline link: (url "title")
                    if (cb + 1 < text.len and text[cb + 1] == '(') {
                        var paren_pos = cb + 2;

                        // Skip whitespace
                        while (paren_pos < text.len and (text[paren_pos] == ' ' or text[paren_pos] == '\t' or text[paren_pos] == '\n')) {
                            paren_pos += 1;
                        }

                        // Parse URL
                        var url_start = paren_pos;
                        var url_end = paren_pos;

                        // Check for angle-bracket URL
                        if (paren_pos < text.len and text[paren_pos] == '<') {
                            url_start = paren_pos + 1;
                            paren_pos += 1;
                            var found_closing = false;
                            while (paren_pos < text.len) {
                                if (text[paren_pos] == '\\' and paren_pos + 1 < text.len) {
                                    // Skip escaped character
                                    paren_pos += 2;
                                    continue;
                                }
                                if (text[paren_pos] == '\n' or text[paren_pos] == '<') {
                                    // Invalid - contains newline or <
                                    break;
                                }
                                if (text[paren_pos] == '>') {
                                    found_closing = true;
                                    url_end = paren_pos;
                                    paren_pos += 1;
                                    break;
                                }
                                paren_pos += 1;
                            }
                            if (!found_closing) {
                                // Invalid angle-bracket URL, reset and skip
                                paren_pos = url_start - 1; // Reset to before '<'
                            }
                        } else {
                            // Bare URL
                            var paren_depth: usize = 0;
                            while (paren_pos < text.len) {
                                const c = text[paren_pos];

                                // Handle backslash escapes
                                if (c == '\\' and paren_pos + 1 < text.len and scanner.isAsciiPunctuation(text[paren_pos + 1])) {
                                    // Skip the backslash and the escaped character
                                    paren_pos += 2;
                                    continue;
                                }

                                if (c == '(') {
                                    paren_depth += 1;
                                } else if (c == ')') {
                                    if (paren_depth == 0) break;
                                    paren_depth -= 1;
                                } else if (c == ' ' or c == '\t' or c == '\n') {
                                    break;
                                } else if (scanner.isControl(c)) {
                                    // Control characters are not allowed
                                    break;
                                }
                                paren_pos += 1;
                            }
                            url_end = paren_pos;
                        }

                        // Skip whitespace
                        while (paren_pos < text.len and (text[paren_pos] == ' ' or text[paren_pos] == '\t' or text[paren_pos] == '\n')) {
                            paren_pos += 1;
                        }

                        // Try to parse title
                        var title: ?[]const u8 = null;
                        if (paren_pos < text.len and (text[paren_pos] == '"' or text[paren_pos] == '\'' or text[paren_pos] == '(')) {
                            const title_delim = text[paren_pos];
                            const closing_delim = if (title_delim == '(') ')' else title_delim;
                            paren_pos += 1;
                            const title_start = paren_pos;

                            // Find closing delimiter
                            while (paren_pos < text.len and text[paren_pos] != closing_delim) {
                                if (text[paren_pos] == '\\' and paren_pos + 1 < text.len) {
                                    paren_pos += 1; // Skip escaped character
                                }
                                paren_pos += 1;
                            }

                            if (paren_pos < text.len) {
                                title = text[title_start..paren_pos];
                                paren_pos += 1; // Skip closing delimiter

                                // Skip trailing whitespace
                                while (paren_pos < text.len and (text[paren_pos] == ' ' or text[paren_pos] == '\t' or text[paren_pos] == '\n')) {
                                    paren_pos += 1;
                                }
                            }
                        }

                        // Check for closing )
                        if (paren_pos < text.len and text[paren_pos] == ')') {
                            // Flush any pending text
                            if (pos > text_start) {
                                try self.addTextNode(parent, text[text_start..pos]);
                            }

                            // Extract link text and URL
                            const link_text = text[link_start + 1 .. cb];
                            const url = text[url_start..url_end];

                            // Process backslash escapes and HTML entities in URL and title
                            const processed_url = try self.processEscapesAndEntities(url);
                            defer self.allocator.free(processed_url);
                            const processed_title = if (title) |t| blk: {
                                const pt = try self.processEscapesAndEntities(t);
                                break :blk pt;
                            } else null;
                            defer if (processed_title) |pt| self.allocator.free(pt);

                            // Create link or image node
                            const link_node = if (is_image)
                                try Node.create(self.arena_allocator, .image)
                            else
                                try Node.create(self.arena_allocator, .link);

                            link_node.link_url = try self.arena_allocator.dupe(u8, processed_url);
                            link_node.link_title = if (processed_title) |pt| try self.arena_allocator.dupe(u8, pt) else null;

                            // Parse link text as inlines (set inside_link flag to prevent nesting)
                            const was_inside_link = self.inside_link;
                            self.inside_link = true;
                            try self.parseInlines(link_node, link_text);
                            self.inside_link = was_inside_link;

                            parent.appendChild(link_node);

                            pos = paren_pos + 1;
                            text_start = pos;
                            continue;
                        }
                    }

                    // Try reference link
                    // Check for [text][ref], [text][], or [text]
                    var ref_label: ?[]const u8 = null;
                    var end_pos = cb + 1;

                    if (cb + 1 < text.len and text[cb + 1] == '[') {
                        // [text][ref] or [text][]
                        const ref_start = cb + 2;
                        var ref_end = ref_start;
                        var valid_label = true;
                        while (ref_end < text.len) : (ref_end += 1) {
                            if (text[ref_end] == '\\' and ref_end + 1 < text.len) {
                                ref_end += 1; // Skip escaped character
                                continue;
                            }
                            if (text[ref_end] == ']') break;
                            if (text[ref_end] == '[') {
                                // Unescaped [ in reference label is not allowed
                                valid_label = false;
                                break;
                            }
                        }
                        if (ref_end < text.len and valid_label) {
                            if (ref_end == ref_start) {
                                // [text][] - use text as label
                                ref_label = text[link_start + 1 .. cb];
                            } else {
                                // [text][ref] - use ref as label
                                ref_label = text[ref_start..ref_end];
                            }
                            end_pos = ref_end + 1;
                        }
                    } else {
                        // [text] - use text as label
                        ref_label = text[link_start + 1 .. cb];
                    }

                    if (ref_label) |label| {
                        // Normalize and look up in refmap
                        const normalized_label = try self.normalizeRefLabel(label);
                        defer self.allocator.free(normalized_label);

                        if (self.refmap.get(normalized_label)) |ref_def| {
                            // Flush any pending text
                            if (pos > text_start) {
                                try self.addTextNode(parent, text[text_start..pos]);
                            }

                            // Create link or image node
                            const link_node = if (is_image)
                                try Node.create(self.arena_allocator, .image)
                            else
                                try Node.create(self.arena_allocator, .link);

                            link_node.link_url = ref_def.url;
                            link_node.link_title = ref_def.title;

                            // Parse link text as inlines (set inside_link flag to prevent nesting)
                            const link_text = text[link_start + 1 .. cb];
                            const was_inside_link = self.inside_link;
                            self.inside_link = true;
                            try self.parseInlines(link_node, link_text);
                            self.inside_link = was_inside_link;

                            parent.appendChild(link_node);

                            pos = end_pos;
                            text_start = pos;
                            continue;
                        }
                    }
                }
            }

            // Check for HTML entity
            if (ch == '&') {
                if (entities.decodeEntity(text, pos)) |result| {
                    // Flush any pending text
                    if (pos > text_start) {
                        try self.addTextNode(parent, text[text_start..pos]);
                    }

                    // Add the decoded entity as text
                    try self.addTextNode(parent, result.str);
                    pos += result.len;
                    text_start = pos;
                    continue;
                }
            }

            // Check for backslash escape
            if (ch == '\\' and pos + 1 < text.len) {
                const next_ch = text[pos + 1];
                if (isAsciiPunctuation(next_ch)) {
                    // Flush any pending text
                    if (pos > text_start) {
                        try self.addTextNode(parent, text[text_start..pos]);
                    }

                    // Add the escaped character as text
                    try self.addTextNode(parent, text[pos + 1 .. pos + 2]);
                    pos += 2;
                    text_start = pos;
                    continue;
                }
            }

            // Check for hard line break (two spaces + newline or backslash + newline)
            if (ch == '\n') {
                var has_hard_break = false;
                var text_end = pos;
                
                // Check if preceded by two or more spaces
                if (pos >= 2 and text[pos - 1] == ' ' and text[pos - 2] == ' ') {
                    has_hard_break = true;
                    // Remove ALL trailing spaces from pending text
                    text_end = pos - 1;
                    while (text_end > text_start and text[text_end - 1] == ' ') {
                        text_end -= 1;
                    }
                } 
                // Check if preceded by backslash
                else if (pos >= 1 and text[pos - 1] == '\\') {
                    has_hard_break = true;
                    // Remove the backslash from pending text
                    text_end = pos - 1;
                }

                if (has_hard_break) {
                    // Add text before the line break marker
                    if (text_end > text_start) {
                        try self.addTextNode(parent, text[text_start .. text_end]);
                    }
                    const br = try Node.create(self.arena_allocator, .linebreak);
                    parent.appendChild(br);
                    pos += 1;
                    text_start = pos;
                    continue;
                } else {
                    // Soft break
                    if (pos > text_start) {
                        try self.addTextNode(parent, text[text_start..pos]);
                    }
                    const sb = try Node.create(self.arena_allocator, .softbreak);
                    parent.appendChild(sb);
                    pos += 1;
                    text_start = pos;
                    continue;
                }
            }
            pos += 1;
        }

        // Flush any remaining text
        if (pos > text_start) {
            try self.addTextNode(parent, text[text_start..pos]);
        }

        // Process emphasis delimiters
        if (delimiters.items.len > 0) {
            try self.processEmphasisStack(parent, delimiters.items[0]);
        }
    }

    fn addTextNode(self: *InlineParser, parent: *Node, text: []const u8) !void {
        if (text.len == 0) return;
        const node = try Node.create(self.arena_allocator, .text);
        node.literal = try self.arena_allocator.dupe(u8, text);
        parent.appendChild(node);
    }

    // Convert line endings to spaces (for code spans)
    // Does NOT collapse multiple spaces - only converts newlines
    fn convertLineEndingsToSpaces(self: *InlineParser, text: []const u8) ![]u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, text.len);
        errdefer result.deinit(self.allocator);

        for (text) |ch| {
            if (ch == '\n' or ch == '\r') {
                try result.append(self.allocator, ' ');
            } else {
                try result.append(self.allocator, ch);
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn collapseWhitespace(self: *InlineParser, text: []const u8) ![]u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, text.len);
        errdefer result.deinit(self.allocator);

        var in_whitespace = false;
        for (text) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
                if (!in_whitespace) {
                    try result.append(self.allocator, ' ');
                    in_whitespace = true;
                }
            } else {
                try result.append(self.allocator, ch);
                in_whitespace = false;
            }
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn isAsciiPunctuation(ch: u8) bool {
        return switch (ch) {
            '!', '"', '#', '$', '%', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/',
            ':', ';', '<', '=', '>', '?', '@', '[', '\\', ']', '^', '_', '`', '{', '|', '}', '~' => true,
            else => false,
        };
    }

    fn parseAutolink(self: *InlineParser, text: []const u8, pos: usize) !?struct { url: []const u8, len: usize } {
        if (pos >= text.len or text[pos] != '<') return null;

        const i = pos + 1;
        if (i >= text.len) return null;

        // Try to parse as URI autolink
        // Scheme: 2-32 chars of alphanumeric, +, ., -
        var scheme_end: usize = i;
        while (scheme_end < text.len and scheme_end < i + 32) {
            const ch = text[scheme_end];
            if (ch == ':') break;
            if (!isAlphaNumeric(ch) and ch != '+' and ch != '.' and ch != '-') {
                break;
            }
            scheme_end += 1;
        }

        if (scheme_end > i + 1 and scheme_end < i + 33 and scheme_end < text.len and text[scheme_end] == ':') {
            // Valid scheme, now parse the rest of the URI
            var uri_end = scheme_end + 1;
            while (uri_end < text.len) {
                const ch = text[uri_end];
                if (ch == '>') {
                    // Found closing >
                    const url = text[i..uri_end];
                    return .{ .url = try self.arena_allocator.dupe(u8, url), .len = uri_end + 1 - pos };
                }
                if (ch == '<' or ch == ' ' or ch == '\n' or ch == '\r') {
                    // Invalid character in URI
                    return null;
                }
                uri_end += 1;
            }
            return null;
        }

        // Try to parse as email autolink
        // Per spec: one or more chars from specific set, @, one or more label chars
        // Local part: a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-
        // Domain part: a-zA-Z0-9.-_  (must contain at least one .)
        var email_end = i;
        var has_at = false;
        var has_dot_after_at = false;
        var at_pos: usize = 0;

        while (email_end < text.len) {
            const ch = text[email_end];
            if (ch == '>') {
                if (has_at and has_dot_after_at and email_end > i) {
                    // Valid email
                    const email = text[i..email_end];
                    const url = try std.fmt.allocPrint(self.arena_allocator, "mailto:{s}", .{email});
                    return .{ .url = url, .len = email_end + 1 - pos };
                }
                return null;
            }
            if (ch == '@') {
                if (has_at) return null; // Multiple @
                if (email_end == i) return null; // Empty local part
                has_at = true;
                at_pos = email_end;
            } else if (ch == '.') {
                if (has_at) {
                    has_dot_after_at = true;
                }
                // Dots are valid in both parts
            } else if (ch == '<' or ch == ' ' or ch == '\n' or ch == '\r' or ch == '\t') {
                return null;
            } else if (has_at) {
                // Domain part: only alphanumeric, -, _
                if (!isAlphaNumeric(ch) and ch != '-' and ch != '_') {
                    return null;
                }
            } else {
                // Local part: more permissive set
                if (!isAlphaNumeric(ch) and ch != '!' and ch != '#' and ch != '$' and ch != '%' and
                    ch != '&' and ch != '\'' and ch != '*' and ch != '+' and ch != '/' and ch != '=' and
                    ch != '?' and ch != '^' and ch != '_' and ch != '`' and ch != '{' and ch != '|' and
                    ch != '}' and ch != '~' and ch != '-') {
                    return null;
                }
            }
            email_end += 1;
        }

        return null;
    }

    fn parseRawHtml(self: *InlineParser, text: []const u8, pos: usize) !?usize {
        _ = self;
        if (pos >= text.len or text[pos] != '<') return null;

        var i = pos + 1;
        if (i >= text.len) return null;

        const ch = text[i];

        // HTML comment: <!--
        if (ch == '!' and i + 2 < text.len and text[i + 1] == '-' and text[i + 2] == '-') {
            i += 3;
            // Find closing -->
            while (i + 2 < text.len) {
                if (text[i] == '-' and text[i + 1] == '-' and text[i + 2] == '>') {
                    return i + 3 - pos;
                }
                i += 1;
            }
            return null;
        }

        // Processing instruction: <?
        if (ch == '?') {
            i += 1;
            // Find closing ?>
            while (i + 1 < text.len) {
                if (text[i] == '?' and text[i + 1] == '>') {
                    return i + 2 - pos;
                }
                i += 1;
            }
            return null;
        }

        // Declaration: <!
        if (ch == '!' and i + 1 < text.len and isUppercaseAlpha(text[i + 1])) {
            i += 1;
            // Find closing >
            while (i < text.len) {
                if (text[i] == '>') {
                    return i + 1 - pos;
                }
                i += 1;
            }
            return null;
        }

        // CDATA: <![CDATA[
        if (ch == '!' and i + 7 < text.len) {
            const cdata = text[i..i + 8];
            if (std.mem.eql(u8, cdata, "![CDATA[")) {
                i += 8;
                // Find closing ]]>
                while (i + 2 < text.len) {
                    if (text[i] == ']' and text[i + 1] == ']' and text[i + 2] == '>') {
                        return i + 3 - pos;
                    }
                    i += 1;
                }
                return null;
            }
        }

        // Closing tag: </
        if (ch == '/') {
            i += 1;
            if (i >= text.len or !isAlpha(text[i])) return null;

            // Skip tag name
            while (i < text.len and (isAlphaNumeric(text[i]) or text[i] == '-')) {
                i += 1;
            }

            // Skip whitespace
            while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n')) {
                i += 1;
            }

            // Must end with >
            if (i < text.len and text[i] == '>') {
                return i + 1 - pos;
            }
            return null;
        }

        // Opening tag or self-closing tag
        if (isAlpha(ch)) {
            // Skip tag name
            while (i < text.len and (isAlphaNumeric(text[i]) or text[i] == '-')) {
                i += 1;
            }

            // Parse attributes
            while (i < text.len) {
                // Skip whitespace
                while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n')) {
                    i += 1;
                }

                if (i >= text.len) return null;

                // Check for end of tag
                if (text[i] == '>') {
                    return i + 1 - pos;
                }

                // Check for self-closing tag
                if (text[i] == '/' and i + 1 < text.len and text[i + 1] == '>') {
                    return i + 2 - pos;
                }

                // Parse attribute name
                if (!isAlpha(text[i]) and text[i] != '_' and text[i] != ':') {
                    return null;
                }

                while (i < text.len and (isAlphaNumeric(text[i]) or text[i] == '_' or text[i] == ':' or text[i] == '.' or text[i] == '-')) {
                    i += 1;
                }

                if (i >= text.len) return null;

                // Skip whitespace
                while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n')) {
                    i += 1;
                }

                if (i >= text.len) return null;

                // Check for attribute value
                if (text[i] == '=') {
                    i += 1;

                    // Skip whitespace
                    while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n')) {
                        i += 1;
                    }

                    if (i >= text.len) return null;

                    // Parse attribute value
                    if (text[i] == '"' or text[i] == '\'') {
                        const quote = text[i];
                        i += 1;
                        while (i < text.len and text[i] != quote) {
                            i += 1;
                        }
                        if (i >= text.len) return null;
                        i += 1; // Skip closing quote
                    } else {
                        // Unquoted value
                        while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '\n' and text[i] != '>' and text[i] != '"' and text[i] != '\'' and text[i] != '=' and text[i] != '<' and text[i] != '`') {
                            i += 1;
                        }
                    }
                }
            }
            return null;
        }

        return null;
    }

    fn isAlpha(ch: u8) bool {
        return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z');
    }

    fn isUppercaseAlpha(ch: u8) bool {
        return ch >= 'A' and ch <= 'Z';
    }

    fn isAlphaNumeric(ch: u8) bool {
        return isAlpha(ch) or (ch >= '0' and ch <= '9');
    }

    fn normalizeRefLabel(self: *InlineParser, label: []const u8) ![]u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, label.len);
        errdefer result.deinit(self.allocator);

        var in_whitespace = false;
        var i: usize = 0;
        while (i < label.len) : (i += 1) {
            const ch = label[i];

            // According to CommonMark spec, backslash escapes are NOT processed during label normalization
            // Only case-folding, whitespace collapsing, and trimming are performed

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
        var start: usize = 0;
        while (start < s.len and s[start] == ' ') {
            start += 1;
        }
        var end: usize = s.len;
        while (end > start and s[end - 1] == ' ') {
            end -= 1;
        }

        if (start > 0 or end < s.len) {
            const trimmed = try self.allocator.dupe(u8, s[start..end]);
            result.deinit(self.allocator);
            return trimmed;
        }

        return result.toOwnedSlice(self.allocator);
    }

    fn processEscapes(self: *InlineParser, text: []const u8) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, text.len);
        errdefer result.deinit(self.allocator);

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

        return result.toOwnedSlice(self.allocator);
    }

    // Process both backslash escapes and HTML entities in a string
    // Used for URLs and titles in links/images
    fn processEscapesAndEntities(self: *InlineParser, text: []const u8) ![]const u8 {
        var result = try std.ArrayList(u8).initCapacity(self.allocator, text.len);
        errdefer result.deinit(self.allocator);

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

        return result.toOwnedSlice(self.allocator);
    }
};
