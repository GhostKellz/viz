const std = @import("std");
const viz = @import("viz");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa_state.deinit();
        if (deinit_status == .leak) {
            std.log.warn("GeneralPurposeAllocator detected a leak", .{});
        }
    }
    const allocator = gpa_state.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const exe_name = args.next() orelse "viz";
    const command = args.next() orelse {
        try printUsage(exe_name);
        return;
    };

    if (std.mem.eql(u8, command, "info")) {
        const input_path = args.next() orelse {
            try printUsage(exe_name);
            return error.InvalidArguments;
        };
        var image = try viz.Image.loadPPMFile(allocator, input_path);
        defer image.deinit();
        std.debug.print("{s}: {d}x{d}\n", .{ input_path, image.width, image.height });
    } else if (std.mem.eql(u8, command, "brighten")) {
        const input_path = args.next() orelse {
            try printUsage(exe_name);
            return error.InvalidArguments;
        };
        const output_path = args.next() orelse {
            try printUsage(exe_name);
            return error.InvalidArguments;
        };
        const factor_str = args.next() orelse {
            try printUsage(exe_name);
            return error.InvalidArguments;
        };
        const factor = std.fmt.parseFloat(f32, factor_str) catch {
            std.log.err("invalid brightness factor: {s}", .{factor_str});
            return error.InvalidArguments;
        };

        var image = try viz.Image.loadPPMFile(allocator, input_path);
        defer image.deinit();
        image.applyBrightness(factor);
        try image.writePPMFile(output_path);
    } else if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        try printUsage(exe_name);
    } else {
        std.log.err("unknown command '{s}'", .{command});
        try printUsage(exe_name);
        return error.InvalidArguments;
    }
}

fn printUsage(exe_name: []const u8) !void {
    var stderr = std.io.getStdErr().writer();
    try stderr.print(
        "Usage: {s} <command> [options]\n\n",
        .{exe_name},
    );
    try stderr.writeAll("Commands:\n");
    try stderr.writeAll("  info <input.ppm>                 Print image dimensions (PPM only).\n");
    try stderr.writeAll("  brighten <input.ppm> <output.ppm> <factor>  Apply brightness scaling.\n");
    try stderr.writeAll("  --help                           Show this message.\n");
}
