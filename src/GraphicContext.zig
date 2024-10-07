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

render_pass: vk.RenderPass,
pipeline_layout: vk.PipelineLayout,

graphics_pipeline: vk.Pipeline,

fn glfwErrorCallback(error_code: glfw.ErrorCode, description: [:0]const u8) void {
    std.log.err("glfw: {}: {s}\n", .{ error_code, description });
}

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

    const swapchain = try Swapchain.init(
        physical_device,
        device,
        device_dispatch,
        surface,
        window,
        queue_family_indices,
        instance_dispatch,
        allocator,
    );

    const render_pass = try createRenderPass(swapchain.surface_format, device, device_dispatch);

    const pipeline_layout, const graphic_pipeline = try createGraphicPipeline(device, device_dispatch, render_pass);

    return Self{
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
        .swapchain = swapchain,
        .pipeline_layout = pipeline_layout,
        .render_pass = render_pass,
        .graphics_pipeline = graphic_pipeline,
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.dispatch.device.destroyPipeline(self.device, self.graphics_pipeline, null);
    self.dispatch.device.destroyPipelineLayout(self.device, self.pipeline_layout, null);
    self.dispatch.device.destroyRenderPass(self.device, self.render_pass, null);
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

pub fn createGraphicPipeline(device: vk.Device, device_dispatch: Dispatch.Device, render_pass: vk.RenderPass) !struct { vk.PipelineLayout, vk.Pipeline } {
    const vert_shader_code align(@alignOf(u32)) = @embedFile("vertex_shader").*;
    const frag_shader_code align(@alignOf(u32)) = @embedFile("fragment_shader").*;

    const vert_shader_module = try createShaderModule(device, device_dispatch, @ptrCast(&vert_shader_code));
    defer device_dispatch.destroyShaderModule(device, vert_shader_module, null);
    const frag_shader_module = try createShaderModule(device, device_dispatch, @ptrCast(&frag_shader_code));
    defer device_dispatch.destroyShaderModule(device, frag_shader_module, null);

    const vert_shader_stage_info = vk.PipelineShaderStageCreateInfo{
        .stage = .{ .vertex_bit = true },
        .module = vert_shader_module,
        .p_name = "main",
    };

    const frag_shader_stage_info = vk.PipelineShaderStageCreateInfo{
        .stage = .{ .fragment_bit = true },
        .module = frag_shader_module,
        .p_name = "main",
    };

    const shader_stages = [2]vk.PipelineShaderStageCreateInfo{
        vert_shader_stage_info,
        frag_shader_stage_info,
    };

    const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 0,
        .p_vertex_binding_descriptions = null,
        .vertex_attribute_description_count = 0,
        .p_vertex_attribute_descriptions = null,
    };

    const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = vk.FALSE,
    };

    // TODO: move this to command buffer
    // const viewport = vk.Viewport{
    //     .x = 0,
    //     .y = 0,
    //     .width = @floatFromInt(swapchain_extent.width),
    //     .height = @floatFromInt(swapchain_extent.height),
    //     .min_depth = 0,
    //     .max_depth = 1,
    // };
    // _ = viewport; // autofix

    // const scissors = vk.Rect2D{
    //     .offset = .{ .x = 0, .y = 0 },
    //     .extent = swapchain_extent,
    // };
    // _ = scissors; // autofix

    const dynamic_states = [_]vk.DynamicState{
        .viewport,
        .scissor,
    };
    const dynamic_state_info = vk.PipelineDynamicStateCreateInfo{
        .p_dynamic_states = &dynamic_states,
        .dynamic_state_count = dynamic_states.len,
    };

    const viewport_state = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .scissor_count = 1,
    };

    const rasterizer = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = vk.FALSE,
        .rasterizer_discard_enable = vk.FALSE,
        .polygon_mode = .fill,
        .line_width = 1,
        .cull_mode = .{ .back_bit = true },
        .front_face = .clockwise,
        .depth_bias_enable = vk.FALSE,
        .depth_bias_constant_factor = 0,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
    };

    const multi_sampling = vk.PipelineMultisampleStateCreateInfo{
        .sample_shading_enable = vk.FALSE,
        .min_sample_shading = 1,
        .rasterization_samples = .{ .@"1_bit" = true },
        .p_sample_mask = null,
        .alpha_to_coverage_enable = vk.FALSE,
        .alpha_to_one_enable = vk.FALSE,
    };

    const color_blend_attachement = vk.PipelineColorBlendAttachmentState{
        .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        .blend_enable = vk.FALSE,
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .zero,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .zero,
        .alpha_blend_op = .add,
    };

    const color_blending = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = vk.FALSE,
        .logic_op = .copy,
        .p_attachments = @ptrCast(&color_blend_attachement),
        .attachment_count = 1,
        .blend_constants = .{ 0, 0, 0, 0 },
    };

    const pipepline_layout_info = vk.PipelineLayoutCreateInfo{
        .set_layout_count = 0,
        .p_set_layouts = null,
        .push_constant_range_count = 0,
        .p_push_constant_ranges = null,
    };
    const pipepline_layout = try device_dispatch.createPipelineLayout(device, &pipepline_layout_info, null);

    const pipeline_create_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = 2,
        .p_stages = &shader_stages,
        .p_vertex_input_state = &vertex_input_info,
        .p_input_assembly_state = &input_assembly,
        .p_viewport_state = &viewport_state,
        .p_rasterization_state = &rasterizer,
        .p_multisample_state = &multi_sampling,
        .p_depth_stencil_state = null,
        .p_color_blend_state = &color_blending,
        .p_dynamic_state = &dynamic_state_info,
        .layout = pipepline_layout,
        .render_pass = render_pass,
        .subpass = 0,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
    };

    var graphic_pipeline: vk.Pipeline = undefined;
    _ = try device_dispatch.createGraphicsPipelines(
        device,
        .null_handle,
        1,
        @ptrCast(&pipeline_create_info),
        null,
        @ptrCast(&graphic_pipeline),
    );

    return .{
        pipepline_layout,
        graphic_pipeline,
    };
}

pub fn createShaderModule(device: vk.Device, device_dispatch: Dispatch.Device, code: []align(@alignOf(u32)) const u8) !vk.ShaderModule {
    const create_info = vk.ShaderModuleCreateInfo{
        .code_size = code.len,
        .p_code = @ptrCast(code),
    };
    return try device_dispatch.createShaderModule(device, &create_info, null);
}

pub fn createRenderPass(swapchain_surface_format: vk.SurfaceFormatKHR, device: vk.Device, device_dispatch: Dispatch.Device) !vk.RenderPass {
    const color_attachement = vk.AttachmentDescription{
        .format = swapchain_surface_format.format,
        .samples = .{ .@"1_bit" = true },
        .load_op = .clear,
        .store_op = .store,
        .stencil_load_op = .dont_care,
        .stencil_store_op = .dont_care,
        .initial_layout = .undefined,
        .final_layout = .present_src_khr,
    };

    const color_attachement_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = .color_attachment_optimal,
    };

    const subpass = vk.SubpassDescription{
        .pipeline_bind_point = .graphics,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&color_attachement_ref),
    };

    const render_pass_create_info = vk.RenderPassCreateInfo{
        .attachment_count = 1,
        .p_attachments = @ptrCast(&color_attachement),
        .subpass_count = 1,
        .p_subpasses = @ptrCast(&subpass),
    };
    return try device_dispatch.createRenderPass(device, &render_pass_create_info, null);
}
