const std = @import("std");
const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("CL/opencl.h");
});

const spirv = struct {
    const Word = u32;
    const magic: Word = 0x07230203;

    // magic + version + generator + bound + schema
    const header_size = 5;

    // We only really care about this instruction, so no need to pull in the entire spir-v spec here.
    const OpEntryPoint = 15;
    const entrypoint_name_offset = 3;
};

pub const std_options = struct {
    pub const log_level = .info;
};

var log_verbose: bool = false;

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = scope;
    if (@enumToInt(level) >= @enumToInt(std.log.Level.warn) or log_verbose) {
        const prefix = comptime level.asText();
        std.debug.print(prefix ++ ": " ++ format ++ "\n", args);
    }
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(1);
}

fn checkCl(status: c.cl_int) !void {
    if (status != c.CL_SUCCESS) {
        // TODO: Error names?
        std.log.err("opencl returned error {}", .{status});
        return error.ClError;
    }
}

const Options = struct {
    platform: ?[]const u8,
    device: ?[]const u8,
    verbose: bool,
    module: []const u8,
};

fn parseArgs(arena: Allocator) !Options {
    var args = try std.process.argsWithAllocator(arena);
    _ = args.next(); // executable name

    var platform: ?[]const u8 = null;
    var device: ?[]const u8 = null;
    var verbose: bool = false;
    var help: bool = false;
    var module: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--platform") or std.mem.eql(u8, arg, "-p")) {
            platform = args.next() orelse fail("missing argument to option {s}", .{arg});
        } else if (std.mem.eql(u8, arg, "--device") or std.mem.eql(u8, arg, "-d")) {
            device = args.next() orelse fail("missing argument to option {s}", .{arg});
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            help = true;
        } else if (module == null) {
            module = arg;
        } else {
            fail("unknown option '{s}'", .{arg});
        }
    }

    if (help) {
        const out = std.io.getStdOut();
        try out.writer().writeAll(
            \\usage: zig-spirv-executor [options...] <spir-v module path>
            \\
            \\This program can be used to execute tests in a SPIR-V binary produced by
            \\`zig test`, together with zig-spirv-runner.zig. For example, to run all tests
            \\in a zig file under spir-v, use
            \\
            \\    zig test \
            \\        --test-cmd zig-spirv-executor --test-cmd-bin \
            \\        --test-runner src/test_runner.zig \
            \\        file.zig
            \\
            \\Alternatively, this program can also be used to test a standalone executable,
            \\as long as every entry point in the spir-v module to test is a kernel, and
            \\every entrypoint in the module has the signature `fn(result: *u32) void`.
            \\`result` must be set to 1 if the test passes, or left 0 if the test fails.
            \\
            \\Options:
            \\--program -p <platform>   OpenCL platform name to use. By default, uses the
            \\                          first platform that has any devices available.
            \\                          Note that the platform must support the
            \\                          'cl_khr_il_program' extension.
            \\--device -d <device>      OpenCL device name to use. If --platform is left
            \\                          unspecified, all devices of all platforms are
            \\                          matched. By default, uses the first device of the
            \\                          platform.
            \\--verbose -v              Turn on verbose logging.
            \\--help -h                 Show this message and exit.
            \\
        );
        std.process.exit(0);
    }

    return .{
        .platform = platform,
        .device = device,
        .verbose = verbose,
        .module = module orelse fail("missing required argument <spir-v module path>", .{}),
    };
}

fn platformName(arena: Allocator, platform: c.cl_platform_id) ![]const u8 {
    var name_size: usize = undefined;
    try checkCl(c.clGetPlatformInfo(platform, c.CL_PLATFORM_NAME, 0, null, &name_size));
    const name = try arena.alloc(u8, name_size);
    try checkCl(c.clGetPlatformInfo(platform, c.CL_PLATFORM_NAME, name_size, name.ptr, null));
    return name;
}

fn platformDevices(arena: Allocator, platform: c.cl_platform_id) ![]const c.cl_device_id {
    var num_devices: c.cl_uint = undefined;
    switch (c.clGetDeviceIDs(platform, c.CL_DEVICE_TYPE_ALL, 0, null, &num_devices)) {
        c.CL_DEVICE_NOT_FOUND => return &.{},
        else => |err| try checkCl(err),
    }
    const devices = try arena.alloc(c.cl_device_id, num_devices);
    try checkCl(c.clGetDeviceIDs(platform, c.CL_DEVICE_TYPE_ALL, num_devices, devices.ptr, null));
    return devices;
}

fn deviceSupportsSpirv(arena: Allocator, device: c.cl_device_id) !bool {
    // TODO: Check for OpenCL 3.0 before accessing this function?
    var ils_size: usize = undefined;
    try checkCl(c.clGetDeviceInfo(device, c.CL_DEVICE_ILS_WITH_VERSION, 0, null, &ils_size));
    const ils = try arena.alloc(c.cl_name_version, ils_size / @sizeOf(c.cl_name_version));
    try checkCl(c.clGetDeviceInfo(device, c.CL_DEVICE_ILS_WITH_VERSION, ils_size, ils.ptr, null));

    for (ils) |il| {
        const name_len = std.mem.indexOfScalar(u8, &il.name, 0).?;
        const name = il.name[0..name_len];

        // TODO: Minimum version?
        if (std.mem.eql(u8, name, "SPIR-V")) {
            std.log.info("Support for SPIR-V version {}.{}.{} detected", .{
                c.CL_VERSION_MAJOR(il.version),
                c.CL_VERSION_MINOR(il.version),
                c.CL_VERSION_PATCH(il.version),
            });
            return true;
        }
    }

    return false;
}

fn deviceName(arena: Allocator, device: c.cl_device_id) ![]const u8 {
    var name_size: usize = undefined;
    try checkCl(c.clGetDeviceInfo(device, c.CL_DEVICE_NAME, 0, null, &name_size));
    const name = try arena.alloc(u8, name_size);
    try checkCl(c.clGetDeviceInfo(device, c.CL_DEVICE_NAME, name_size, name.ptr, null));
    return name;
}

fn pickDevice(arena: Allocator, platform: c.cl_platform_id, query: ?[]const u8) !c.cl_device_id {
    const devices = try platformDevices(arena, platform);
    if (devices.len == 0) {
        return error.NoDevices;
    }

    if (query) |device_query| {
        for (devices) |device_id| {
            const device_name = try deviceName(arena, device_id);
            if (std.mem.indexOf(u8, device_name, device_query) != null) {
                if (!try deviceSupportsSpirv(arena, device_id)) {
                    fail("device '{s}' does not support spir-v ingestion", .{device_name});
                }
                return device_id;
            }
        }

        return error.NoSuchDevice;
    } else {
        for (devices) |device_id| {
            if (try deviceSupportsSpirv(arena, device_id)) {
                return device_id;
            }
        }

        return error.NoSpirvSupport;
    }
}

fn pickPlatformAndDevice(
    arena: Allocator,
    options: Options,
    platform: *c.cl_platform_id,
    device: *c.cl_device_id,
) !void {
    var num_platforms: c.cl_uint = undefined;
    try checkCl(c.clGetPlatformIDs(0, null, &num_platforms));
    std.log.info("{} platform(s) available", .{num_platforms});

    if (num_platforms == 0) {
        fail("no opencl platform available", .{});
    }

    var platforms = try arena.alloc(c.cl_platform_id, num_platforms);
    try checkCl(c.clGetPlatformIDs(num_platforms, platforms.ptr, null));

    if (options.platform) |platform_query| {
        const platform_name = for (platforms) |platform_id| {
            const name = try platformName(arena, platform_id);
            if (std.mem.indexOf(u8, name, platform_query) != null) {
                platform.* = platform_id;
                break name;
            }
        } else {
            fail("no such opencl platform '{s}'", .{platform_query});
        };

        std.log.info("using platform '{s}'", .{platform_name});

        device.* = pickDevice(arena, platform.*, options.device) catch |err| switch (err) {
            error.NoDevices => fail("no opencl devices available for platform", .{}),
            error.NoSuchDevice => fail("no such opencl device: '{s}'", .{options.device.?}),
            error.NoSpirvSupport => fail("platform has no devices that support spir-v", .{}),
            else => return err,
        };
    } else if (options.device) |device_query| {
        // Loop through all platforms to find one which matches the device
        for (platforms) |platform_id| {
            device.* = pickDevice(arena, platform_id, device_query) catch |err| switch (err) {
                error.NoDevices, error.NoSuchDevice => continue,
                error.NoSpirvSupport => unreachable,
                else => return err,
            };

            platform.* = platform_id;
            std.log.info("using platform '{s}'", .{try platformName(arena, platform_id)});
            break;
        } else {
            fail("no such opencl device '{s}'", .{device_query});
        }
    } else {
        for (platforms) |platform_id| {
            device.* = pickDevice(arena, platform_id, null) catch |err| switch (err) {
                error.NoDevices, error.NoSpirvSupport => continue,
                error.NoSuchDevice => unreachable,
                else => return err,
            };
            platform.* = platform_id;
            std.log.info("using platform '{s}'", .{try platformName(arena, platform_id)});
            break;
        } else {
            fail("no opencl platform that has any devices which support spir-v ingestion", .{});
        }
    }

    std.log.info("using device '{s}'", .{try deviceName(arena, device.*)});
}

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const options = try parseArgs(arena);
    if (options.verbose) {
        log_verbose = true;
    }

    std.log.info("loading spir-v module '{s}'", .{options.module});

    const module_bytes = std.fs.cwd().readFileAllocOptions(
        arena,
        options.module,
        std.math.maxInt(usize),
        1 * 1024 * 1024,
        @alignOf(spirv.Word),
        null,
    ) catch |err| {
        fail("failed to open module '{s}': {s}", .{ options.module, @errorName(err) });
    };

    if (module_bytes.len % @sizeOf(spirv.Word) != 0) {
        fail("file is not a spir-v module - module size is not multiple of spir-v word size", .{});
    }

    const module = std.mem.bytesAsSlice(spirv.Word, module_bytes);

    if (module[0] != spirv.magic) {
        if (@byteSwap(module[0]) == spirv.magic) {
            fail("zig doesn't produce big-endian spir-v binaries", .{});
        }

        fail("invalid spir-v magic", .{});
    }

    // Collect all the entry points from the spir-v binary.
    var entry_points = std.ArrayList([:0]const u8).init(arena);
    var i: usize = spirv.header_size;
    while (i < module.len) {
        const instruction_len = module[i] >> 16;
        defer i += instruction_len;

        const opcode = module[i] & 0xFFFF;
        if (opcode != spirv.OpEntryPoint) {
            // Dont care about this instruction.
            continue;
        }

        // Entry point layout:
        // - opcode and length (1 word)
        // - execution model (1 word)
        // - function reference (1 word)
        // - name (string literal, variable) <-- we want this
        // - interface (variable)
        const name_ptr = std.mem.sliceAsBytes(module[i + spirv.entrypoint_name_offset ..]);
        const name = std.mem.sliceTo(name_ptr, 0);
        try entry_points.append(name_ptr[0 .. name.len :0]);
    }

    std.log.info("module has {} entry point(s)", .{entry_points.items.len});

    if (entry_points.items.len == 0) {
        // Nothing to test.
        return;
    }

    var platform: c.cl_platform_id = undefined;
    var device: c.cl_device_id = undefined;
    try pickPlatformAndDevice(arena, options, &platform, &device);

    var status: c.cl_int = undefined;

    const properties = [_]c.cl_context_properties{
        c.CL_CONTEXT_PLATFORM,
        @bitCast(c.cl_context_properties, @ptrToInt(platform)),
        0,
    };

    const context = c.clCreateContext(&properties, 1, &device, null, null, &status);
    try checkCl(status);
    defer _ = c.clReleaseContext(context);

    const queue = c.clCreateCommandQueue(context, device, c.CL_QUEUE_PROFILING_ENABLE, &status);
    try checkCl(status);

    // All spir-v kernels can be launched from the same program.
    // TODO: Check that this function is actually available, and error out otherwise.
    const program = c.clCreateProgramWithIL(
        context,
        @ptrCast(*const anyopaque, module_bytes.ptr),
        module_bytes.len,
        &status,
    );
    try checkCl(status);
    defer _ = c.clReleaseProgram(program);

    status = c.clBuildProgram(program, 1, &device, null, null, null);
    if (status == c.CL_BUILD_PROGRAM_FAILURE) {
        var build_log_size: usize = undefined;
        try checkCl(c.clGetProgramBuildInfo(
            program,
            device,
            c.CL_PROGRAM_BUILD_LOG,
            0,
            null,
            &build_log_size,
        ));
        const build_log = try arena.alloc(u8, build_log_size);
        try checkCl(c.clGetProgramBuildInfo(
            program,
            device,
            c.CL_PROGRAM_BUILD_LOG,
            build_log_size,
            build_log.ptr,
            null,
        ));
        std.log.err("Failed to build program:\n{s}", .{build_log});
    }
    try checkCl(status);

    for (entry_points.items) |name| {
        std.log.info("running test for kernel '{s}'", .{name});
        const kernel = c.clCreateKernel(program, name.ptr, &status);
        try checkCl(status);
        defer _= c.clReleaseKernel(kernel);

        // TODO: Pass global result buffer.

        var kernel_completed_event: c.cl_event = undefined;
        const global_work_size: usize = 1;
        const local_work_size: usize = 1;
        try checkCl(c.clEnqueueNDRangeKernel(
            queue,
            kernel,
            1,
            null,
            &global_work_size,
            &local_work_size,
            0,
            null,
            &kernel_completed_event,
        ));

        try checkCl(c.clWaitForEvents(1, &kernel_completed_event));

        var start: c.cl_ulong = undefined;
        var stop: c.cl_ulong = undefined;
        _ = c.clGetEventProfilingInfo(kernel_completed_event, c.CL_PROFILING_COMMAND_START, @sizeOf(c.cl_ulong), &start, null);
        _ = c.clGetEventProfilingInfo(kernel_completed_event, c.CL_PROFILING_COMMAND_END, @sizeOf(c.cl_ulong), &stop, null);
        std.log.info("kernel runtime: {}us", .{(stop - start) / std.time.ns_per_us});
    }
}
