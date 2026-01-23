const std = @import("std");
const Node = @import("node.zig").Node;
const NodeType = @import("node.zig").NodeType;

pub const HtmlRenderer = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) !HtmlRenderer {
        return HtmlRenderer{
            .allocator = allocator,
            .buffer = try std.ArrayList(u8).initCapacity(allocator, 4096),
        };
    }

    pub fn deinit(self: *HtmlRenderer) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn render(self: *HtmlRenderer, root: *Node) ![]u8 {
        try self.renderNode(root);
        return self.buffer.toOwnedSlice(self.allocator);
    }

    fn renderNode(self: *HtmlRenderer, node: *Node) !void {
        switch (node.type) {
            .document => {
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
            },
            .paragraph => {
                // Check if paragraph is empty (only whitespace text nodes and softbreaks)
                var has_content = false;
                var child_check = node.first_child;
                while (child_check) |c| {
                    if (c.type == .text) {
                        if (c.literal) |lit| {
                            // Check if there's any non-whitespace
                            for (lit) |ch| {
                                if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r') {
                                    has_content = true;
                                    break;
                                }
                            }
                        }
                    } else if (c.type != .softbreak and c.type != .linebreak) {
                        // Non-text, non-break node means there's content
                        has_content = true;
                    }
                    if (has_content) break;
                    child_check = c.next;
                }

                // Don't render empty paragraphs
                if (!has_content) {
                    return;
                }

                // Check if we're in a tight list - if so, don't render <p> tags
                // BUT only if the paragraph is a direct child of the list item
                // Paragraphs inside blockquotes, etc. should still get <p> tags
                var in_tight_list = false;
                if (node.parent) |direct_parent| {
                    if (direct_parent.type == .list_item) {
                        // Check if this list item's parent list is tight
                        if (direct_parent.parent) |list| {
                            if (list.type == .list and list.list_data != null) {
                                if (list.list_data.?.tight) {
                                    in_tight_list = true;
                                }
                            }
                        }
                    }
                }

                if (!in_tight_list) {
                    try self.buffer.appendSlice(self.allocator,"<p>");
                }
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
                if (!in_tight_list) {
                    try self.buffer.appendSlice(self.allocator,"</p>\n");
                } else {
                    try self.buffer.appendSlice(self.allocator,"\n");
                }
            },
            .heading => {
                const level = node.heading_level;
                try self.buffer.writer(self.allocator).print("<h{d}>", .{level});
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
                try self.buffer.writer(self.allocator).print("</h{d}>\n", .{level});
            },
            .text => {
                if (node.literal) |lit| {
                    try self.escapeHtml(lit);
                }
            },
            .thematic_break => {
                try self.buffer.appendSlice(self.allocator,"<hr />\n");
            },
            .code_block => {
                try self.buffer.appendSlice(self.allocator,"<pre><code");
                if (node.code_info) |info| {
                    if (info.len > 0) {
                        // Extract first word for language class
                        var lang = info;
                        var space_idx: usize = 0;
                        for (info, 0..) |ch, i| {
                            if (ch == ' ' or ch == '\t') {
                                space_idx = i;
                                break;
                            }
                        }
                        if (space_idx > 0) {
                            lang = info[0..space_idx];
                        }

                        try self.buffer.appendSlice(self.allocator," class=\"language-");
                        try self.escapeHtml(lang);
                        try self.buffer.appendSlice(self.allocator,"\"");
                    }
                }
                try self.buffer.appendSlice(self.allocator,">");
                if (node.literal) |lit| {
                    try self.escapeHtml(lit);
                    // Code blocks always end with a newline
                    if (lit.len > 0) {
                        try self.buffer.appendSlice(self.allocator,"\n");
                    }
                }
                try self.buffer.appendSlice(self.allocator,"</code></pre>\n");
            },
            .block_quote => {
                try self.buffer.appendSlice(self.allocator,"<blockquote>\n");
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
                try self.buffer.appendSlice(self.allocator,"</blockquote>\n");
            },
            .list => {
                const list_data = node.list_data orelse return error.MissingListData;
                if (list_data.type == .ordered) {
                    if (list_data.start != 1) {
                        try self.buffer.writer(self.allocator).print("<ol start=\"{d}\">\n", .{list_data.start});
                    } else {
                        try self.buffer.appendSlice(self.allocator,"<ol>\n");
                    }
                } else {
                    try self.buffer.appendSlice(self.allocator,"<ul>\n");
                }

                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }

                if (list_data.type == .ordered) {
                    try self.buffer.appendSlice(self.allocator,"</ol>\n");
                } else {
                    try self.buffer.appendSlice(self.allocator,"</ul>\n");
                }
            },
            .list_item => {
                // Check if parent list is tight
                const is_tight = if (node.parent) |parent|
                    if (parent.list_data) |ld| ld.tight else false
                else
                    false;

                try self.buffer.appendSlice(self.allocator,"<li>");

                var child = node.first_child;

                // If tight list and single paragraph child, render paragraph contents without <p> tags
                if (is_tight and child != null and child.?.type == .paragraph and child.?.next == null) {
                    // Render paragraph's children directly
                    var para_child = child.?.first_child;
                    while (para_child) |pc| {
                        try self.renderNode(pc);
                        para_child = pc.next;
                    }
                } else {
                    // Render all children normally
                    while (child) |c| {
                        try self.renderNode(c);
                        child = c.next;
                    }
                }

                try self.buffer.appendSlice(self.allocator,"</li>\n");
            },
            .emph => {
                try self.buffer.appendSlice(self.allocator,"<em>");
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
                try self.buffer.appendSlice(self.allocator,"</em>");
            },
            .strong => {
                try self.buffer.appendSlice(self.allocator,"<strong>");
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
                try self.buffer.appendSlice(self.allocator,"</strong>");
            },
            .link => {
                try self.buffer.appendSlice(self.allocator,"<a href=\"");
                if (node.link_url) |url| {
                    try self.encodeUrl(url);
                }
                try self.buffer.appendSlice(self.allocator,"\"");
                if (node.link_title) |title| {
                    try self.buffer.appendSlice(self.allocator," title=\"");
                    try self.escapeHtml(title);
                    try self.buffer.appendSlice(self.allocator,"\"");
                }
                try self.buffer.appendSlice(self.allocator,">");
                var child = node.first_child;
                while (child) |c| {
                    try self.renderNode(c);
                    child = c.next;
                }
                try self.buffer.appendSlice(self.allocator,"</a>");
            },
            .image => {
                try self.buffer.appendSlice(self.allocator,"<img src=\"");
                if (node.link_url) |url| {
                    try self.encodeUrl(url);
                }
                try self.buffer.appendSlice(self.allocator,"\" alt=\"");
                // Render alt text from children (as plain text, not HTML)
                var child = node.first_child;
                while (child) |c| {
                    try self.renderAltText(c);
                    child = c.next;
                }
                try self.buffer.appendSlice(self.allocator,"\"");
                if (node.link_title) |title| {
                    try self.buffer.appendSlice(self.allocator," title=\"");
                    try self.escapeHtml(title);
                    try self.buffer.appendSlice(self.allocator,"\"");
                }
                try self.buffer.appendSlice(self.allocator," />");
            },
            .code => {
                try self.buffer.appendSlice(self.allocator,"<code>");
                if (node.literal) |lit| {
                    try self.escapeHtml(lit);
                }
                try self.buffer.appendSlice(self.allocator,"</code>");
            },
            .linebreak => {
                try self.buffer.appendSlice(self.allocator,"<br />\n");
            },
            .softbreak => {
                try self.buffer.appendSlice(self.allocator,"\n");
            },
            .html_block => {
                if (node.literal) |lit| {
                    try self.buffer.appendSlice(self.allocator, lit);
                }
                // HTML blocks should end with a newline
                try self.buffer.append(self.allocator, '\n');
            },
            .html_inline => {
                if (node.literal) |lit| {
                    try self.buffer.appendSlice(self.allocator, lit);
                }
            },
        }
    }

    fn escapeHtml(self: *HtmlRenderer, s: []const u8) !void {
        for (s) |ch| {
            switch (ch) {
                '&' => try self.buffer.appendSlice(self.allocator,"&amp;"),
                '<' => try self.buffer.appendSlice(self.allocator,"&lt;"),
                '>' => try self.buffer.appendSlice(self.allocator,"&gt;"),
                '"' => try self.buffer.appendSlice(self.allocator,"&quot;"),
                else => try self.buffer.append(self.allocator,ch),
            }
        }
    }

    fn encodeUrl(self: *HtmlRenderer, s: []const u8) !void {
        for (s) |ch| {
            // HTML special characters use HTML entities in href attribute
            if (ch == '&') {
                try self.buffer.appendSlice(self.allocator,"&amp;");
            } else if (ch >= 0x80 or // Non-ASCII (UTF-8 continuation bytes)
                       ch <= 0x20 or // Control chars and space
                       ch == '<' or ch == '>' or ch == '"' or ch == '\\' or
                       ch == '[' or ch == ']' or
                       ch == '{' or ch == '}' or ch == '|' or ch == '^' or ch == '`')
            {
                // Percent-encode other special chars
                const hex = "0123456789ABCDEF";
                try self.buffer.append(self.allocator,'%');
                try self.buffer.append(self.allocator,hex[ch >> 4]);
                try self.buffer.append(self.allocator,hex[ch & 0x0F]);
            } else {
                try self.buffer.append(self.allocator,ch);
            }
        }
    }

    fn renderAltText(self: *HtmlRenderer, node: *Node) !void {
        // Render alt text as plain text (recursively for nested elements)
        switch (node.type) {
            .text => {
                if (node.literal) |lit| {
                    try self.escapeHtml(lit);
                }
            },
            .code => {
                if (node.literal) |lit| {
                    try self.escapeHtml(lit);
                }
            },
            .linebreak, .softbreak => {
                try self.buffer.append(self.allocator,' ');
            },
            .emph, .strong, .link => {
                // For nested elements, just render their children as text
                var child = node.first_child;
                while (child) |c| {
                    try self.renderAltText(c);
                    child = c.next;
                }
            },
            .image => {
                // Nested images shouldn't happen, but if they do, render their alt text
                var child = node.first_child;
                while (child) |c| {
                    try self.renderAltText(c);
                    child = c.next;
                }
            },
            else => {},
        }
    }
};

test "html renderer basic" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const root = try Node.create(arena.allocator(), .document);
    const para = try Node.create(arena.allocator(), .paragraph);
    const text = try Node.create(arena.allocator(), .text);
    text.literal = "Hello World";

    root.appendChild(para);
    para.appendChild(text);

    var renderer = try HtmlRenderer.init(allocator);
    defer renderer.deinit();

    const html = try renderer.render(root);
    defer allocator.free(html);

    try std.testing.expectEqualStrings("<p>Hello World</p>\n", html);
}
