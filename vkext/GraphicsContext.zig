pub const xcb = @import("xcblazy.zig");

const required_device_extensions = [_][*:0]const u8{
    vk.extensions.khr_swapchain.name,
    // TODO: the app should control this!
    vk.extensions.ext_external_memory_host.name,
};

/// To construct base, instance and device wrappers for vulkan-zig, you need to pass a list of 'apis' to it.
const apis: []const vk.ApiInfo = &.{
    // You can either add invidiual functions by manually creating an 'api'
    .{
        .base_commands = .{
            .createInstance = true,
            .enumerateInstanceLayerProperties = true,
        },
        .instance_commands = .{
            .createDevice = true,
            .createXcbSurfaceKHR = true,
        },
    },
    // Or you can add entire feature sets or extensions
    vk.features.version_1_0,
    vk.extensions.khr_surface,
    vk.extensions.khr_swapchain,
    vk.extensions.ext_debug_utils,
    vk.extensions.ext_external_memory_host,
};

/// Next, pass the `apis` to the wrappers to create dispatch tables.
// const BaseDispatch = vk.BaseWrapper(apis);
// const InstanceDispatch = vk.InstanceWrapper(apis);
const BaseDispatch = vk.BaseWrapper;
const InstanceDispatch = vk.InstanceWrapper;
const DeviceDispatch = vk.DeviceWrapper;

// Also create some proxying wrappers, which also have the respective handles
// const Instance = vk.InstanceProxy(apis);
// const Device = vk.DeviceProxy(apis);
const Instance = vk.InstanceProxy;
const Device = vk.DeviceProxy;

pub const CommandBuffer = vk.CommandBufferProxy;

allocator: Allocator,

vkb: BaseDispatch,

instance: Instance,
surface: vk.SurfaceKHR,
pdev: vk.PhysicalDevice,
props: vk.PhysicalDeviceProperties,
mem_props: vk.PhysicalDeviceMemoryProperties,

wsi: Wsi,
dev: Device,
graphics_queue: Queue,
present_queue: Queue,

debug_messenger: vk.DebugUtilsMessengerEXT,

pub const Wsi = union(enum) {
    xcb: struct {
        connection: *xcb.Connection,
        window: xcb.Window,
    },
    wayland,

    fn disconnect(self: Wsi) void {
        switch (self) {
            .xcb => |wsi| xcb.disconnect(wsi.connection),
            .wayland => {},
        }
    }

    pub fn mapWindow(self: Wsi) void {
        switch (self) {
            .xcb => |wsi| {
                _ = xcb.map_window(wsi.connection, wsi.window);
                _ = xcb.flush(wsi.connection);
            },
            .wayland => @panic("TODO"),
        }
    }
};

pub const ValidationLayers = enum(u8) {
    no = 0,
    if_available = 1,
    require = 2,

    pub const default = if (builtin.mode == .Debug) .if_available else .no;
};

pub fn init(
    allocator: Allocator,
    app_name: [*:0]const u8,
    window: union(enum) {
        xcb: xcb.Window,
        wayland: void,
    },
    vkGetInstanceProcAddr: anytype,
    named: struct {
        validation_layers: ValidationLayers,
    },
) !GraphicsContext {
    var self: GraphicsContext = undefined;
    self.allocator = allocator;
    self.vkb = BaseDispatch.load(vkGetInstanceProcAddr);

    const app_info: vk.ApplicationInfo = .{
        .p_application_name = app_name,
        .application_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
        .p_engine_name = app_name,
        .engine_version = @bitCast(vk.makeApiVersion(0, 0, 0, 0)),
        .api_version = @bitCast(vk.API_VERSION_1_2),
    };

    var extension_names_buffer: [3][*:0]const u8 = undefined;
    var extension_names: std.ArrayListUnmanaged([*:0]const u8) = .{
        .items = extension_names_buffer[0..0],
        .capacity = extension_names_buffer.len,
    };
    extension_names.appendAssumeCapacity("VK_KHR_surface");
    extension_names.appendAssumeCapacity("VK_KHR_xcb_surface");
    switch (named.validation_layers) {
        .no => {},
        .if_available, .require => {
            extension_names.appendAssumeCapacity("VK_EXT_debug_utils");
        },
    }

    const validation_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"};
    const first_attempt_enabled_layers: []const [*:0]const u8 = switch (named.validation_layers) {
        .no => &.{},
        .if_available, .require => &validation_layers,
    };

    const instance = blk: {
        break :blk self.vkb.createInstance(&.{
            .p_application_info = &app_info,

            .enabled_extension_count = @intCast(extension_names.items.len),
            .pp_enabled_extension_names = extension_names.items.ptr,

            .enabled_layer_count = @intCast(first_attempt_enabled_layers.len),
            .pp_enabled_layer_names = first_attempt_enabled_layers.ptr,
        }, null) catch |err| switch (err) {
            error.LayerNotPresent => switch (named.validation_layers) {
                .no, .require => return error.LayerNotPresent,
                .if_available => {
                    std.log.info("validation layers not present, leaving them out", .{});
                    break :blk try self.vkb.createInstance(&.{
                        .p_application_info = &app_info,
                        .enabled_extension_count = @intCast(extension_names.items.len),
                        .pp_enabled_extension_names = extension_names.items.ptr,
                        .enabled_layer_count = 0,
                        .pp_enabled_layer_names = undefined,
                    }, null);
                },
            },
            else => |e| return e,
        };
    };

    const vki = try allocator.create(InstanceDispatch);
    errdefer allocator.destroy(vki);
    vki.* = InstanceDispatch.load(instance, self.vkb.dispatch.vkGetInstanceProcAddr.?);
    self.instance = Instance.init(instance, vki);
    errdefer self.instance.destroyInstance(null);

    switch (named.validation_layers) {
        .no => {},
        .if_available, .require => {
            self.debug_messenger = try self.instance.createDebugUtilsMessengerEXT(&.{
                .message_severity = .{
                    .error_bit_ext = true,
                    .warning_bit_ext = true,
                },
                .message_type = .{
                    .general_bit_ext = true,
                    .validation_bit_ext = true,
                    .performance_bit_ext = true,
                    .device_address_binding_bit_ext = true,
                },
                .pfn_user_callback = debugCallback,
            }, null);
        },
    }

    // Connects after extension is intiailized so libvulkan.so resolves libxcb.so
    self.wsi = switch (window) {
        .xcb => |xcb_window| b: {
            const display = std.posix.getenv("DISPLAY");
            std.log.info("vow: connecting to X11 DISPLAY {f}", .{xcb.fmtDisplay(display)});
            break :b .{ .xcb = .{
                .connection = (try xcb.connect(display))[0],
                .window = xcb_window,
            } };
        },
        .wayland => .wayland,
    };
    errdefer self.wsi.disconnect();

    self.surface = switch (self.wsi) {
        .xcb => |wsi| try createSurface(self.instance, wsi.connection, window.xcb),
        .wayland => @panic("TODO"),
    };
    errdefer self.instance.destroySurfaceKHR(self.surface, null);

    const candidate = try pickPhysicalDevice(self.instance, allocator, self.surface);
    self.pdev = candidate.pdev;
    self.props = candidate.props;

    const dev = try initializeCandidate(self.instance, candidate);

    const vkd = try allocator.create(DeviceDispatch);
    errdefer allocator.destroy(vkd);
    vkd.* = DeviceDispatch.load(dev, self.instance.wrapper.dispatch.vkGetDeviceProcAddr.?);
    self.dev = Device.init(dev, vkd);
    errdefer self.dev.destroyDevice(null);

    self.graphics_queue = Queue.init(self.dev, candidate.queues.graphics_family);
    self.present_queue = Queue.init(self.dev, candidate.queues.present_family);

    self.mem_props = self.instance.getPhysicalDeviceMemoryProperties(self.pdev);

    return self;
}

pub fn deinit(self: *const GraphicsContext) void {
    // self.wsi.disconnect();
    self.instance.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
    self.dev.destroyDevice(null);
    self.instance.destroySurfaceKHR(self.surface, null);
    self.instance.destroyInstance(null);

    // Don't forget to free the tables to prevent a memory leak.
    self.allocator.destroy(self.dev.wrapper);
    self.allocator.destroy(self.instance.wrapper);
}

pub fn deviceName(self: *const GraphicsContext) []const u8 {
    return std.mem.sliceTo(&self.props.device_name, 0);
}

pub fn findMemoryTypeIndex(self: *const GraphicsContext, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
    for (self.mem_props.memory_types[0..self.mem_props.memory_type_count], 0..) |mem_type, i| {
        if (memory_type_bits & (@as(u32, 1) << @truncate(i)) != 0 and mem_type.property_flags.contains(flags)) {
            return @truncate(i);
        }
    }

    return error.NoSuitableMemoryType;
}

pub fn allocate(self: *const GraphicsContext, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
    return try self.dev.allocateMemory(&.{
        .allocation_size = requirements.size,
        .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
    }, null);
}

pub const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(device: Device, family: u32) Queue {
        return .{
            .handle = device.getDeviceQueue(family, 0),
            .family = family,
        };
    }
};

fn createSurface(instance: Instance, connection: *vk.xcb_connection_t, window: vk.xcb_window_t) !vk.SurfaceKHR {
    var surface_create_info: vk.XcbSurfaceCreateInfoKHR = .{
        .connection = connection,
        .window = window,
    };
    return instance.createXcbSurfaceKHR(&surface_create_info, null);
}

fn initializeCandidate(instance: Instance, candidate: DeviceCandidate) !vk.Device {
    const priority = [_]f32{1};
    const qci = [_]vk.DeviceQueueCreateInfo{
        .{
            .queue_family_index = candidate.queues.graphics_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .queue_family_index = candidate.queues.present_family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };

    const queue_count: u32 = if (candidate.queues.graphics_family == candidate.queues.present_family)
        1
    else
        2;

    return try instance.createDevice(candidate.pdev, &.{
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &qci,
        .enabled_extension_count = required_device_extensions.len,
        .pp_enabled_extension_names = @ptrCast(&required_device_extensions),
    }, null);
}

const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queues: QueueAllocation,
};

const QueueAllocation = struct {
    graphics_family: u32,
    present_family: u32,
};

fn pickPhysicalDevice(
    instance: Instance,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !DeviceCandidate {
    const pdevs = try instance.enumeratePhysicalDevicesAlloc(allocator);
    defer allocator.free(pdevs);

    for (pdevs) |pdev| {
        if (try checkSuitable(instance, pdev, allocator, surface)) |candidate| {
            return candidate;
        }
    }

    return error.NoSuitableDevice;
}

fn checkSuitable(
    instance: Instance,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !?DeviceCandidate {
    if (!try checkExtensionSupport(instance, pdev, allocator)) {
        return null;
    }

    if (!try checkSurfaceSupport(instance, pdev, surface)) {
        return null;
    }

    if (try allocateQueues(instance, pdev, allocator, surface)) |allocation| {
        const props = instance.getPhysicalDeviceProperties(pdev);
        return DeviceCandidate{
            .pdev = pdev,
            .props = props,
            .queues = allocation,
        };
    }

    return null;
}

fn allocateQueues(instance: Instance, pdev: vk.PhysicalDevice, allocator: Allocator, surface: vk.SurfaceKHR) !?QueueAllocation {
    const families = try instance.getPhysicalDeviceQueueFamilyPropertiesAlloc(pdev, allocator);
    defer allocator.free(families);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (families, 0..) |properties, i| {
        const family: u32 = @intCast(i);

        if (graphics_family == null and properties.queue_flags.graphics_bit) {
            graphics_family = family;
        }

        if (present_family == null and (try instance.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface)) == .true) {
            present_family = family;
        }
    }

    if (graphics_family != null and present_family != null) {
        return QueueAllocation{
            .graphics_family = graphics_family.?,
            .present_family = present_family.?,
        };
    }

    return null;
}

fn checkSurfaceSupport(instance: Instance, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try instance.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn checkExtensionSupport(
    instance: Instance,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
) !bool {
    const propsv = try instance.enumerateDeviceExtensionPropertiesAlloc(pdev, null, allocator);
    defer allocator.free(propsv);

    for (required_device_extensions) |ext| {
        for (propsv) |props| {
            if (std.mem.eql(u8, std.mem.span(ext), std.mem.sliceTo(&props.extension_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }

    return true;
}

fn debugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    _ = message_severity;
    _ = message_types;
    _ = p_user_data;
    b: {
        const msg = (p_callback_data orelse break :b).p_message orelse break :b;
        std.log.scoped(.validation).warn("{s}", .{msg});
        return .false;
    }
    std.log.scoped(.validation).warn("unrecognized validation layer debug message", .{});
    return .false;
}

const builtin = @import("builtin");
const std = @import("std");
const vk = @import("vulkan");
const Allocator = std.mem.Allocator;
const GraphicsContext = @This();
