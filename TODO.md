# ZMark Implementation TODO List

## Legend
- [ ] Not started
- [x] Completed
- [~] In progress
- [!] Blocked/Issues

---

## Phase 2: Block Structure Parser

### Basic Block Infrastructure ✅
- [x] Implement `src/blocks.zig` - Block parsing foundation
  - [x] Define `BlockParser` struct
    - [x] Parser state (current line, offset, column)
    - [x] Open blocks stack (tip)
    - [x] Arena allocator
  - [x] Implement `parse()` main entry point
  - [x] Implement block continuation checking (container matching algorithm)
  - [x] Implement block finalization

### Simple Leaf Blocks (Implement First)
- [x] **Blank lines** ✅
  - [x] Detection (line with only spaces/tabs)
  - [x] Tests: spec examples in "Blank lines" section (1/1 passing)

- [~] **Thematic breaks** (12/19 passing)
  - [x] Detection: 3+ `*`, `-`, or `_` with optional spaces
  - [x] Not confused with setext heading or list
  - [~] Tests: spec examples in "Thematic breaks" section

- [~] **ATX headings** (13/18 passing)
  - [x] Parse `#` markers (1-6)
  - [x] Extract heading text
  - [~] Handle closing `#` sequences (optional) - some edge cases remain
  - [~] Tests: spec examples in "ATX headings" section

- [x] **Indented code blocks** (11/12 passing) ✅
  - [x] Detect 4-space indentation
  - [x] Handle blank lines within block
  - [x] Remove indentation from content
  - [x] Trim trailing blank lines when closing
  - [~] Tests: spec examples in "Indented code blocks" section (1 edge case remaining)

- [~] **Fenced code blocks** (basic implementation, some edge cases remain)
  - [x] Parse opening fence (3+ backticks or tildes)
  - [x] Parse info string
  - [x] Parse closing fence (same character, >= opening length)
  - [~] Handle content (indentation handling needs work)
  - [~] Tests: spec examples in "Fenced code blocks" section

### HTML Blocks
- [ ] **HTML blocks**
  - [ ] Implement 7 HTML block start conditions (per spec)
  - [ ] Implement corresponding end conditions
  - [ ] Pass through content without parsing
  - [ ] Tests: spec examples in "HTML blocks" section

### Paragraphs
- [~] **Paragraphs**
  - [x] Basic paragraph creation
  - [~] Lazy continuation lines (needs refinement)
  - [~] Interruption by other blocks (edge cases remain)
  - [~] Tests: spec examples in "Paragraphs" section

- [~] **Setext headings**
  - [x] Detect underline (`===` or `---`)
  - [x] Convert paragraph to heading
  - [~] Handle precedence with thematic breaks (issues remain)
  - [~] Tests: spec examples in "Setext headings" section

### Container Blocks
- [~] **Block quotes** (11 failures remain)
  - [x] Detect `>` marker
  - [x] Handle continuation with `>`
  - [x] Nested block quotes
  - [x] Can contain other block elements (lists, code, etc.)
  - [ ] Lazy continuation (paragraphs without `>`)
  - [~] Tests: spec examples in "Block quotes" section

- [x] **List items** (20/40 failures fixed) ✅
  - [x] Detect list markers:
    - [x] Unordered: `-`, `+`, `*`
    - [x] Ordered: `1.`, `2)`, etc.
  - [x] Calculate content indentation correctly
  - [x] Account for stripped indentation in indent calculation
  - [x] Handle blank lines within list items
  - [x] Container matching for list item continuation
  - [x] Can contain nested blocks (code, quotes, lists)
  - [~] Tests: spec examples in "List items" section (20 edge cases remaining)

- [x] **Lists** (17/26 failures fixed) ✅
  - [x] Detect list start
  - [x] Tight vs loose lists - properly implemented
  - [x] Render tight lists without `<p>` tags for single paragraphs
  - [x] Nested lists
  - [x] List item interruption rules
  - [x] Changing list type/delimiter
  - [x] Start number for ordered lists
  - [x] Close lists when non-list-item content appears
  - [~] Tests: spec examples in "Lists" section (17 edge cases remaining)

### Link Reference Definitions
- [~] **Link reference definitions**
  - [x] Parse syntax: `[label]: url "title"`
  - [x] Store in reference map
  - [x] Remove from AST (don't render)
  - [x] Handle multiline titles
  - [~] Tests: spec examples in "Link reference definitions" section (label normalization issues)

### Block Parser Integration
- [ ] Integrate all block types into main parser loop
- [ ] Implement precedence rules
- [ ] Implement interruption rules
- [ ] Handle edge cases for block transitions
- [ ] Run block-level tests from spec

---

## Phase 3: Inline Parser

### Inline Infrastructure
- [ ] Implement `src/inlines.zig` - Inline parsing foundation
  - [ ] Define `InlineParser` struct
    - [ ] Input position/offset
    - [ ] Delimiter stack
    - [ ] Reference map access
  - [ ] Implement `parseInlines()` entry point
  - [ ] Implement delimiter scanning

### Basic Inlines
- [ ] **Plain text**
  - [ ] Text node creation
  - [ ] Text accumulation
  - [ ] Adjacent text merging

- [ ] **Backslash escapes**
  - [ ] Detect `\` followed by ASCII punctuation
  - [ ] Generate literal character
  - [ ] Tests: spec examples in "Backslash escapes" section

- [ ] **Line breaks**
  - [ ] Hard line breaks (two spaces + newline, or backslash + newline)
  - [ ] Soft line breaks (normal newlines)
  - [ ] Tests: spec examples in "Hard line breaks" and "Soft line breaks"

### Code Spans
- [ ] **Code spans**
  - [ ] Parse backtick delimiters
  - [ ] Handle multiple backticks
  - [ ] Collapse whitespace
  - [ ] Strip single space padding
  - [ ] Tests: spec examples in "Code spans" section

### HTML Entities & Inline HTML
- [ ] Implement `src/entities.zig` - HTML entity handling
  - [ ] Named entities map (`&amp;`, `&lt;`, etc.)
  - [ ] Decimal entities (`&#35;`)
  - [ ] Hexadecimal entities (`&#x1F;`)
  - [ ] Entity decoding

- [ ] **Raw HTML inline**
  - [ ] Detect HTML tags
  - [ ] Parse tag structure
  - [ ] Pass through without modification
  - [ ] Tests: spec examples in "Raw HTML" section

### Emphasis and Strong Emphasis
- [ ] **Emphasis/Strong implementation**
  - [ ] Detect delimiter runs (`*`, `_`)
  - [ ] Determine left/right-flanking
  - [ ] Implement can-open/can-close rules
  - [ ] Push delimiters to stack
  - [ ] Process delimiter stack:
    - [ ] Look for matching pairs
    - [ ] Handle precedence (`***` -> strong vs em)
    - [ ] Remove used delimiters
  - [ ] Tests: spec examples in "Emphasis and strong emphasis" section
    - [ ] Basic cases
    - [ ] Intraword emphasis
    - [ ] Nested emphasis
    - [ ] Multiple delimiters
    - [ ] Edge cases

### Links and Images
- [ ] **Links** (most complex inline element)
  - [ ] Detect `[` opener
  - [ ] Track potential link text
  - [ ] Parse link destination:
    - [ ] Inline: `(url "title")`
    - [ ] Reference: `[ref]`, `[]`, or just text
  - [ ] Handle nested brackets
  - [ ] Parse URL:
    - [ ] Angle-bracket form: `<url>`
    - [ ] Bare URL with balanced parens
  - [ ] Parse title (optional, in quotes, apostrophes, or parens)
  - [ ] Resolve reference links from refmap
  - [ ] Tests: spec examples in "Links" section

- [ ] **Autolinks**
  - [ ] Detect `<url>` or `<email>`
  - [ ] Validate URL/email format
  - [ ] Create link node
  - [ ] Tests: spec examples in "Autolinks" section

- [ ] **Images**
  - [ ] Detect `![` opener
  - [ ] Same parsing as links
  - [ ] Create image node instead of link
  - [ ] Tests: spec examples in "Images" section

### Inline Parser Integration
- [ ] Integrate all inline types
- [ ] Implement precedence rules
- [ ] Handle delimiter priority
- [ ] Run inline tests from spec

---

## Phase 4: HTML Rendering

### HTML Renderer Foundation
- [ ] Implement `src/html.zig` - HTML rendering
  - [ ] Define `HtmlRenderer` struct
    - [ ] Output buffer
    - [ ] Escaping functions
  - [ ] Implement `render()` entry point
  - [ ] AST traversal (visitor pattern)

### Block Rendering
- [ ] Render block nodes:
  - [ ] Document (wrapper)
  - [ ] Paragraphs (`<p>...</p>`)
  - [ ] Headings (`<h1>` through `<h6>`)
  - [ ] Code blocks (`<pre><code>...</code></pre>`)
    - [ ] Info string as class attribute
  - [ ] Block quotes (`<blockquote>...</blockquote>`)
  - [ ] Lists (`<ul>`, `<ol>`)
    - [ ] Start attribute for ordered lists
  - [ ] List items (`<li>...</li>`)
    - [ ] Tight vs loose (no `<p>` in tight)
  - [ ] Thematic breaks (`<hr />`)
  - [ ] HTML blocks (pass through)

### Inline Rendering
- [ ] Render inline nodes:
  - [ ] Text (escaped)
  - [ ] Code spans (`<code>...</code>`)
  - [ ] Emphasis (`<em>...</em>`)
  - [ ] Strong (`<strong>...</strong>`)
  - [ ] Links (`<a href="url" title="title">...</a>`)
  - [ ] Images (`<img src="url" alt="text" title="title" />`)
  - [ ] Line breaks (`<br />` or newline)
  - [ ] HTML inline (pass through)

### Escaping and Normalization
- [ ] Implement character escaping:
  - [ ] HTML entity escaping (`&`, `<`, `>`, `"`)
  - [ ] URL encoding for attributes
- [ ] Implement output normalization:
  - [ ] Proper newlines between blocks
  - [ ] Tight list handling
  - [ ] Match CommonMark reference output

---

## Phase 5: Testing & Compliance

### Test Execution
- [ ] Run full test suite against `spec.txt`
- [ ] Generate test report:
  - [ ] Group failures by section
  - [ ] Priority: sections with most failures

### Systematic Bug Fixing
- [ ] Fix failures by category:
  - [ ] **Tabs** (usually in tab expansion)
  - [ ] **Precedence** (block parsing order)
  - [ ] **Thematic breaks** (edge cases)
  - [ ] **Headings** (ATX and Setext edge cases)
  - [ ] **Code blocks** (fenced vs indented)
  - [ ] **HTML blocks** (all 7 types)
  - [ ] **Paragraphs** (lazy continuation)
  - [ ] **Block quotes** (nesting, lazy)
  - [ ] **Lists** (tight/loose, nesting, interruption)
  - [ ] **Inlines** (delimiter runs)
  - [ ] **Code spans** (backtick matching)
  - [ ] **Emphasis** (complex nesting)
  - [ ] **Links** (all forms, precedence)
  - [ ] **Images** (same as links)

### Debugging Tools
- [ ] Add AST dump functionality (for debugging)
- [ ] Add verbose test mode (show parse tree)
- [ ] Add ability to run single test by number

### Compliance Target
- [ ] **Goal: 100% pass rate (652/652 tests)**
  - Track progress here as tests pass:
  - [ ] 25% (163 tests)
  - [ ] 50% (326 tests)
  - [ ] 75% (489 tests)
  - [ ] 90% (587 tests)
  - [ ] 95% (619 tests)
  - [ ] 99% (646 tests)
  - [ ] 100% (652 tests) 🎉

---

## Phase 6: Optimization & Polish

### Performance
- [ ] Profile memory usage
  - [ ] Ensure no memory leaks
  - [ ] Optimize allocations in hot paths
- [ ] Profile CPU usage
  - [ ] Identify bottlenecks
  - [ ] Optimize critical paths
- [ ] Add benchmarks
  - [ ] Small documents
  - [ ] Large documents
  - [ ] Pathological cases (from `pathological_tests.py`)

### Code Quality
- [ ] Code review and refactoring
  - [ ] Consistent naming conventions
  - [ ] Remove dead code
  - [ ] Simplify complex functions
- [ ] Documentation
  - [ ] Doc comments for public API
  - [ ] Inline comments for complex logic
  - [ ] Update README with usage examples
- [ ] Error handling review
  - [ ] Proper error propagation
  - [ ] Meaningful error messages

### CLI Tool
- [ ] Implement `src/main.zig` - CLI interface
  - [ ] Read from file or stdin (UTF-8)
  - [ ] Write to file or stdout (UTF-8)
  - [ ] Command-line options:
    - [ ] `--help`
    - [ ] `--version`
    - [ ] `--unsafe` (enable raw HTML passthrough - REQUIRED for tests)
    - [ ] `--output <file>`
    - [ ] `--smart` (smart punctuation, if implemented)
  - [ ] Error handling and user messages
  - [ ] Note: Python tests automatically add `--unsafe` flag

### Examples and Documentation
- [ ] Create `examples/simple.zig` - Basic usage example
- [ ] Create `examples/custom_renderer.zig` - AST traversal
- [ ] Update README.md:
  - [ ] Project description
  - [ ] Installation instructions
  - [ ] Usage examples (library and CLI)
  - [ ] API documentation
  - [ ] Building and testing
  - [ ] License information
- [ ] Add LICENSE file (choose appropriate license)
- [ ] Add CHANGELOG.md

### Additional Test Suites
- [ ] Run `pathological_tests.py` (stress tests)
- [ ] Run `regression.txt` tests
- [ ] Consider `smart_punct.txt` (optional feature)

---

## Phase 7: Optional Enhancements

### Extended Features (Post-MVP)
- [ ] Smart punctuation (convert straight quotes to curly, -- to em-dash)
- [ ] CommonMark extensions:
  - [ ] Tables (GFM)
  - [ ] Strikethrough (GFM)
  - [ ] Task lists (GFM)
  - [ ] Footnotes
- [ ] Alternative renderers:
  - [ ] XML/AST output
  - [ ] Markdown output (pretty-printer)
  - [ ] Plain text output
- [ ] Syntax highlighting integration
  - [ ] Detect code block language
  - [ ] Optional syntax highlighter interface

### Developer Experience
- [ ] Detailed error messages with suggestions
- [ ] Better debugging output
- [ ] VSCode/editor integration examples

---

## Current Status

**Phase**: Phase 3 - Block Structure & List Parsing (In Progress)
**Tests Passing**: 505/652 (77.5%)
**Last Updated**: 2026-01-19
**Status**: Active development - 147 tests remaining (77.5% → target 100%)

**Progress this iteration**: +48 tests (457 → 505), +7.4% improvement

**Major fixes in this iteration**:
- **List Items & Lists**: Rewrote container matching algorithm for proper list item continuation
  - Fixed list item indentation calculation to account for stripped spaces
  - Implemented tight/loose list rendering in HTML output
  - Fixed lazy continuation for list items
  - Fixed 29 tests (66 → 37 remaining)
- **Code Blocks**: Fixed trailing blank line handling in indented code blocks
  - Proper trimming of trailing newlines when code blocks close
  - Fixed indentation calculation for code blocks at document level vs within lists
- **Block Structure**: Improved container matching for nested structures
  - Block quotes can now contain list items properly
  - List items can contain code blocks and block quotes
  - Fixed blank line handling to not prematurely close containers

**Remaining failures by category**:
- Links: 24 failures (escape handling in URLs, nested links)
- HTML blocks: 22 failures (type detection edge cases)
- List items: 20 failures (complex indentation edge cases)
- Lists: 17 failures (nesting edge cases)
- Emphasis: 16 failures (complex nesting edge cases)
- Block quotes: 11 failures (lazy continuation)
- Other categories: 37 failures

**Current focus**: Block quotes lazy continuation (11 failures) and HTML blocks (22 failures)

## Notes

- Implement in order
- Run tests frequently to catch regressions
- Tests take a little while to run, save output to file so you can read it quickly.
- Refer to CommonMark spec for ambiguous cases
- Check cmark reference implementation when stuck
- Keep commits small and focused
- Each major feature should have passing tests before moving on

## Quick Start Commands

```bash
# Build the project
zig build

# Run the CommonMark spec test suite (using Python)
python3 tests/spec_tests.py --program ./zig-out/bin/zmark --spec tests/spec.txt

# Run specific test by number
python3 tests/spec_tests.py --program ./zig-out/bin/zmark --spec tests/spec.txt --number 123

# Run tests matching a pattern (e.g., only "Headings" section)
python3 tests/spec_tests.py --program ./zig-out/bin/zmark --spec tests/spec.txt --pattern "Headings"

# Run pathological tests (stress tests)
python3 tests/pathological_tests.py --program ./zig-out/bin/zmark

# Run optional Zig unit tests
zig build test

# Run CLI tool on a file
zig build run -- input.md > output.html

# Or use the binary directly
./zig-out/bin/zmark < input.md > output.html
```
