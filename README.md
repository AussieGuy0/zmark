# ZMark

A pure Zig CommonMark-compliant markdown parser.

## Features
- Pure Zig implementation with no C dependencies
- CommonMark 0.31.2 specification compliance (passes 644/652 of cmark tests)
- Clean AST representation
- HTML rendering

### Known Limitations
- Tabs edge case in code blocks within lists
- Some tight/loose list detection edge cases
- Complex emphasis/strong nesting edge cases

## Building

```bash
zig build
```

## Usage

### As a Library

Add zmark to your project's `build.zig.zon`:

```bash
zig fetch --save git+https://github.com/AussieGuy0/zmark
```

Then in your `build.zig`:

```zig
const zmark = b.dependency("zmark", .{});
exe.root_module.addImport("zmark", zmark.module("zmark"));
```

Use in your code:

```zig
const std = @import("std");
const zmark = @import("zmark");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parser = try zmark.Parser.init(allocator);
    defer parser.deinit();

    const ast = try parser.parse("# Hello, World!");
    
    var renderer = try zmark.html.HtmlRenderer.init(allocator);
    defer renderer.deinit();
    const output = try renderer.render(ast);
    defer allocator.free(output);
    
    std.debug.print("{s}", .{output});
}
```

### As a CLI tool

```bash
# Read from stdin, write to stdout
./zig-out/bin/zmark < input.md > output.html

# Or use zig build run
zig build run -- input.md > output.html
```

### Running Tests

```bash
# Run all tests (including CommonMark spec tests)
zig build test
```

## Project Structure

```
zmark/
├── src/
│   ├── main.zig           # CLI entry point
│   ├── parser.zig         # Main parser coordinator
│   ├── blocks.zig         # Block-level parsing
│   ├── inlines.zig        # Inline parsing
│   ├── node.zig           # AST node definitions
│   ├── scanner.zig        # Input scanning utilities
│   ├── html.zig           # HTML renderer
│   ├── entities.zig       # HTML entity handling
│   ├── spec_tests.zig     # CommonMark spec test runner
│   └── utils.zig          # Utility functions
├── tests/
│   └── spec.txt           # CommonMark spec test cases
├── build.zig             # Build configuration
└── README.md             # This file
```

## License

MIT

## References

- [CommonMark Spec 0.31.2](https://spec.commonmark.org/0.31.2/)
- [cmark reference implementation](https://github.com/commonmark/cmark)
