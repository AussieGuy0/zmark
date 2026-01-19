# ZMark - Pure Zig Markdown Parser Implementation Plan

## Overview

This document outlines the implementation plan for ZMark, a pure Zig implementation of a CommonMark-compliant markdown parser. The goal is to pass all tests from the CommonMark specification (version 0.31.2).

## Project Goals

1. Full CommonMark 0.31.2 specification compliance
2. Pure Zig implementation with no C dependencies
3. Pass all 652 examples in `tests/spec.txt`
4. Clean, maintainable, and idiomatic Zig code
5. Good performance with minimal allocations

## Architecture Overview

### Core Components

```
┌─────────────────────────────────────────────────────┐
│                   Main Parser                        │
│  (Coordinates the parsing phases)                   │
└─────────────────────────────────────────────────────┘
                         │
        ┌────────────────┼────────────────┐
        │                │                │
        ▼                ▼                ▼
┌──────────────┐  ┌──────────────┐  ┌──────────────┐
│  Tokenizer   │  │    Block     │  │   Inline     │
│              │  │   Parser     │  │   Parser     │
│ - Input      │  │              │  │              │
│ - Lines      │  │ - Blocks     │  │ - Emphasis   │
│ - Normalize  │  │ - Lists      │  │ - Links      │
│              │  │ - Code       │  │ - Images     │
└──────────────┘  │ - Quotes     │  │ - Code spans │
                  └──────────────┘  └──────────────┘
                         │                │
                         └────────┬───────┘
                                  ▼
                         ┌──────────────┐
                         │     AST      │
                         │  (Document   │
                         │    Tree)     │
                         └──────────────┘
                                  │
                                  ▼
                         ┌──────────────┐
                         │    HTML      │
                         │  Renderer    │
                         └──────────────┘
```

### 1. Tokenizer/Preprocessor
- Read input and split into lines
- Handle tab expansion (tabs = 4 spaces for structure)
- Track line numbers for error reporting
- Handle different line ending types (LF, CR, CRLF)

### 2. Block Parser (Phase 1)
Implements the two-phase parsing strategy per CommonMark spec:
- Parse block structure first (paragraphs, lists, code blocks, quotes, etc.)
- Build preliminary AST of block elements
- Handle container blocks (block quotes, list items)
- Handle leaf blocks (paragraphs, headings, code blocks, thematic breaks)

### 3. Inline Parser (Phase 2)
- Parse inline content within blocks
- Handle emphasis and strong emphasis
- Parse links and images (reference and inline)
- Handle code spans
- Process HTML entities
- Handle backslash escapes

### 4. AST (Abstract Syntax Tree)
- Tree structure representing document
- Each node has type, content, and children
- Supports visitor pattern for rendering

### 5. HTML Renderer
- Traverse AST and generate HTML
- Proper escaping of special characters
- Normalize output to match CommonMark expectations

## Implementation Phases

### Phase 1: Project Setup & Foundation (Week 1)
**Goal**: Basic project structure and utilities

**Tasks**:
1. Initialize Zig project with `build.zig`
2. Set up project directory structure
3. Implement basic types and data structures:
   - `Node` type for AST
   - `NodeType` enum (all block and inline types)
   - `Document` type
   - Arena allocator strategy
4. Implement input handling:
   - Line reader
   - Tab expansion
   - Line ending normalization
5. Create CLI tool that works with existing Python test infrastructure:
   - Build executable that reads markdown from stdin and outputs HTML to stdout
   - Ensure compatibility with `spec_tests.py` (takes markdown, produces HTML)
   - The existing Python tests (`spec_tests.py`, `pathological_tests.py`, etc.) will be used directly
   - Optional: Add Zig unit tests for individual components

### Phase 2: Block Structure Parser (Week 2-3)
**Goal**: Parse all block-level elements

**Priority order** (from simpler to more complex):
1. **Thematic breaks** (`---`, `***`, `___`)
2. **ATX headings** (`# Heading`)
3. **Indented code blocks** (4-space indented)
4. **Fenced code blocks** (backticks and tildes)
5. **HTML blocks** (passthrough)
6. **Paragraphs** (basic text blocks)
7. **Blank lines** (block separators)
8. **Block quotes** (`> quote`)
9. **Lists**:
   - Unordered lists (`-`, `*`, `+`)
   - Ordered lists (`1.`, `2.`)
   - Nested lists
   - Tight vs loose lists
10. **Setext headings** (`Heading\n====`)

**Implementation strategy**:
- Container block parsing (quotes, lists)
- Leaf block parsing (paragraphs, code, headings)
- Proper precedence and interruption rules

### Phase 3: Inline Parser (Week 3-4)
**Goal**: Parse all inline elements

**Priority order**:
1. **Text and line breaks**
2. **Backslash escapes** (`\*`, `\[`, etc.)
3. **Code spans** (`` `code` ``)
4. **HTML entities** (`&amp;`, `&#35;`, etc.)
5. **Emphasis and strong** (`*em*`, `**strong**`)
6. **Links**:
   - Inline links `[text](url)`
   - Reference links `[text][ref]`
   - Autolinks `<url>`
7. **Images** (same structure as links)
8. **Hard and soft line breaks**

**Key challenges**:
- Delimiter run processing for emphasis
- Link reference definition parsing
- Proper precedence between different inline elements

### Phase 4: HTML Rendering (Week 4)
**Goal**: Generate correct HTML output

**Tasks**:
1. AST visitor implementation
2. HTML entity escaping
3. Attribute generation (for code blocks, links)
4. Pretty-printing (proper newlines and indentation)
5. Match CommonMark normalization rules

### Phase 5: Testing & Compliance (Week 5-6)
**Goal**: Pass all CommonMark spec tests

**Process**:
1. Run against all 652 spec examples
2. Fix failures systematically by category:
   - Block structure tests
   - Inline tests
   - Edge cases
3. Add debugging output for failures
4. Iterate until 100% pass rate

### Phase 6: Optimization & Polish (Week 6-7)
**Goal**: Performance and code quality

**Tasks**:
1. Profile memory usage
2. Optimize allocations
3. Add benchmarks
4. Code cleanup and documentation
5. Add examples and usage documentation

## Data Structures

### AST Node
```zig
const NodeType = enum {
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

const Node = struct {
    type: NodeType,
    parent: ?*Node,
    first_child: ?*Node,
    last_child: ?*Node,
    prev: ?*Node,
    next: ?*Node,

    // Content
    literal: ?[]const u8,

    // Attributes (for specific node types)
    heading_level: u8,
    list_data: ?ListData,
    code_info: ?[]const u8,
    link_url: ?[]const u8,
    link_title: ?[]const u8,

    // Source location
    start_line: usize,
    end_line: usize,
};
```

### Parser State
```zig
const Parser = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,

    // Input
    input: []const u8,
    lines: std.ArrayList([]const u8),

    // AST
    root: *Node,
    current: *Node,

    // State
    tip: *Node, // Deepest open block
    offset: usize,
    column: usize,

    // Reference definitions
    refmap: std.StringHashMap(RefDef),
};
```

## Testing Strategy

### Unit Tests
- Test each component in isolation
- Use Zig's built-in testing framework
- Focus on edge cases

### Integration Tests (Using Existing Python Infrastructure)
We'll use the existing Python test infrastructure from the cmark project:

**Main test suite**:
```bash
python3 tests/spec_tests.py --program ./zig-out/bin/zmark --spec tests/spec.txt
```

The Python test runner (`spec_tests.py`) will:
- Parse `spec.txt` format and extract all 652 examples
- Run our Zig executable for each test, passing markdown via stdin
- Capture HTML output from stdout
- Normalize both expected and actual HTML
- Compare and report differences

**Additional test suites**:
- `pathological_tests.py` - Stress tests for performance
- `regression.txt` - Regression test cases
- `smart_punct.txt` - Smart punctuation tests (optional feature)

**Our CLI must**:
- Read markdown from stdin (UTF-8 encoded)
- Write HTML to stdout (UTF-8 encoded)
- Accept `--unsafe` flag (enables raw HTML passthrough, required for tests)
- Exit with code 0 on success
- Be compatible with the Python test harness expectations

**Note**: The Python test runner automatically adds `--unsafe` when invoking our program (see `tests/cmark.py:67`)

### Test Categories (from spec)
1. Tabs
2. Precedence
3. Thematic breaks
4. ATX headings
5. Setext headings
6. Indented code blocks
7. Fenced code blocks
8. HTML blocks
9. Link reference definitions
10. Paragraphs
11. Blank lines
12. Block quotes
13. List items
14. Lists
15. Inlines
16. Code spans
17. Emphasis and strong emphasis
18. Links
19. Images
20. Autolinks
21. Raw HTML
22. Hard line breaks
23. Soft line breaks
24. Textual content

## Key Algorithms

### Block Parsing Algorithm
1. For each line:
   - Check if it continues current open blocks
   - Close blocks that are interrupted
   - Open new blocks as needed
   - Add content to appropriate block
2. After all lines processed, close all open blocks

### Inline Parsing Algorithm
1. Scan for delimiter runs (`*`, `_`, `` ` ``, `[`, `!`)
2. Build delimiter stack
3. Process emphasis using delimiter matching rules
4. Process links using reference definitions
5. Merge adjacent text nodes

### Delimiter Run Rules (for emphasis)
- Left-flanking: not followed by whitespace, and either:
  - Not followed by punctuation, or
  - Followed by punctuation and preceded by whitespace or punctuation
- Right-flanking: symmetric to left-flanking
- Can open emphasis: left-flanking and (`_` + not right-flanking or preceded by punctuation)
- Can close emphasis: right-flanking and (`_` + not left-flanking or followed by punctuation)

## File Structure

```
zmark/
├── build.zig              # Build configuration
├── src/
│   ├── main.zig          # CLI entry point
│   ├── parser.zig        # Main parser coordinator
│   ├── blocks.zig        # Block-level parsing
│   ├── inlines.zig       # Inline parsing
│   ├── node.zig          # AST node definitions
│   ├── scanner.zig       # Input scanning utilities
│   ├── html.zig          # HTML renderer
│   ├── entities.zig      # HTML entity handling
│   └── utils.zig         # Utility functions
├── tests/
│   ├── spec.txt          # CommonMark spec tests
│   ├── test_runner.zig   # Test harness
│   └── ...               # Other test files
├── examples/
│   └── simple.zig        # Usage examples
├── IMPLEMENTATION_PLAN.md # This file
├── TODO.md               # Detailed task list
└── README.md             # Project documentation
```

## Error Handling Strategy

Since CommonMark parsers should be very permissive:
- No syntax errors in markdown (everything is valid)
- Internal errors (OOM, etc.) use Zig error handling
- Allocation failures are propagated up
- Use arena allocator for AST (single free at end)

## Performance Considerations

1. **Memory**:
   - Use arena allocator for AST nodes
   - Minimize allocations in hot paths
   - Reuse string buffers where possible

2. **Speed**:
   - Single-pass block parsing
   - Efficient delimiter scanning for inlines
   - Avoid unnecessary string copies
   - Use string views where possible

## References

- [CommonMark Spec 0.31.2](https://spec.commonmark.org/0.31.2/)
- [cmark reference implementation](https://github.com/commonmark/cmark)
- CommonMark test suite in `tests/` directory

## Success Criteria

- [ ] All 652 spec.txt tests pass
- [ ] Clean, documented code
- [ ] Memory-safe (no leaks in test runs)
- [ ] Reasonable performance (comparable to cmark for basic use)
- [ ] Usable as library and CLI tool
