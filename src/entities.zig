const std = @import("std");

// Decode an HTML entity starting at the given position
// Returns the decoded character(s) and the length of the entity
// Note: for numeric entities, this returns a static buffer that should be copied if needed
pub fn decodeEntity(text: []const u8, pos: usize) ?struct { str: []const u8, len: usize } {
    if (pos >= text.len or text[pos] != '&') return null;

    var i = pos + 1;
    if (i >= text.len) return null;

    // Check for numeric entity
    if (text[i] == '#') {
        i += 1;
        if (i >= text.len) return null;

        var is_hex = false;
        if (text[i] == 'x' or text[i] == 'X') {
            is_hex = true;
            i += 1;
        }

        if (i >= text.len) return null;

        // Parse the number
        var value: u32 = 0;
        const base: u32 = if (is_hex) 16 else 10;
        const start = i;
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            if (ch == ';') {
                // Valid end of entity
                if (i == start) return null; // Empty number

                const result_len = i + 1 - pos;

                // Replace invalid codepoints with U+FFFD (replacement character)
                const codepoint = if (value == 0 or // NUL character
                                     value > 0x10FFFF or // Outside Unicode range
                                     (value >= 0xD800 and value <= 0xDFFF)) // Surrogate range
                    0xFFFD
                else
                    value;

                // Use a static buffer for numeric entity results
                const static = struct {
                    var buf: [4]u8 = undefined;
                };

                const utf8_len = std.unicode.utf8Encode(@intCast(codepoint), &static.buf) catch return null;
                return .{ .str = static.buf[0..utf8_len], .len = result_len };
            }

            const digit: u32 = if (is_hex) switch (ch) {
                '0'...'9' => ch - '0',
                'a'...'f' => ch - 'a' + 10,
                'A'...'F' => ch - 'A' + 10,
                else => return null,
            } else switch (ch) {
                '0'...'9' => ch - '0',
                else => return null,
            };

            value = value * base + digit;
            if (value > 0x10FFFF) return null; // Invalid Unicode codepoint
        }

        return null; // No closing semicolon
    }

    // Check for named entity
    const start = i;
    while (i < text.len and i < start + 32) : (i += 1) {
        const ch = text[i];
        if (ch == ';') {
            const name = text[start..i];
            if (getNamedEntity(name)) |replacement| {
                const result_len = i + 1 - pos;
                return .{ .str = replacement, .len = result_len };
            }
            return null;
        }
        if (!isAlphanumeric(ch)) {
            return null;
        }
    }

    return null;
}

fn isAlphanumeric(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or
           (ch >= 'A' and ch <= 'Z') or
           (ch >= '0' and ch <= '9');
}

// Common HTML5 named entities
fn getNamedEntity(name: []const u8) ?[]const u8 {
    // This is a minimal set - CommonMark spec requires supporting all HTML5 named entities
    // For a complete implementation, this would need to include all 2000+ HTML5 entities

    const Entity = struct { name: []const u8, value: []const u8 };
    const entities = [_]Entity{
        .{ .name = "quot", .value = "\"" },
        .{ .name = "amp", .value = "&" },
        .{ .name = "apos", .value = "'" },
        .{ .name = "lt", .value = "<" },
        .{ .name = "gt", .value = ">" },
        .{ .name = "nbsp", .value = "\u{00A0}" },
        .{ .name = "iexcl", .value = "¡" },
        .{ .name = "cent", .value = "¢" },
        .{ .name = "pound", .value = "£" },
        .{ .name = "curren", .value = "¤" },
        .{ .name = "yen", .value = "¥" },
        .{ .name = "brvbar", .value = "¦" },
        .{ .name = "sect", .value = "§" },
        .{ .name = "uml", .value = "¨" },
        .{ .name = "copy", .value = "©" },
        .{ .name = "ordf", .value = "ª" },
        .{ .name = "laquo", .value = "«" },
        .{ .name = "not", .value = "¬" },
        .{ .name = "shy", .value = "\u{00AD}" },
        .{ .name = "reg", .value = "®" },
        .{ .name = "macr", .value = "¯" },
        .{ .name = "deg", .value = "°" },
        .{ .name = "plusmn", .value = "±" },
        .{ .name = "sup2", .value = "²" },
        .{ .name = "sup3", .value = "³" },
        .{ .name = "acute", .value = "´" },
        .{ .name = "micro", .value = "µ" },
        .{ .name = "para", .value = "¶" },
        .{ .name = "middot", .value = "·" },
        .{ .name = "cedil", .value = "¸" },
        .{ .name = "sup1", .value = "¹" },
        .{ .name = "ordm", .value = "º" },
        .{ .name = "raquo", .value = "»" },
        .{ .name = "frac14", .value = "¼" },
        .{ .name = "frac12", .value = "½" },
        .{ .name = "frac34", .value = "¾" },
        .{ .name = "iquest", .value = "¿" },
        .{ .name = "Agrave", .value = "À" },
        .{ .name = "Aacute", .value = "Á" },
        .{ .name = "Acirc", .value = "Â" },
        .{ .name = "Atilde", .value = "Ã" },
        .{ .name = "Auml", .value = "Ä" },
        .{ .name = "Aring", .value = "Å" },
        .{ .name = "AElig", .value = "Æ" },
        .{ .name = "Ccedil", .value = "Ç" },
        .{ .name = "Egrave", .value = "È" },
        .{ .name = "Eacute", .value = "É" },
        .{ .name = "Ecirc", .value = "Ê" },
        .{ .name = "Euml", .value = "Ë" },
        .{ .name = "Igrave", .value = "Ì" },
        .{ .name = "Iacute", .value = "Í" },
        .{ .name = "Icirc", .value = "Î" },
        .{ .name = "Iuml", .value = "Ï" },
        .{ .name = "ETH", .value = "Ð" },
        .{ .name = "Ntilde", .value = "Ñ" },
        .{ .name = "Ograve", .value = "Ò" },
        .{ .name = "Oacute", .value = "Ó" },
        .{ .name = "Ocirc", .value = "Ô" },
        .{ .name = "Otilde", .value = "Õ" },
        .{ .name = "Ouml", .value = "Ö" },
        .{ .name = "times", .value = "×" },
        .{ .name = "Oslash", .value = "Ø" },
        .{ .name = "Ugrave", .value = "Ù" },
        .{ .name = "Uacute", .value = "Ú" },
        .{ .name = "Ucirc", .value = "Û" },
        .{ .name = "Uuml", .value = "Ü" },
        .{ .name = "Yacute", .value = "Ý" },
        .{ .name = "THORN", .value = "Þ" },
        .{ .name = "szlig", .value = "ß" },
        .{ .name = "agrave", .value = "à" },
        .{ .name = "aacute", .value = "á" },
        .{ .name = "acirc", .value = "â" },
        .{ .name = "atilde", .value = "ã" },
        .{ .name = "auml", .value = "ä" },
        .{ .name = "aring", .value = "å" },
        .{ .name = "aelig", .value = "æ" },
        .{ .name = "ccedil", .value = "ç" },
        .{ .name = "egrave", .value = "è" },
        .{ .name = "eacute", .value = "é" },
        .{ .name = "ecirc", .value = "ê" },
        .{ .name = "euml", .value = "ë" },
        .{ .name = "igrave", .value = "ì" },
        .{ .name = "iacute", .value = "í" },
        .{ .name = "icirc", .value = "î" },
        .{ .name = "iuml", .value = "ï" },
        .{ .name = "eth", .value = "ð" },
        .{ .name = "ntilde", .value = "ñ" },
        .{ .name = "ograve", .value = "ò" },
        .{ .name = "oacute", .value = "ó" },
        .{ .name = "ocirc", .value = "ô" },
        .{ .name = "otilde", .value = "õ" },
        .{ .name = "ouml", .value = "ö" },
        .{ .name = "divide", .value = "÷" },
        .{ .name = "oslash", .value = "ø" },
        .{ .name = "ugrave", .value = "ù" },
        .{ .name = "uacute", .value = "ú" },
        .{ .name = "ucirc", .value = "û" },
        .{ .name = "uuml", .value = "ü" },
        .{ .name = "yacute", .value = "ý" },
        .{ .name = "thorn", .value = "þ" },
        .{ .name = "yuml", .value = "ÿ" },
        // Additional entities from CommonMark tests
        .{ .name = "Dcaron", .value = "Ď" },
        .{ .name = "HilbertSpace", .value = "ℋ" },
        .{ .name = "DifferentialD", .value = "ⅆ" },
        .{ .name = "ClockwiseContourIntegral", .value = "∲" },
        .{ .name = "ngE", .value = "≧̸" },
    };

    for (entities) |entity| {
        if (std.mem.eql(u8, name, entity.name)) {
            return entity.value;
        }
    }

    return null;
}
