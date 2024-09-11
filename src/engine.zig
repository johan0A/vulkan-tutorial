const std = @import("std");
const glfw = @import("mach-glfw");
const vk = @import("vulkan");

const Allocator = std.mem.Allocator;

const Self = @This();

const validation_layers_enabled = true;
const validation_layers = [_][:0]const u8{"VK_LAYER_KHRONOS_validation"};

const apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
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

fn glfwErrorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

pub fn init(allocator: Allocator) !Self {
    glfw.setErrorCallback(glfwErrorCallback);
    if (glfw.init(.{}) != true) {
        return error.GLFWInitFailed;
    }

    const base_dispatch = try Dispatch.Base.load(@as(vk.PfnGetInstanceProcAddr, @ptrCast(&glfw.getInstanceProcAddress)));
    const instance = try createVkInstance(base_dispatch, allocator);
    const instance_dispatch = try Dispatch.Instance.load(instance, base_dispatch.dispatch.vkGetInstanceProcAddr);

    return .{
        .alloc = allocator,
        .dispatch = Dispatch{
            .base = base_dispatch,
            .device = undefined,
            .instance = instance_dispatch,
        },
        .window = try Self.initWindow(),
        .instance = instance,
        .device = undefined,
    };
}

fn pickPhysicalDevice(self: *Self) !vk.PhysicalDevice {
    const devices = try self.instance_dispatch.enumeratePhysicalDevicesAlloc(self.alloc);
    defer self.alloc.free(devices);

    for (devices) |device| {
        const properties = try self.instance_dispatch.getPhysicalDeviceProperties(device);
        if (properties.device_type == .discrete_gpu) {
            return device;
        }
    }

    return error.NoPhysicalDeviceFound;
}

fn isPhysicalDeviceSuitable(self: Self, physical_device: vk.PhysicalDevice) !bool {
    return self.findQueueFamilies(physical_device).graphics_family != null;
}

fn findQueueFamilies(self: Self, physical_device: vk.PhysicalDevice) QueueFamilyIndices {
    var indices: QueueFamilyIndices = .{
        .graphics_family = null,
    };

    const queue_families =
        try self.instance_dispatch.getPhysicalDeviceQueueFamilyPropertiesAlloc(physical_device, self.alloc);
    defer self.alloc.free(queue_families);

    for (queue_families, 0..) |queue_familie, i| {
        if (queue_familie.queue_flags == .graphics_bit) {
            indices.graphics_family = i;
            break;
        }
    }

    return indices;
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
        .enabled_layer_count = if (validation_layers_enabled) @intCast(validation_layers.len) else 0,
        .pp_enabled_layer_names = if (validation_layers_enabled) @ptrCast(&validation_layers) else null,
    };

    // // TODO: add checking for extensions
    // const glfwExtensions = try base_dispatch.enumerateInstanceLayerPropertiesAlloc(alloc);
    // _ = glfwExtensions; // autofix

    return try base_dispatch.createInstance(
        &create_info,
        null,
    );
}

pub fn initWindow() !glfw.Window {
    return glfw.Window.create(
        640,
        480,
        "Vulkan Tutorial",
        null,
        null,
        .{
            .resizable = false,
        },
    ) orelse return error.GLFWCreateWindowFailed;
}

pub fn initVulkan(self: *Self) !void {
    _ = self; // autofix
}

pub fn mainLoop(self: Self) void {
    while (!self.window.shouldClose()) {
        glfw.pollEvents();
    }
}

pub fn deinit(self: *Self) void {
    self.dispatch.instance.destroyInstance(self.instance, null);
    self.window.destroy();
    glfw.terminate();
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
        }
    }

    if (validation_layers_idx != validation_layers.len) {
        return error.ValidationLayersNotSupported;
    }
}
