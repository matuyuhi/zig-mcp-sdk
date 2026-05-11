const std = @import("std");

const JsonValue = std.json.Value;

/// Extract a string from a JSON value
pub fn getString(val: ?JsonValue) ?[]const u8 {
    const v = val orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// Extract a number (integer or float) from a JSON value as f64
pub fn getNumber(val: ?JsonValue) ?f64 {
    const v = val orelse return null;
    return switch (v) {
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => null,
    };
}

/// Extract a boolean from a JSON value
pub fn getBool(val: ?JsonValue) ?bool {
    const v = val orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

/// Extract an object from a JSON value
pub fn getObject(val: ?JsonValue) ?std.json.ObjectMap {
    const v = val orelse return null;
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

/// Extract an array from a JSON value
pub fn getArray(val: ?JsonValue) ?std.json.Array {
    const v = val orelse return null;
    return switch (v) {
        .array => |a| a,
        else => null,
    };
}

// --- Tests ---

const testing = std.testing;

test "getString" {
    try testing.expectEqualStrings("hello", getString(.{ .string = "hello" }).?);
    try testing.expect(getString(.{ .integer = 42 }) == null);
    try testing.expect(getString(null) == null);
}

test "getNumber from integer" {
    try testing.expectEqual(@as(f64, 42.0), getNumber(.{ .integer = 42 }).?);
}

test "getNumber from float" {
    try testing.expectEqual(@as(f64, 3.14), getNumber(.{ .float = 3.14 }).?);
}

test "getNumber returns null for non-numeric" {
    try testing.expect(getNumber(.{ .string = "hi" }) == null);
    try testing.expect(getNumber(null) == null);
}

test "getBool" {
    try testing.expectEqual(true, getBool(.{ .bool = true }).?);
    try testing.expectEqual(false, getBool(.{ .bool = false }).?);
    try testing.expect(getBool(.{ .integer = 1 }) == null);
    try testing.expect(getBool(null) == null);
}

test "getArray" {
    var array = std.json.Array.init(testing.allocator);
    defer array.deinit();

    // Verify successful extraction
    const extracted = getArray(.{ .array = array }).?;
    try testing.expectEqual(array.items.len, extracted.items.len);

    // Verify null is returned for non-array values
    try testing.expect(getArray(.{ .integer = 1 }) == null);

    // Verify null is returned for null
    try testing.expect(getArray(null) == null);
}
