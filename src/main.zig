const std = @import("std");
const Parser = @import("parser.zig").Parser;
const HtmlRenderer = @import("html.zig").HtmlRenderer;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    _ = args.skip(); // Skip program name

    var unsafe_mode = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--unsafe")) {
            unsafe_mode = true;
        } else if (std.mem.eql(u8, arg, "--help")) {
            try printHelp();
            return;
        } else if (std.mem.eql(u8, arg, "--version")) {
            try printVersion();
            return;
        }
    }

    // Read input from stdin
    var input_list = try std.ArrayList(u8).initCapacity(allocator, 4096);
    defer input_list.deinit(allocator);

    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = try std.posix.read(std.posix.STDIN_FILENO, &buffer);
        if (n == 0) break;
        try input_list.appendSlice(allocator, buffer[0..n]);
    }

    const input = try input_list.toOwnedSlice(allocator);
    defer allocator.free(input);

    // Parse markdown
    var parser = try Parser.init(allocator);
    defer parser.deinit();

    const ast = try parser.parse(input);

    // Render HTML
    var renderer = try HtmlRenderer.init(allocator);
    defer renderer.deinit();

    const html = try renderer.render(ast);
    defer allocator.free(html);

    // Write output to stdout
    _ = try std.posix.write(std.posix.STDOUT_FILENO, html);

    // Track unsafe mode for future use
    if (unsafe_mode) {
        // Will be used when HTML blocks are implemented
    }
}

fn printHelp() !void {
    const msg =
        \\zmark - CommonMark parser in Zig
        \\
        \\Usage: zmark [OPTIONS]
        \\
        \\Options:
        \\  --help     Show this help message
        \\  --version  Show version information
        \\  --unsafe   Enable raw HTML passthrough
        \\
        \\Reads markdown from stdin and writes HTML to stdout.
        \\
    ;
    _ = try std.posix.write(std.posix.STDOUT_FILENO, msg);
}

fn printVersion() !void {
    _ = try std.posix.write(std.posix.STDOUT_FILENO, "zmark 0.1.0\n");
}
