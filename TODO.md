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

**Phase**: Phase 2/3 - Block Structure Parser + Inline Parsing (In Progress)
**Tests Passing**: 531/652 (81.4%)
**Last Updated**: 2026-01-20
**Status**: Active development - 121 tests remaining (81.4% → target 100%)

**Progress this session**: +20 tests (511 → 531), +3.1% improvement

**Major fixes this session**:
- **Lists + List items**: MAJOR IMPROVEMENTS ✅
  - Implemented lazy continuation for list items (like block quotes)
  - Fixed empty list item handling (can't interrupt paragraphs)
  - Added blank line tracking for empty list items
  - Implemented tight/loose list detection using trailing blank tracking
  - Fixed tight/loose rendering in HTML output
  - Reduced failures from ~34 to ~20
- **Setext Headings**: ALL TESTS PASSING (27/27) ✅
  - Fixed internal spaces in underlines (must be trailing only)
  - Fixed lazy continuation behavior (structural elements don't continue)
  - Implemented looksLikeStructuralElement() for proper precedence
- **HTML Blocks**: Significantly improved (28/44 passing)
  - Fixed indentation preservation (0-3 spaces kept in output)
  - Added type 7 end condition
  - 16 edge cases remain (mostly paragraph interruption)
- **Fenced Code Blocks**: Improved (24/29 passing)
  - Fixed container marker handling (blockquotes, lists)
  - Fixed in_fenced_code flag management
  - 5 edge cases remain (indentation handling)
- **Lazy Continuation**: Major improvements
  - Thematic breaks no longer lazily continued
  - Setext headings no longer lazily continued
  - Structural elements properly detected and break containers
  - List items now support lazy continuation like block quotes

**Remaining failures by category** (current):
- Lists + List items: ~20 failures (nested structures, complex indentation)
- Links: ~24 failures (escape handling, nested links, entity encoding, precedence)
- Emphasis: ~16 failures (complex nesting, delimiter matching edge cases)
- HTML blocks: ~16 failures (paragraph interruption, type 7 edge cases)
- Block quotes: ~11 failures (lazy continuation edge cases)
- Fenced code blocks: ~5 failures (indentation edge cases, blank line handling)
- Code spans: ~4 failures (whitespace handling, backtick matching)
- Autolinks: ~5 failures (email validation, escaping)
- Tabs: ~3 failures (tab expansion in various contexts)
- Other categories: ~17 failures

**Current focus**: Block-level mostly working. Next priorities: Links (escape/entity handling), Emphasis (complex nesting), remaining edge cases.

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
