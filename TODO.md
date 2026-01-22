# ZMark Implementation TODO List

## Legend
- [ ] Not started
- [x] Completed
- [~] In progress
- [!] Blocked/Issues

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

**Phase**: Phase 5 - Testing & Compliance (In Progress)
**Tests Passing**: 635/652 (97.4%) ⬆️ from 630
**Last Updated**: 2026-01-22
**Status**: Excellent progress - improved from 96.6% to 97.4%
**Progress**:
- ✅ Fixed Raw HTML tests (5 tests) - proper HTML tag/attribute validation including multi-line tags, attribute spacing, HTML comments, backslash handling
- ⚠️  Tabs (4 tests) - requires architectural refactoring of offset tracking system
- ⚠️  Emphasis (6 tests) - complex delimiter matching with Unicode/nested emphasis
- ⚠️  Links/Images/Lists (7 tests) - various edge cases
**Current Work**: Achieved 97.4% compliance. Remaining 17 tests require significant refactoring.


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
