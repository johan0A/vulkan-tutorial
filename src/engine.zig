const std = @import("std");
const glfw = @import("mach-glfw");
const vk = @import("vulkan");

const Allocator = std.mem.Allocator;

const Self = @This();

const validation_layers_enabled = true;
const validation_layers = [_][:0]const u8{"VK_LAYER_KHRONOS_validation"};

const apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    // vk.extensions.khr_surface,
    // vk.extensions.khr_swapchain,
};

const Dispatch = struct {
    pub const Base = vk.BaseWrapper(apis);
    pub const Instance = vk.InstanceWrapper(apis);
    pub const Device = vk.DeviceWrapper(apis);
    base: Base,
    instance: Instance,
    device: Device,
};

const QueueFamilyIndices = struct {
    graphics_family: ?u32,
};

alloc: Allocator,

//glfw:
window: glfw.Window,

//vk:
dispatch: Dispatch,

instance: vk.Instance,
device: vk.Device,

pub fn init(allocator: Allocator) !Self {
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
        .{ .resizable = false },
    ) orelse return error.GLFWCreateWindowFailed;

    const base_dispatch = try Dispatch.Base.load(@as(vk.PfnGetInstanceProcAddr, @ptrCast(&glfw.getInstanceProcAddress)));

    const instance = try createVkInstance(base_dispatch, allocator);
    const instance_dispatch = try Dispatch.Instance.load(instance, base_dispatch.dispatch.vkGetInstanceProcAddr);

    const physical_device = try pickPhysicalDevice(instance, instance_dispatch, allocator);
    const queue_family_indices = try findQueueFamilies(physical_device, instance_dispatch, allocator);

    const device = try createLogicalDevice(physical_device, queue_family_indices.graphics_family.?, instance_dispatch);
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
    };
}

pub fn deinit(self: *Self) void {
    self.dispatch.device.destroyDevice(self.device, null);
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

fn createVkInstance(base_dispatch: Dispatch.Base, alloc: Allocator) !vk.Instance {
    const appinfo = vk.ApplicationInfo{
        .s_type = .application_info,
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
        .s_type = .instance_create_info,
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

fn checkValidationLayerSupport(alloc: Allocator, base_dispatch: Dispatch.Base) !void {
    const available_layers = try base_dispatch.enumerateInstanceLayerPropertiesAlloc(alloc);
    defer alloc.free(available_layers);

    var validation_layers_idx: usize = 0;
    for (available_layers) |available_layer| {
        if (std.mem.eql(
            u8,
            std.mem.span(@as([*c]const u8, @ptrCast(&available_layer.layer_name))),
            validation_layers[validation_layers_idx],
        )) {
            validation_layers_idx += 1;
            if (validation_layers_idx >= validation_layers.len) break;
        }
    }

    if (validation_layers_idx != validation_layers.len) {
        return error.NotAllValidationLayersSupported;
    }
}

fn createLogicalDevice(physical_device: vk.PhysicalDevice, device_graphic_queue_family_index: u32, instance_dispatch: Dispatch.Instance) !vk.Device {
    const queue_prioritie: f32 = 1;
    const queue_create_info = vk.DeviceQueueCreateInfo{
        .s_type = .device_queue_create_info,
        .queue_family_index = device_graphic_queue_family_index,
        .queue_count = 1,
        .p_queue_priorities = @ptrCast(&queue_prioritie),
    };

    const device_features = vk.PhysicalDeviceFeatures{};

    const create_info = vk.DeviceCreateInfo{
        .s_type = .device_create_info,
        .p_queue_create_infos = @ptrCast(&queue_create_info),
        .queue_create_info_count = 1,
        .p_enabled_features = &device_features,
        .pp_enabled_layer_names = if (validation_layers_enabled) @ptrCast(&validation_layers) else null,
        .enabled_layer_count = if (validation_layers_enabled) @intCast(validation_layers.len) else 0,
    };

    return try instance_dispatch.createDevice(physical_device, &create_info, null);
}

fn pickPhysicalDevice(instance: vk.Instance, instance_dispatch: Dispatch.Instance, alloc: Allocator) !vk.PhysicalDevice {
    const devices = try instance_dispatch.enumeratePhysicalDevicesAlloc(instance, alloc);
    defer alloc.free(devices);

    for (devices) |device| {
        if (try isPhysicalDeviceSuitable(device, instance_dispatch, alloc)) {
            return device;
        }
    }

    return error.NoPhysicalDeviceFound;
}

fn isPhysicalDeviceSuitable(
    physical_device: vk.PhysicalDevice,
    instance_dispatch: Dispatch.Instance,
    alloc: Allocator,
) !bool {
    return (try findQueueFamilies(physical_device, instance_dispatch, alloc)).graphics_family != null;
}

fn findQueueFamilies(
    physical_device: vk.PhysicalDevice,
    instance_dispatch: Dispatch.Instance,
    alloc: Allocator,
) !QueueFamilyIndices {
    var indices: QueueFamilyIndices = .{
        .graphics_family = null,
    };

    const queue_families = try instance_dispatch.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, alloc);
    defer alloc.free(queue_families);

    for (queue_families, 0..) |queue_familie, i| {
        if (queue_familie.queue_flags.graphics_bit) {
            indices.graphics_family = @intCast(i);
            break;
        }
    }

    return indices;
}

fn glfwErrorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}
