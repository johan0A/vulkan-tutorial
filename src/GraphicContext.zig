const std = @import("std");
const glfw = @import("mach-glfw");
const vk = @import("vulkan");
const Swapchain = @import("swapchain.zig");

const Allocator = std.mem.Allocator;

const Self = @This();

const validation_layers_enabled = false;
const validation_layers = [_][:0]const u8{"VK_LAYER_KHRONOS_validation"};

pub const required_device_extensions = [_][:0]const u8{
    vk.extensions.khr_swapchain.name,
};

pub const apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
};

pub const Dispatch = struct {
    pub const Base = vk.BaseWrapper(apis);
    pub const Instance = vk.InstanceWrapper(apis);
    pub const Device = vk.DeviceWrapper(apis);
    base: Base,
    instance: Instance,
    device: Device,
};

pub const QueueFamilyIndices = struct {
    graphics_family: ?u32,
    present_family: ?u32,
};

alloc: Allocator,

//glfw:
window: glfw.Window,

//vk:
dispatch: Dispatch,

instance: vk.Instance,
device: vk.Device,

graphics_queue: vk.Queue,
present_queue: vk.Queue,

surface: vk.SurfaceKHR,

swapchain: Swapchain,

pub fn init(allocator: Allocator) !Self {
    // NOTE: (should be checked again) most init time taken by glfw.init, glfw.Window.create and Dispatch.Base.load(@as(vk.PfnGetInstanceProcAddr, @ptrCast(&glfw.getInstanceProcAddress)))
    // might want to switch out glfw to something else, maybe RGFW

    glfw.setErrorCallback(glfwErrorCallback);
    if (glfw.init(.{}) != true) {
        return error.GLFWInitFailed;
    }

    const window = glfw.Window.create(
        640,
        480,
        "Vulkan Tutorial",
        null,
        null,
        .{ .resizable = false, .client_api = .no_api },
    ) orelse return error.GLFWCreateWindowFailed;

    const base_dispatch = try Dispatch.Base.load(@as(vk.PfnGetInstanceProcAddr, @ptrCast(&glfw.getInstanceProcAddress)));

    const instance = try createVkInstance(base_dispatch, allocator);
    const instance_dispatch = try Dispatch.Instance.load(instance, base_dispatch.dispatch.vkGetInstanceProcAddr);

    var surface: vk.SurfaceKHR = undefined;
    _ = glfw.createWindowSurface(instance, window, null, &surface);

    const physical_device = try pickPhysicalDevice(instance, instance_dispatch, surface, allocator);
    const queue_family_indices = try findQueueFamilies(physical_device, instance_dispatch, surface, allocator);

    const device = try createLogicalDevice(physical_device, queue_family_indices, instance_dispatch);
    const device_dispatch = try Dispatch.Device.load(device, instance_dispatch.dispatch.vkGetDeviceProcAddr);

    return .{
        .alloc = allocator,
        .dispatch = Dispatch{
            .base = base_dispatch,
            .device = device_dispatch,
            .instance = instance_dispatch,
        },
        .window = window,
        .instance = instance,
        .device = device,
        .graphics_queue = device_dispatch.getDeviceQueue(device, queue_family_indices.graphics_family.?, 0),
        .present_queue = device_dispatch.getDeviceQueue(device, queue_family_indices.present_family.?, 0),
        .surface = surface,
        .swapchain = try Swapchain.init(
            physical_device,
            device,
            device_dispatch,
            surface,
            window,
            queue_family_indices,
            instance_dispatch,
            allocator,
        ),
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.swapchain.deinit(self.device, self.dispatch.device, allocator);
    self.dispatch.device.destroyDevice(self.device, null);
    self.dispatch.instance.destroySurfaceKHR(self.instance, self.surface, null);
    self.dispatch.instance.destroyInstance(self.instance, null);
    self.window.destroy();
    glfw.terminate();
}

pub fn initVulkan(self: *Self) !void {
    _ = self; // autofix
}

pub fn mainLoop(self: Self) void {
    while (!self.window.shouldClose()) {
        glfw.pollEvents();
    }
}

pub fn createVkInstance(base_dispatch: Dispatch.Base, alloc: Allocator) !vk.Instance {
    const appinfo = vk.ApplicationInfo{
        .p_application_name = "Vulkan Tutorial",
        .application_version = vk.makeApiVersion(1, 0, 0, 0),
        .p_engine_name = "No Engine",
        .engine_version = vk.makeApiVersion(1, 0, 0, 0),
        .api_version = vk.makeApiVersion(1, 0, 0, 0),
    };

    const glfw_extensions = glfw.getRequiredInstanceExtensions() orelse return error.GLFWGetRequiredInstanceExtensionsFailed;

    if (validation_layers_enabled) {
        try checkValidationLayerSupport(alloc, base_dispatch);
    }

    const create_info = vk.InstanceCreateInfo{
        .p_application_info = &appinfo,
        .enabled_extension_count = @intCast(glfw_extensions.len),
        .pp_enabled_extension_names = glfw_extensions.ptr,
        .pp_enabled_layer_names = if (validation_layers_enabled) @ptrCast(&validation_layers) else null,
        .enabled_layer_count = if (validation_layers_enabled) @intCast(validation_layers.len) else 0,
    };

    // // TODO: add checking for extensions
    // const glfwExtensions = try base_dispatch.enumerateInstanceLayerPropertiesAlloc(alloc);
    // _ = glfwExtensions; // autofix

    return try base_dispatch.createInstance(
        &create_info,
        null,
    );
}

pub fn checkValidationLayerSupport(alloc: Allocator, base_dispatch: Dispatch.Base) !void {
    const available_layers = try base_dispatch.enumerateInstanceLayerPropertiesAlloc(alloc);
    defer alloc.free(available_layers);

    outer: for (validation_layers) |validation_layer| {
        for (available_layers) |available_layer| {
            if (std.mem.eql(
                u8,
                std.mem.span(@as([*:0]const u8, @ptrCast(&available_layer.layer_name))),
                validation_layer,
            )) {
                continue :outer;
            }
        }
        return error.NotAllValidationLayersSupported;
    }
}

pub fn createLogicalDevice(physical_device: vk.PhysicalDevice, queue_family_indices: QueueFamilyIndices, instance_dispatch: Dispatch.Instance) !vk.Device {
    const indices = [_]u32{
        queue_family_indices.graphics_family.?,
        queue_family_indices.present_family.?,
    };

    const queue_prioritie: f32 = 1;
    var queue_create_infos_buff: [indices.len]vk.DeviceQueueCreateInfo = undefined;
    var queue_create_infos = std.ArrayListUnmanaged(vk.DeviceQueueCreateInfo).initBuffer(&queue_create_infos_buff);
    outer: for (indices, 0..) |indice, i| {
        for (indices[0..i]) |previous_indice| {
            if (previous_indice == indice) continue :outer;
        }

        queue_create_infos.appendAssumeCapacity(.{
            .queue_family_index = indice,
            .queue_count = 1,
            .p_queue_priorities = @ptrCast(&queue_prioritie),
        });
    }

    const device_features = vk.PhysicalDeviceFeatures{};

    const create_info = vk.DeviceCreateInfo{
        .p_queue_create_infos = @ptrCast(queue_create_infos.items),
        .queue_create_info_count = @intCast(queue_create_infos.items.len),
        .p_enabled_features = &device_features,
        // TODO: apparently validation layers for device have been deprecated so should remove ?
        .pp_enabled_layer_names = if (validation_layers_enabled) @ptrCast(&validation_layers) else null,
        .enabled_layer_count = if (validation_layers_enabled) @intCast(validation_layers.len) else 0,
        .pp_enabled_extension_names = @ptrCast(&required_device_extensions),
        .enabled_extension_count = required_device_extensions.len,
    };

    return try instance_dispatch.createDevice(physical_device, &create_info, null);
}

pub fn pickPhysicalDevice(instance: vk.Instance, instance_dispatch: Dispatch.Instance, surface: vk.SurfaceKHR, alloc: Allocator) !vk.PhysicalDevice {
    const devices = try instance_dispatch.enumeratePhysicalDevicesAlloc(instance, alloc);
    defer alloc.free(devices);

    for (devices) |device| {
        if (try isPhysicalDeviceSuitable(device, instance_dispatch, surface, alloc)) {
            return device;
        }
    }

    return error.NoPhysicalDeviceFound;
}

pub fn isPhysicalDeviceSuitable(
    physical_device: vk.PhysicalDevice,
    instance_dispatch: Dispatch.Instance,
    surface: vk.SurfaceKHR,
    alloc: Allocator,
) !bool {
    const formats = try instance_dispatch.getPhysicalDeviceSurfaceFormatsAllocKHR(physical_device, surface, alloc);
    defer alloc.free(formats);
    const present_modes = try instance_dispatch.getPhysicalDeviceSurfacePresentModesAllocKHR(physical_device, surface, alloc);
    defer alloc.free(present_modes);
    return (try findQueueFamilies(physical_device, instance_dispatch, surface, alloc)).graphics_family != null and
        try checkDeviceExtensionSupport(physical_device, instance_dispatch, alloc) and
        formats.len > 0 and
        present_modes.len > 0;
}

pub fn checkDeviceExtensionSupport(physical_device: vk.PhysicalDevice, instance_dispatch: Dispatch.Instance, alloc: Allocator) !bool {
    const available_extensions = try instance_dispatch.enumerateDeviceExtensionPropertiesAlloc(physical_device, null, alloc);
    defer alloc.free(available_extensions);

    outer: for (required_device_extensions) |required_device_extension| {
        for (available_extensions) |available_extension| {
            if (std.mem.eql(
                u8,
                std.mem.span(@as([*:0]const u8, @ptrCast(&available_extension.extension_name))),
                required_device_extension,
            )) {
                continue :outer;
            }
        }
        return false;
    }

    return true;
}

pub fn findQueueFamilies(
    physical_device: vk.PhysicalDevice,
    instance_dispatch: Dispatch.Instance,
    surface: vk.SurfaceKHR,
    alloc: Allocator,
) !QueueFamilyIndices {
    var indices: QueueFamilyIndices = .{
        .graphics_family = null,
        .present_family = null,
    };

    const queue_families = try instance_dispatch.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, alloc);
    defer alloc.free(queue_families);

    // TODO: prefer queue that supports both graphics and KHR

    for (queue_families, 0..) |queue_familie, i| {
        if (queue_familie.queue_flags.graphics_bit) {
            indices.graphics_family = @intCast(i);
            break;
        }
    }

    for (queue_families, 0..) |_, i| {
        if ((try instance_dispatch.getPhysicalDeviceSurfaceSupportKHR(physical_device, @intCast(i), surface) != 0)) {
            indices.present_family = @intCast(i);
            break;
        }
    }

    return indices;
}

fn glfwErrorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}
