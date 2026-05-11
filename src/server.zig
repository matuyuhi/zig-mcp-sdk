const std = @import("std");
const protocol = @import("protocol.zig");

/// Result returned by a tool handler.
pub const ToolResult = struct {
    text: []const u8,
    is_error: bool,
};

/// Tool handler function type.
/// Takes allocator, tool name, and arguments object.
/// Returns a ToolResult (text + is_error flag).
pub const ToolHandler = *const fn (std.mem.Allocator, []const u8, std.json.ObjectMap) anyerror!ToolResult;

/// MCP Server configuration
pub const ServerConfig = struct {
    name: []const u8,
    version: []const u8,
    tools_list_json: []const u8,
    tool_handler: ToolHandler,
};

pub fn run(allocator: std.mem.Allocator, config: ServerConfig) !void {
    const stdin_file = std.fs.File.stdin();
    const stdout_file = std.fs.File.stdout();

    // Allocate read buffer (1MB for large JSON-RPC messages)
    const read_buf = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(read_buf);

    var file_reader = stdin_file.readerStreaming(read_buf);

    std.debug.print("{s}: server started, waiting for input...\n", .{config.name});

    while (true) {
        const line = file_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                std.debug.print("{s}: line too long, skipping\n", .{config.name});
                continue;
            },
            error.ReadFailed => break,
        } orelse break; // EOF

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        // Copy line since takeDelimiter returns a slice into the read buffer
        const line_copy = allocator.dupe(u8, trimmed) catch continue;
        defer allocator.free(line_copy);

        // Build response into a buffer, then write all at once to stdout
        const response = processLine(allocator, config, line_copy) catch |err| {
            std.debug.print("{s}: process error: {}\n", .{ config.name, err });
            continue;
        } orelse continue; // notification, no response
        defer allocator.free(response);

        _ = stdout_file.write(response) catch |err| {
            std.debug.print("{s}: write error: {}\n", .{ config.name, err });
        };
    }

    std.debug.print("{s}: server shutting down\n", .{config.name});
}

/// Process a JSON-RPC line. Returns allocated response string, or null for notifications.
fn processLine(allocator: std.mem.Allocator, config: ServerConfig, line: []const u8) !?[]const u8 {
    // Parse JSON
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch {
        return try protocol.buildJsonRpcError(allocator, "null", -32700, "Parse error");
    };
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => {
            return try protocol.buildJsonRpcError(allocator, "null", -32600, "Invalid Request");
        },
    };

    // Get method
    const method = switch (root.get("method") orelse {
        return try protocol.buildJsonRpcError(allocator, "null", -32600, "Invalid Request: missing method");
    }) {
        .string => |s| s,
        else => {
            return try protocol.buildJsonRpcError(allocator, "null", -32600, "Invalid Request: method must be string");
        },
    };

    // Format id for response
    var id_buf: [256]u8 = undefined;
    const id_json = protocol.formatId(root.get("id"), &id_buf);

    // Handle notifications (no response needed)
    if (std.mem.startsWith(u8, method, "notifications/")) {
        std.debug.print("{s}: notification: {s}\n", .{ config.name, method });
        return null;
    }

    // Dispatch method
    if (std.mem.eql(u8, method, "initialize")) {
        return try protocol.buildInitializeResult(allocator, id_json, config.name, config.version);
    } else if (std.mem.eql(u8, method, "tools/list")) {
        return try protocol.buildJsonRpcResult(allocator, id_json, config.tools_list_json);
    } else if (std.mem.eql(u8, method, "tools/call")) {
        return try handleToolsCall(allocator, config, id_json, root.get("params"));
    } else {
        return try protocol.buildJsonRpcError(allocator, id_json, -32601, "Method not found");
    }
}

fn handleToolsCall(allocator: std.mem.Allocator, config: ServerConfig, id_json: []const u8, params_val: ?std.json.Value) ![]const u8 {
    const params = switch (params_val orelse {
        return try protocol.buildToolResult(allocator, id_json, "Error: missing params", true);
    }) {
        .object => |o| o,
        else => {
            return try protocol.buildToolResult(allocator, id_json, "Error: params must be object", true);
        },
    };

    const tool_name = switch (params.get("name") orelse {
        return try protocol.buildToolResult(allocator, id_json, "Error: missing tool name", true);
    }) {
        .string => |s| s,
        else => {
            return try protocol.buildToolResult(allocator, id_json, "Error: tool name must be string", true);
        },
    };

    const arguments = switch (params.get("arguments") orelse {
        return try protocol.buildToolResult(allocator, id_json, "Error: missing arguments", true);
    }) {
        .object => |o| o,
        else => {
            return try protocol.buildToolResult(allocator, id_json, "Error: arguments must be object", true);
        },
    };

    std.debug.print("{s}: executing tool: {s}\n", .{ config.name, tool_name });

    const result = config.tool_handler(allocator, tool_name, arguments) catch |err| {
        const err_msg = std.fmt.allocPrint(allocator, "Error: {}", .{err}) catch
            return try protocol.buildToolResult(allocator, id_json, "Error: internal error", true);
        defer allocator.free(err_msg);
        return try protocol.buildToolResult(allocator, id_json, err_msg, true);
    };
    defer allocator.free(result.text);

    return try protocol.buildToolResult(allocator, id_json, result.text, result.is_error);
}
