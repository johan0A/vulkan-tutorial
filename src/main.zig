const std = @import("std");
const glfw = @import("mach-glfw");
const vk = @import("vulkan");
const Engine = @import("GraphicContext.zig");

pub fn main() !void {
    var timer = try std.time.Timer.start();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const init_allocators_time = timer.lap();

    var engine = try Engine.init(allocator);
    defer engine.deinit();

    const total_time = timer.lap();
    std.debug.print("init_allocators_time: {} ns\n", .{init_allocators_time});
    std.debug.print("total: {} s\n", .{@as(f64, @floatFromInt(total_time)) / 1000000000});

    engine.mainLoop();
}
