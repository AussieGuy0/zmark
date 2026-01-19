const std = @import("std");

pub const NodeType = enum {
    // Block nodes
    document,
    block_quote,
    list,
    list_item,
    code_block,
    html_block,
    paragraph,
    heading,
    thematic_break,

    // Inline nodes
    text,
    softbreak,
    linebreak,
    code,
    html_inline,
    emph,
    strong,
    link,
    image,
};

pub const ListType = enum {
    bullet,
    ordered,
};

pub const ListData = struct {
    type: ListType,
    tight: bool,
    bullet_char: u8, // '-', '+', '*'
    delimiter: u8, // '.' or ')'
    start: u32, // Starting number for ordered lists
    padding: u32, // Spaces after marker
};

pub const RefDef = struct {
    url: []const u8,
    title: ?[]const u8,
};

pub const Node = struct {
    type: NodeType,

    // Tree structure
    parent: ?*Node = null,
    first_child: ?*Node = null,
    last_child: ?*Node = null,
    prev: ?*Node = null,
    next: ?*Node = null,

    // Content
    literal: ?[]const u8 = null,

    // Attributes for specific node types
    heading_level: u8 = 0,
    list_data: ?ListData = null,
    code_info: ?[]const u8 = null, // Language info for code blocks
    link_url: ?[]const u8 = null,
    link_title: ?[]const u8 = null,

    // List item content indentation (spaces needed for content to be part of item)
    indent: usize = 0,

    // Source location
    start_line: usize = 0,
    end_line: usize = 0,
    start_column: usize = 0,

    pub fn create(allocator: std.mem.Allocator, node_type: NodeType) !*Node {
        const node = try allocator.create(Node);
        node.* = Node{
            .type = node_type,
        };
        return node;
    }

    pub fn appendChild(self: *Node, child: *Node) void {
        child.parent = self;
        if (self.last_child) |last| {
            last.next = child;
            child.prev = last;
            self.last_child = child;
        } else {
            self.first_child = child;
            self.last_child = child;
        }
    }

    pub fn insertAfter(self: *Node, sibling: *Node) void {
        sibling.next = self.next;
        sibling.prev = self;
        if (self.next) |next| {
            next.prev = sibling;
        } else if (self.parent) |parent| {
            parent.last_child = sibling;
        }
        self.next = sibling;
        sibling.parent = self.parent;
    }

    pub fn insertBefore(self: *Node, sibling: *Node) void {
        sibling.prev = self.prev;
        sibling.next = self;
        if (self.prev) |prev| {
            prev.next = sibling;
        } else if (self.parent) |parent| {
            parent.first_child = sibling;
        }
        self.prev = sibling;
        sibling.parent = self.parent;
    }

    pub fn unlink(self: *Node) void {
        if (self.prev) |prev| {
            prev.next = self.next;
        } else if (self.parent) |parent| {
            parent.first_child = self.next;
        }

        if (self.next) |next| {
            next.prev = self.prev;
        } else if (self.parent) |parent| {
            parent.last_child = self.prev;
        }

        self.parent = null;
        self.next = null;
        self.prev = null;
    }

    pub fn isContainer(self: *Node) bool {
        return switch (self.type) {
            .document, .block_quote, .list, .list_item => true,
            else => false,
        };
    }

    pub fn canContain(self: *Node, child_type: NodeType) bool {
        return switch (self.type) {
            .document => switch (child_type) {
                .block_quote, .list, .code_block, .html_block,
                .paragraph, .heading, .thematic_break => true,
                else => false,
            },
            .block_quote => switch (child_type) {
                .block_quote, .list, .code_block, .html_block,
                .paragraph, .heading, .thematic_break => true,
                else => false,
            },
            .list => child_type == .list_item,
            .list_item => switch (child_type) {
                .block_quote, .list, .code_block, .html_block,
                .paragraph, .heading, .thematic_break => true,
                else => false,
            },
            .paragraph, .heading => switch (child_type) {
                .text, .softbreak, .linebreak, .code, .html_inline,
                .emph, .strong, .link, .image => true,
                else => false,
            },
            .emph, .strong, .link, .image => switch (child_type) {
                .text, .softbreak, .linebreak, .code, .html_inline,
                .emph, .strong, .link, .image => true,
                else => false,
            },
            else => false,
        };
    }
};
