# ZMark

A pure Zig implementation of a CommonMark-compliant markdown parser.

## Status

This is an active work-in-progress implementation of the CommonMark specification (version 0.31.2).

## Features

- Pure Zig implementation with no C dependencies
- CommonMark 0.31.2 specification compliance (in progress)
- Clean AST representation
- HTML rendering

### Currently Implemented

- ✅ Block structure parsing (lists, block quotes, code blocks, headings)
- ✅ Container matching for proper nesting
- ✅ Tight/loose list detection and rendering
- ✅ List item content indentation tracking
- ✅ Basic inline parsing (emphasis, strong, links, images, code spans)
- ✅ Link reference definitions
- ✅ HTML block passthrough
- ✅ Fenced and indented code blocks
- ✅ ATX and Setext headings
- ✅ Thematic breaks

### In Progress

- Block quote lazy continuation
- HTML block type detection edge cases
- Link escape handling
- Complex nesting scenarios

## Building

```bash
zig build
```

## Usage

### As a CLI tool

```bash
# Read from stdin, write to stdout
./zig-out/bin/zmark < input.md > output.html

# Or use zig build run
zig build run -- input.md > output.html
```

### Running Tests

```bash
# Run CommonMark spec tests
python3 tests/spec_tests.py --program ./zig-out/bin/zmark --spec tests/spec.txt

# Run specific test
python3 tests/spec_tests.py --program ./zig-out/bin/zmark --spec tests/spec.txt --number 123

# Run tests matching a pattern
python3 tests/spec_tests.py --program ./zig-out/bin/zmark --spec tests/spec.txt --pattern "Lists"
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
│   └── utils.zig          # Utility functions
├── tests/                 # CommonMark test suite
├── build.zig             # Build configuration
└── README.md             # This file
```

## License

MIT

## References

- [CommonMark Spec 0.31.2](https://spec.commonmark.org/0.31.2/)
- [cmark reference implementation](https://github.com/commonmark/cmark)
