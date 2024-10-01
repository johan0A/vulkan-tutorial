const std = @import("std");
const glfw = @import("mach-glfw");
const vk = @import("vulkan");
const Engine = @import("engine.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var engine = try Engine.init(allocator);
    defer engine.deinit();

    engine.mainLoop();
}
