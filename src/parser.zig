const std = @import("std");
const Node = @import("node.zig").Node;
const NodeType = @import("node.zig").NodeType;
const RefDef = @import("node.zig").RefDef;
const Scanner = @import("scanner.zig").Scanner;
const BlockParser = @import("blocks.zig").BlockParser;
const InlineParser = @import("inlines.zig").InlineParser;

// Re-export for library usage
pub const html = @import("html.zig");
pub const node = @import("node.zig");

pub const Parser = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    root: *Node,

    pub fn init(allocator: std.mem.Allocator) !Parser {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const arena_allocator = arena.allocator();

        const root = try Node.create(arena_allocator, .document);

        return Parser{
            .allocator = allocator,
            .arena = arena,
            .root = root,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    pub fn parse(self: *Parser, input: []const u8) !*Node {
        // Parse block structure
        const arena_allocator = self.arena.allocator();
        var block_parser = try BlockParser.init(self.allocator, arena_allocator, self.root);
        defer block_parser.deinit();

        try block_parser.parse(input);

        // Parse inline content
        var inline_parser = InlineParser.init(self.allocator, arena_allocator, &block_parser.refmap);
        try inline_parser.processInlines(self.root);

        return self.root;
    }
};

test "parser basic" {
    const allocator = std.testing.allocator;
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    const result = try parser.parse("# Hello World");
    try std.testing.expectEqual(NodeType.document, result.type);
}
