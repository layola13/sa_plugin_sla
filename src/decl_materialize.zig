// Target-conditional declaration materialization (C-upper).
//
// This is an upper-layer source transform in the SLA front-end. It runs on
// source text BEFORE the parser, the type checker, and both code generators
// (SAB and SA text) ever see the file, and it reduces target-conditional
// declaration blocks to the single concrete variant for the compilation
// target, written with pre-existing types only. The SA grammar, the SAB
// encoding, the parser, and the checker never learn any conditional
// semantics: downstream stages only ever see ordinary declarations.
//
// Shared specification: docs/target_conditional_decls.md. The Rust
// standalone implementation follows the same specification and must pass
// the same golden corpus (tests/decl_target/).
//
// Block spelling (markers are whole comment lines, matched after trimming
// surrounding whitespace):
//
//   // @target-begin
//   // @target native
//   <lines for native targets>
//   // @target wasm32
//   <lines for wasm32 targets>
//   // @target-end
//
// Selection is loud: for every block, the requested target must have
// exactly one section, and that section must be non-empty. A missing or
// duplicated section, an unknown target name, a section outside a block,
// a nested or unterminated block, or an end marker without a block is a
// hard error. Nothing ever falls back to a default variant.

const std = @import("std");

pub const DeclTarget = enum {
    native,
    wasm32,

    pub fn targetName(self: DeclTarget) []const u8 {
        return switch (self) {
            .native => "native",
            .wasm32 => "wasm32",
        };
    }

    pub fn fromName(name: []const u8) ?DeclTarget {
        if (std.mem.eql(u8, name, "native")) return .native;
        if (std.mem.eql(u8, name, "wasm32")) return .wasm32;
        return null;
    }
};

pub const MaterializeError = error{
    MissingTargetVariant,
    DuplicateTargetVariant,
    UnknownTargetName,
    EmptyTargetSection,
    TargetSectionOutsideBlock,
    ContentOutsideTargetSection,
    NestedTargetBlock,
    EndWithoutTargetBlock,
    UnterminatedTargetBlock,
    OutOfMemory,
};

const marker_prefix = "// @target";
const begin_marker = "// @target-begin";
const end_marker = "// @target-end";
const section_prefix = "// @target ";

/// Fast probe used by call sites: files without any marker-shaped text
/// pass through byte-identical and pay only these substring scans. Any
/// marker at all (including stray end/section markers, which are hard
/// errors) routes the file through the full state machine.
pub fn containsTargetBlocks(source: []const u8) bool {
    if (std.mem.indexOf(u8, source, begin_marker) != null) return true;
    if (std.mem.indexOf(u8, source, end_marker) != null) return true;
    if (std.mem.startsWith(u8, source, section_prefix)) return true;
    return std.mem.indexOf(u8, source, "\n// @target ") != null;
}

const Marker = union(enum) {
    begin,
    end,
    section: []const u8, // target name slice into the line
    not_marker,
};

fn classifyMarker(trimmed_line: []const u8) Marker {
    if (std.mem.eql(u8, trimmed_line, begin_marker)) return .begin;
    if (std.mem.eql(u8, trimmed_line, end_marker)) return .end;
    if (std.mem.startsWith(u8, trimmed_line, section_prefix)) {
        const name = trimmed_line[section_prefix.len..];
        // A section marker is exactly `// @target <name>`; a name with
        // interior whitespace means the line is prose, not a marker.
        if (name.len == 0) return .not_marker;
        if (std.mem.indexOfAny(u8, name, " \t") != null) return .not_marker;
        return .{ .section = name };
    }
    return .not_marker;
}

fn isBlank(trimmed_line: []const u8) bool {
    return trimmed_line.len == 0;
}

/// Reduce every target-conditional block in `source` to the variant for
/// `target`. Returns an owned slice; files without blocks are returned as
/// an owned copy, byte-identical to the input.
pub fn materialize(allocator: std.mem.Allocator, source: []const u8, target: DeclTarget) MaterializeError![]const u8 {
    if (!containsTargetBlocks(source)) {
        return allocator.dupe(u8, source) catch return error.OutOfMemory;
    }

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();

    var in_block = false;
    var seen = [_]bool{ false, false };
    var section: ?DeclTarget = null;
    var section_lines: usize = 0;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw_line| {
        // Preserve original line endings: splitScalar removed '\n'; the
        // iterator's index becomes null exactly when the returned segment
        // is the final one. A trailing '\r' is kept in emitted content but
        // ignored for marker matching.
        const is_last = lines.index == null;
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");

        switch (classifyMarker(trimmed)) {
            .begin => {
                if (in_block) return error.NestedTargetBlock;
                in_block = true;
                seen = [_]bool{ false, false };
                section = null;
                section_lines = 0;
            },
            .end => {
                if (!in_block) return error.EndWithoutTargetBlock;
                if (section == target and section_lines == 0) return error.EmptyTargetSection;
                if (!seen[@intFromEnum(target)]) return error.MissingTargetVariant;
                in_block = false;
                section = null;
            },
            .section => |name| {
                if (!in_block) return error.TargetSectionOutsideBlock;
                const named = DeclTarget.fromName(name) orelse return error.UnknownTargetName;
                if (section == target and section_lines == 0) return error.EmptyTargetSection;
                if (seen[@intFromEnum(named)]) return error.DuplicateTargetVariant;
                seen[@intFromEnum(named)] = true;
                section = named;
                section_lines = 0;
            },
            .not_marker => {
                if (!in_block) {
                    try appendLine(&out, raw_line, is_last);
                } else if (section == null) {
                    if (!isBlank(trimmed)) return error.ContentOutsideTargetSection;
                    // Blank lines between markers carry no meaning; drop.
                } else if (section == target) {
                    section_lines += 1;
                    try appendLine(&out, raw_line, is_last);
                } else {
                    section_lines += 1;
                    // Other target's section: counted, not emitted.
                }
            },
        }
    }
    if (in_block) {
        if (section == target and section_lines == 0) return error.EmptyTargetSection;
        return error.UnterminatedTargetBlock;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn appendLine(out: *std.array_list.Managed(u8), line: []const u8, is_last: bool) MaterializeError!void {
    out.appendSlice(line) catch return error.OutOfMemory;
    if (!is_last) out.append('\n') catch return error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const sample =
    \\const A: u32 = 1;
    \\// @target-begin
    \\// @target native
    \\extern fn mmap(addr: ptr, len: u64) -> ptr;
    \\// @target wasm32
    \\extern fn mmap(addr: ptr, len: u32) -> ptr;
    \\// @target-end
    \\const B: u32 = 2;
    \\
;

test "materialize selects the native variant" {
    const out = try materialize(testing.allocator, sample, .native);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\const A: u32 = 1;
        \\extern fn mmap(addr: ptr, len: u64) -> ptr;
        \\const B: u32 = 2;
        \\
    , out);
}

test "materialize selects the wasm32 variant" {
    const out = try materialize(testing.allocator, sample, .wasm32);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\const A: u32 = 1;
        \\extern fn mmap(addr: ptr, len: u32) -> ptr;
        \\const B: u32 = 2;
        \\
    , out);
}

test "materialize is identity without blocks" {
    const src = "extern fn read(fd: i32, len: u64) -> i32;\n";
    const out = try materialize(testing.allocator, src, .wasm32);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(src, out);
}

test "materialize rejects a missing variant" {
    const src =
        \\// @target-begin
        \\// @target native
        \\extern fn f(len: u64) -> void;
        \\// @target-end
        \\
    ;
    try testing.expectError(error.MissingTargetVariant, materialize(testing.allocator, src, .wasm32));
}

test "materialize rejects a duplicated variant" {
    const src =
        \\// @target-begin
        \\// @target native
        \\extern fn f(len: u64) -> void;
        \\// @target native
        \\extern fn f(len: u64) -> void;
        \\// @target-end
        \\
    ;
    try testing.expectError(error.DuplicateTargetVariant, materialize(testing.allocator, src, .native));
}

test "materialize rejects an unknown target name" {
    const src =
        \\// @target-begin
        \\// @target mips
        \\extern fn f(len: u64) -> void;
        \\// @target-end
        \\
    ;
    try testing.expectError(error.UnknownTargetName, materialize(testing.allocator, src, .native));
}

test "materialize rejects an empty selected section" {
    const src =
        \\// @target-begin
        \\// @target native
        \\// @target wasm32
        \\extern fn f(len: u32) -> void;
        \\// @target-end
        \\
    ;
    try testing.expectError(error.EmptyTargetSection, materialize(testing.allocator, src, .native));
}

test "materialize rejects unterminated and stray markers" {
    const unterminated =
        \\// @target-begin
        \\// @target native
        \\extern fn f(len: u64) -> void;
        \\
    ;
    try testing.expectError(error.UnterminatedTargetBlock, materialize(testing.allocator, unterminated, .native));

    const stray_end = "// @target-end\n";
    try testing.expectError(error.EndWithoutTargetBlock, materialize(testing.allocator, stray_end, .native));

    const stray_section =
        \\// @target native
        \\extern fn f(len: u64) -> void;
        \\
    ;
    try testing.expectError(error.TargetSectionOutsideBlock, materialize(testing.allocator, stray_section, .native));
}

test "materialize rejects content outside a section and nested blocks" {
    const outside =
        \\// @target-begin
        \\extern fn f(len: u64) -> void;
        \\// @target native
        \\extern fn f(len: u64) -> void;
        \\// @target-end
        \\
    ;
    try testing.expectError(error.ContentOutsideTargetSection, materialize(testing.allocator, outside, .native));

    const nested =
        \\// @target-begin
        \\// @target-begin
        \\// @target native
        \\extern fn f(len: u64) -> void;
        \\// @target-end
        \\
    ;
    try testing.expectError(error.NestedTargetBlock, materialize(testing.allocator, nested, .native));
}

test "materialize keeps indented markers and multi-line sections" {
    const src =
        \\fn main() -> void {}
        \\  // @target-begin
        \\  // @target wasm32
        \\const FLAGS: i32 = 34;
        \\const PROT: i32 = 3;
        \\  // @target native
        \\const FLAGS: i32 = 16418;
        \\const PROT: i32 = 3;
        \\  // @target-end
        \\
    ;
    const out = try materialize(testing.allocator, src, .wasm32);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        \\fn main() -> void {}
        \\const FLAGS: i32 = 34;
        \\const PROT: i32 = 3;
        \\
    , out);
}

// ---------------------------------------------------------------------------
// Golden corpus conformance (shared specification,
// docs/target_conditional_decls.md §6). The corpus lives in
// tests/decl_target/; per this repository's test rules the suite runs
// with the repository root as the working directory. Every other
// implementation of the specification (sci build-time, Rust standalone)
// must produce byte-identical outputs for the same inputs.
// ---------------------------------------------------------------------------

fn readCorpusFile(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "tests/decl_target/{s}", .{name});
    defer allocator.free(path);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 20));
}

test "golden corpus: pair1 conditional extern and flag constant" {
    const a = testing.allocator;
    const input = try readCorpusFile(a, "pair1_conditional.sla");
    defer a.free(input);
    for ([_]DeclTarget{ .native, .wasm32 }) |target| {
        const expected_name = try std.fmt.allocPrint(a, "pair1_conditional.{s}.expected", .{target.targetName()});
        defer a.free(expected_name);
        const expected = try readCorpusFile(a, expected_name);
        defer a.free(expected);
        const out = try materialize(a, input, target);
        defer a.free(out);
        try testing.expectEqualStrings(expected, out);
    }
}

test "golden corpus: pair2 plain source is the identity" {
    const a = testing.allocator;
    const input = try readCorpusFile(a, "pair2_plain.sla");
    defer a.free(input);
    for ([_]DeclTarget{ .native, .wasm32 }) |target| {
        const out = try materialize(a, input, target);
        defer a.free(out);
        try testing.expectEqualStrings(input, out);
    }
}

test "golden corpus: neg1 missing variant fails only for the missing target" {
    const a = testing.allocator;
    const input = try readCorpusFile(a, "neg1_missing_variant.sla");
    defer a.free(input);
    try testing.expectError(error.MissingTargetVariant, materialize(a, input, .wasm32));
    const out = try materialize(a, input, .native);
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "len: u64") != null);
}

test "golden corpus: neg2 duplicate variant fails for every target" {
    const a = testing.allocator;
    const input = try readCorpusFile(a, "neg2_duplicate_variant.sla");
    defer a.free(input);
    try testing.expectError(error.DuplicateTargetVariant, materialize(a, input, .native));
    try testing.expectError(error.DuplicateTargetVariant, materialize(a, input, .wasm32));
}
