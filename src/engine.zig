const std = @import("std");
const mem = std.mem;
const Format = @import("format.zig").Format;

pub const Engine = struct {
    exe: []const u8 = undefined,

    const Self = @This();

    pub fn init() Self {
        return Self{};
    }

    pub fn loadModule(self: *Self, alloc: *mem.Allocator, data: []const u8) !void {
        var buffer = Format.init(alloc, data);
        var module = try buffer.readModule();

        var i: usize = 0;
        while (true) : (i += 1) {
            var section = try buffer.readSection(&module);
        }
    }

    pub fn getFunction(self: *Self, function_name: []const u8) usize {}
};
