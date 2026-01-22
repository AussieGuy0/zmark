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

### Systematic Bug Fixing (17 tests remaining)

#### **Tabs** (0 tests) - COMPLETED ✅
  - [x] Example 5 (lines 395-407): Tab in list with code block - FIXED ✅
  - [x] Example 6 (lines 418-425): Tab in blockquote with code block - FIXED ✅
  - [x] Example 7 (lines 427-436): Tab after list marker should create code block - FIXED ✅
  - [x] Example 9 (lines 448-464): Tab handling in nested lists - FIXED ✅

#### **Link Reference Definitions** (0 tests) - COMPLETED ✅
  - [x] Example 206 (lines 3348-3354): Case-insensitive Unicode matching (Greek ΑΓΩ/αγω) - FIXED ✅

#### **List Items** (2 tests)
  - [ ] Example 259 (lines 3348-3354): Tight/loose detection in nested blockquotes
  - [ ] Example 260 (lines 4278-4291): Tight/loose detection with blank lines

#### **Lists** (1 test)
  - [ ] Example 319 (lines 5690-5708): Tight/loose detection with nested lists

#### **Emphasis and Strong Emphasis** (4 tests)
  - [x] Example 362 (lines 6421-6425): Unicode Cyrillic with underscores (should NOT emphasize) - FIXED ✅
  - [x] Example 388 (lines 6672-6676): Unicode Cyrillic with double underscores (should NOT bold) - FIXED ✅
  - [ ] Example 411 (lines 6882-6886): Nested emphasis/strong `*foo**bar**baz*`
  - [ ] Example 412 (lines 6906-6910): Complex emphasis `*foo**bar*`
  - [ ] Example 415 (lines 6933-6937): Complex emphasis `*foo**bar***`
  - [ ] Example 429 (lines 7049-7053): Nested strong/emphasis `**foo*bar*baz**`

#### **Links** (0 tests) - COMPLETED ✅
  - [x] Example 520 (lines 7900-7904): Nested image/link alt text handling - FIXED ✅
  - [x] Example 552 (lines 8294-8305): Link reference with whitespace in label - FIXED ✅

#### **Images** (0 tests) - COMPLETED ✅
  - [x] Example 574 (lines 8557-8561): Nested images in alt text - FIXED ✅
  - [x] Example 575 (lines 8564-8568): Image alt text with inline link - FIXED ✅

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
  - [x] 90% (587 tests) ✅
  - [x] 95% (619 tests) ✅
  - [x] 97% (635 tests) ✅
  - [x] 98% (639 tests) - **Currently at 98.8% (644/652)** 🎯
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
**Tests Passing**: 644/652 (98.8%) ⬆️ from 638
**Last Updated**: 2026-01-22
**Status**: Excellent progress! Down to only 8 remaining failures, all complex edge cases

**Remaining Test Failures (8 total)**:
- Emphasis: 4 tests (Examples 411, 412, 415, 429) - Complex delimiter nesting (requires full delimiter stack algorithm)
- Lists: 3 tests (Examples 259, 260, 319) - Tight/loose detection edge cases
- Tabs: 1 test (Example 5) - Tab expansion in code blocks within lists

**Recent Fixes** (6 tests fixed in this session):
- ✅ Example 206: Link reference Unicode case-insensitive matching (added Greek letter support)
- ✅ Example 520: Nested image/link alt text handling (added inside_image flag)
- ✅ Example 552: Link reference with empty labels after normalization
- ✅ Example 574: Nested images in alt text
- ✅ Example 575: Image alt text with inline links
- ✅ Example 362: Unicode Cyrillic with underscores (fixed punctuation detection)
- ✅ Example 388: Unicode Cyrillic with double underscores


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
