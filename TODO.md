# ZMark Implementation TODO List

## Legend
- [ ] Not started
- [x] Completed
- [~] In progress
- [!] Blocked/Issues

---

## Phase 2: Block Structure Parser

### Simple Leaf Blocks (Implement First)
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

- [~] **Setext headings** (23/27 passing)
  - [x] Detect underline (`===` or `---`)
  - [x] Convert paragraph to heading
  - [x] Handle precedence with thematic breaks
  - [x] Indentation limit (0-3 spaces only)
  - [~] Tests: spec examples in "Setext headings" section (4 edge cases remaining)

### Container Blocks
- [~] **Block quotes** (11 failures remain)
  - [x] Detect `>` marker
  - [x] Handle continuation with `>`
  - [x] Nested block quotes
  - [x] Can contain other block elements (lists, code, etc.)
  - [ ] Lazy continuation (paragraphs without `>`)
  - [~] Tests: spec examples in "Block quotes" section

- [~] **List items** (38/48 passing - 79%) 🎯
  - [x] Detect list markers:
    - [x] Unordered: `-`, `+`, `*`
    - [x] Ordered: `1.`, `2)`, etc.
  - [x] Calculate content indentation correctly
  - [x] Account for stripped indentation in indent calculation
  - [x] Handle blank lines within list items
  - [x] Container matching for list item continuation
  - [x] Can contain nested blocks (code, quotes, lists, headings) ✅
  - [x] Process first line content through block parser (not just as paragraph) ✅
  - [x] Recognize empty list markers as structural elements ✅
  - [!] Remaining issues:
    - [ ] Empty list items create separate lists instead of continuing
    - [ ] Indented code blocks (4+ spaces) not recognized in list items
    - [ ] Tight/loose rendering edge cases with multiple blocks
  - [~] Tests: spec examples in "List items" section (10 failures remaining)

- [~] **Lists**
  - [x] Detect list start
  - [x] Tight vs loose lists - properly implemented
  - [x] Render tight lists without `<p>` tags for single paragraphs
  - [x] Nested lists
  - [x] List item interruption rules
  - [x] Changing list type/delimiter
  - [x] Start number for ordered lists (with proper ≤999999999 validation)
  - [x] Close lists when non-list-item content appears
  - [x] Empty list item indentation handling
  - [x] Thematic breaks within list items
  - [~] Tests: spec examples in "Lists" section (some edge cases remaining)

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

- [~] **Raw HTML inline** (most passing, 6 edge cases remain)
  - [x] Detect HTML tags
  - [x] Parse tag structure (opening tags, closing tags, comments, etc.)
  - [x] Require whitespace before attributes ✅
  - [x] Pass through without modification
  - [!] Remaining: HTML block vs inline detection edge cases
  - [~] Tests: spec examples in "Raw HTML" section

### Emphasis and Strong Emphasis
- [~] **Emphasis/Strong implementation** (90% complete - 5 edge cases remain) 🎯
  - [x] Detect delimiter runs (`*`, `_`)
  - [x] Determine left/right-flanking
  - [x] Implement can-open/can-close rules (rule 9)
  - [x] Push delimiters to stack
  - [x] Process delimiter stack:
    - [x] Look for matching pairs (backwards search from closer)
    - [x] Handle precedence (`***` -> strong vs em)
    - [x] Remove used delimiters
    - [x] Process closers left-to-right ✅
    - [x] Use 2 delimiters if both >= 2, else 1 ✅
    - [x] Remove intervening delimiters from stack ✅
  - [~] Tests: spec examples in "Emphasis and strong emphasis" section
    - [x] Basic cases ✅
    - [x] Intraword emphasis ✅
    - [x] Most nested emphasis ✅
    - [!] Remaining: 5 complex multi-delimiter cases (e.g., `*foo**bar**baz*`)

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
- [~] **Goal: 100% pass rate (652/652 tests)**
  - Track progress here as tests pass:
  - [x] 25% (163 tests) ✅
  - [x] 50% (326 tests) ✅
  - [x] 75% (489 tests) ✅
  - [~] 90% (587 tests) - **Currently at 89.7% (585/652)** 🎯
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

**Phase**: Phase 2/3 - Block Structure Parser + Inline Parsing (In Progress)
**Tests Passing**: 585/652 (89.7%)
**Last Updated**: 2026-01-21
**Status**: Active development - 67 tests remaining (89.7% → target 100%)

**Breakdown of remaining 67 failures**:
- Links: 11 failures (precedence, nested links)
- List items: 10 failures (indented code, empty items, tight/loose - **fixed 4!** ✅)
- HTML blocks: 10 failures (block detection edge cases)
- Lists: 8 failures (related to list items - **fixed 1!** ✅)
- Block quotes: 6 failures (lazy continuation rules)
- Raw HTML: 6 failures (tag validation edge cases)
- Emphasis and strong emphasis: 5 failures (complex nesting - **fixed 11!** ✅)
- Link reference definitions: 5 failures (multiline, Unicode case-folding)
- Tabs: 4 failures (expansion in nested structures)
- Autolinks: 1 failure (HTML block detection - **fixed 1!** ✅)
- Images: 1 failure (nested links in alt text)

**Recent progress (2026-01-21)**:
- ✅ **Emphasis delimiter processing**: Fixed 11/16 failures by improving the algorithm
  - Implemented proper left-to-right closer processing
  - Fixed delimiter removal and counting logic
  - Improved handling of delimiter runs with varying lengths
- ✅ **List item parsing**: Fixed 4/14 failures by allowing block-level content
  - Changed first line processing to use `processLineContent()` instead of forcing paragraphs
  - Now correctly recognizes headings in list items (e.g., `- # Foo`)
  - Now correctly creates nested lists (e.g., `- - foo`, `1. - 2. foo`)
  - Block quotes in list items now parse correctly
- ✅ **Raw HTML attribute parsing**: Fixed 1 autolink failure
  - Added requirement for whitespace before HTML tag attributes per CommonMark spec
- ✅ **Overall improvement**: 570/652 (87.4%) → 585/652 (89.7%) - **+15 tests!**

**Current focus**: Remaining list items edge cases (empty items, indented code), then Links and HTML blocks

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
