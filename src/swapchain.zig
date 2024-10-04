const std = @import("std");
const glfw = @import("mach-glfw");
const vk = @import("vulkan");
const GC = @import("GraphicContext.zig");

const Allocator = std.mem.Allocator;

const Self = @This();

const Dispatch = GC.Dispatch;

surface_format: vk.SurfaceFormatKHR,
present_mode: vk.PresentModeKHR,
extent: vk.Extent2D,

handle: vk.SwapchainKHR,

swap_images: []vk.Image,
swap_image_views: []vk.ImageView,

pub fn init(
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    device_dispatch: Dispatch.Device,
    surface: vk.SurfaceKHR,
    window: glfw.Window,
    queue_families: GC.QueueFamilyIndices,
    instance_dispatch: Dispatch.Instance,
    alloc: Allocator,
) !Self {
    const capabilities = try instance_dispatch.getPhysicalDeviceSurfaceCapabilitiesKHR(physical_device, surface);
    const available_formats = try instance_dispatch.getPhysicalDeviceSurfaceFormatsAllocKHR(physical_device, surface, alloc);
    defer alloc.free(available_formats);
    const available_present_modes = try instance_dispatch.getPhysicalDeviceSurfacePresentModesAllocKHR(physical_device, surface, alloc);
    defer alloc.free(available_present_modes);

    const present_mode = blk: {
        for (available_present_modes) |present_mode| {
            if (present_mode == .mailbox_khr) break :blk present_mode;
        }
        break :blk vk.PresentModeKHR.fifo_khr;
    };

    const extent = blk: {
        if (capabilities.current_extent.width != std.math.maxInt(u32)) {
            break :blk capabilities.current_extent;
        }

        const size = window.getFramebufferSize();
        break :blk vk.Extent2D{
            .height = std.math.clamp(size.height, capabilities.min_image_extent.height, capabilities.max_image_extent.height),
            .width = std.math.clamp(size.width, capabilities.min_image_extent.width, capabilities.max_image_extent.width),
        };
    };

    const surface_format = blk: {
        for (available_formats) |format| {
            if (format.format == .b8g8r8a8_srgb and format.color_space == .srgb_nonlinear_khr) break :blk format;
        }
        // TODO: rank by quality of format before picking backup format
        break :blk available_formats[0];
    };

    const image_count: u32 = if (capabilities.max_image_count != 0 and capabilities.max_image_count < capabilities.min_image_count + 1)
        capabilities.max_image_count
    else
        capabilities.min_image_count + 1;

    const swapchain = blk: {
        var create_info = vk.SwapchainCreateInfoKHR{
            .surface = surface,
            .min_image_count = image_count,
            .image_format = surface_format.format,
            .image_color_space = surface_format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .pre_transform = capabilities.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = present_mode,
            .clipped = @intFromBool(false),
            .old_swapchain = .null_handle,
            .image_sharing_mode = .exclusive,
        };
        if (queue_families.graphics_family.? == queue_families.present_family.?) {
            create_info.image_sharing_mode = .concurrent;
            create_info.queue_family_index_count = 2;
            create_info.p_queue_family_indices = &.{ queue_families.graphics_family.?, queue_families.present_family.? };
        } else {
            create_info.image_sharing_mode = .exclusive;
        }
        break :blk try device_dispatch.createSwapchainKHR(device, &create_info, null);
    };

    const swap_images = try device_dispatch.getSwapchainImagesAllocKHR(device, swapchain, alloc);

    const swap_image_views = blk: {
        const swap_image_views = try alloc.alloc(vk.ImageView, swap_images.len);
        for (swap_images, swap_image_views) |swap_image, *view| {
            const create_info = vk.ImageViewCreateInfo{
                .image = swap_image,
                .view_type = .@"2d",
                .format = surface_format.format,
                .components = .{ .a = .identity, .b = .identity, .g = .identity, .r = .identity },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            };
            view.* = try device_dispatch.createImageView(device, &create_info, null);
        }
        break :blk swap_image_views;
    };

    return Self{
        .extent = extent,
        .present_mode = present_mode,
        .surface_format = surface_format,
        .handle = swapchain,
        .swap_images = swap_images,
        .swap_image_views = swap_image_views,
    };
}

pub fn deinit(self: Self, device: vk.Device, device_dispatch: Dispatch.Device, alloc: Allocator) void {
    for (self.swap_image_views) |image_view| {
        device_dispatch.destroyImageView(device, image_view, null);
    }
    alloc.free(self.swap_image_views);
    device_dispatch.destroySwapchainKHR(device, self.handle, null);
    alloc.free(self.swap_images);
}
