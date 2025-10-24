const std = @import("std");
const flash = @import("flash");
const viz = @import("viz");
const zfont = @import("zfont");

const VizCLI = flash.CLI(.{
    .name = "viz",
    .version = "0.1.0",
    .about = "VIZ - Image processing toolkit",
});

const info_cmd = flash.cmd("info", (flash.CommandConfig{})
    .withAbout("Print image dimensions")
    .withArgs(&.{
        flash.arg("input", (flash.ArgumentConfig{})
            .withHelp("Input image file (PPM format)")
            .setRequired()),
    })
    .withHandler(infoCommand));

const brighten_cmd = flash.cmd("brighten", (flash.CommandConfig{})
    .withAbout("Apply brightness scaling to an image")
    .withArgs(&.{
        flash.arg("input", (flash.ArgumentConfig{})
            .withHelp("Input image file (PPM format)")
            .setRequired()),
        flash.arg("output", (flash.ArgumentConfig{})
            .withHelp("Output image file (PPM format)")
            .setRequired()),
        flash.arg("factor", (flash.ArgumentConfig{})
            .withHelp("Brightness factor (e.g., 1.2 for 20% brighter)")
            .setRequired()),
    })
    .withHandler(brightenCommand));

const contrast_cmd = flash.cmd("contrast", (flash.CommandConfig{})
    .withAbout("Apply contrast adjustment to an image")
    .withArgs(&.{
        flash.arg("input", (flash.ArgumentConfig{})
            .withHelp("Input image file (PPM format)")
            .setRequired()),
        flash.arg("output", (flash.ArgumentConfig{})
            .withHelp("Output image file (PPM format)")
            .setRequired()),
        flash.arg("factor", (flash.ArgumentConfig{})
            .withHelp("Contrast factor (e.g., 1.5 for increased contrast)")
            .setRequired()),
    })
    .withHandler(contrastCommand));

const blur_cmd = flash.cmd("blur", (flash.CommandConfig{})
    .withAbout("Apply box blur to an image")
    .withArgs(&.{
        flash.arg("input", (flash.ArgumentConfig{})
            .withHelp("Input image file (PPM format)")
            .setRequired()),
        flash.arg("output", (flash.ArgumentConfig{})
            .withHelp("Output image file (PPM format)")
            .setRequired()),
    })
    .withHandler(blurCommand));

const bench_cmd = flash.cmd("bench", (flash.CommandConfig{})
    .withAbout("Run performance benchmarks")
    .withArgs(&.{
        flash.arg("size", (flash.ArgumentConfig{})
            .withHelp("Image size for benchmark (default: 100)")
            .withDefault(flash.ArgValue{ .string = "100" })),
    })
    .withHandler(benchCommand));

const generate_cmd = flash.cmd("generate", (flash.CommandConfig{})
    .withAbout("Generate a test image and save as BMP")
    .withArgs(&.{
        flash.arg("output", (flash.ArgumentConfig{})
            .withHelp("Output BMP file")
            .setRequired()),
        flash.arg("width", (flash.ArgumentConfig{})
            .withHelp("Image width (default: 256)")
            .withDefault(flash.ArgValue{ .string = "256" })),
        flash.arg("height", (flash.ArgumentConfig{})
            .withHelp("Image height (default: 256)")
            .withDefault(flash.ArgValue{ .string = "256" })),
    })
    .withHandler(generateCommand));

const bmpinfo_cmd = flash.cmd("bmpinfo", (flash.CommandConfig{})
    .withAbout("Print BMP image dimensions")
    .withArgs(&.{
        flash.arg("input", (flash.ArgumentConfig{})
            .withHelp("Input BMP file")
            .setRequired()),
    })
    .withHandler(bmpinfoCommand));

const text_cmd = flash.cmd("text", (flash.CommandConfig{})
    .withAbout("Add text overlay to an image")
    .withArgs(&.{
        flash.arg("input", (flash.ArgumentConfig{})
            .withHelp("Input image file")
            .setRequired()),
        flash.arg("output", (flash.ArgumentConfig{})
            .withHelp("Output image file")
            .setRequired()),
        flash.arg("text", (flash.ArgumentConfig{})
            .withHelp("Text to overlay")
            .setRequired()),
        flash.arg("font", (flash.ArgumentConfig{})
            .withHelp("Font file path")
            .setRequired()),
        flash.arg("x", (flash.ArgumentConfig{})
            .withHelp("X position (default: 10)")
            .withDefault(flash.ArgValue{ .string = "10" })),
        flash.arg("y", (flash.ArgumentConfig{})
            .withHelp("Y position (default: 10)")
            .withDefault(flash.ArgValue{ .string = "10" })),
    })
    .withHandler(textCommand));

fn infoCommand(ctx: flash.Context) flash.Error!void {
    const allocator = ctx.allocator;
    const input_path = ctx.getString("input").?;

    var image = viz.loadImage(allocator, input_path) catch |err| {
        std.log.err("failed to load image: {}", .{err});
        return flash.Error.IOError;
    };
    defer image.deinit();

    std.debug.print("{s}: {d}x{d}\n", .{ input_path, image.width, image.height });
}

fn brightenCommand(ctx: flash.Context) flash.Error!void {
    const allocator = ctx.allocator;
    const input_path = ctx.getString("input").?;
    const output_path = ctx.getString("output").?;
    const factor_str = ctx.getString("factor").?;

    const factor = std.fmt.parseFloat(f32, factor_str) catch {
        std.log.err("invalid brightness factor: {s}", .{factor_str});
        return flash.Error.InvalidArgument;
    };

    var image = viz.loadImage(allocator, input_path) catch |err| {
        std.log.err("failed to load image: {}", .{err});
        return flash.Error.IOError;
    };
    defer image.deinit();

    image.applyBrightness(factor);

    viz.saveImage(&image, output_path) catch |err| {
        std.log.err("failed to save image: {}", .{err});
        return flash.Error.IOError;
    };
}

fn contrastCommand(ctx: flash.Context) flash.Error!void {
    const allocator = ctx.allocator;
    const input_path = ctx.getString("input").?;
    const output_path = ctx.getString("output").?;
    const factor_str = ctx.getString("factor").?;

    const factor = std.fmt.parseFloat(f32, factor_str) catch {
        std.log.err("invalid contrast factor: {s}", .{factor_str});
        return flash.Error.InvalidArgument;
    };

    var image = viz.Image.loadPPMFile(allocator, input_path) catch |err| {
        std.log.err("failed to load image: {}", .{err});
        return flash.Error.IOError;
    };
    defer image.deinit();

    image.applyContrast(factor);
    image.writePPMFile(output_path) catch |err| {
        std.log.err("failed to write image: {}", .{err});
        return flash.Error.IOError;
    };
}

fn blurCommand(ctx: flash.Context) flash.Error!void {
    const allocator = ctx.allocator;
    const input_path = ctx.getString("input").?;
    const output_path = ctx.getString("output").?;

    var image = viz.Image.loadPPMFile(allocator, input_path) catch |err| {
        std.log.err("failed to load image: {}", .{err});
        return flash.Error.IOError;
    };
    defer image.deinit();

    image.applyBlur() catch |err| {
        std.log.err("blur failed: {}", .{err});
        return flash.Error.IOError;
    };
    image.writePPMFile(output_path) catch |err| {
        std.log.err("failed to write image: {}", .{err});
        return flash.Error.IOError;
    };
}

fn benchCommand(ctx: flash.Context) flash.Error!void {
    const allocator = ctx.allocator;
    const size_str = ctx.getString("size").?;
    const size = std.fmt.parseInt(u32, size_str, 10) catch 100;

    var image = viz.Image.init(allocator, size, size) catch |err| {
        std.log.err("failed to create benchmark image: {}", .{err});
        return flash.Error.IOError;
    };
    defer image.deinit();
    image.fill(viz.Pixel{ .r = 128, .g = 128, .b = 128, .a = 255 });

    const start = std.time.nanoTimestamp();
    image.applyBrightness(1.2);
    const end = std.time.nanoTimestamp();
    const brightness_time = @as(f64, @floatFromInt(end - start)) / 1e9;

    const start2 = std.time.nanoTimestamp();
    image.applyContrast(1.5);
    const end2 = std.time.nanoTimestamp();
    const contrast_time = @as(f64, @floatFromInt(end2 - start2)) / 1e9;

    const start3 = std.time.nanoTimestamp();
    image.applyBlur() catch |err| {
        std.log.err("blur benchmark failed: {}", .{err});
        return flash.Error.IOError;
    };
    const end3 = std.time.nanoTimestamp();
    const blur_time = @as(f64, @floatFromInt(end3 - start3)) / 1e9;

    std.debug.print("Benchmark ({d}x{d} image):\n", .{size, size});
    std.debug.print("  Brightness: {d:.3}s\n", .{brightness_time});
    std.debug.print("  Contrast: {d:.3}s\n", .{contrast_time});
    std.debug.print("  Blur: {d:.3}s\n", .{blur_time});
}

fn generateCommand(ctx: flash.Context) flash.Error!void {
    const allocator = ctx.allocator;
    const output_path = ctx.getString("output").?;
    const width_str = ctx.getString("width").?;
    const height_str = ctx.getString("height").?;

    const width = std.fmt.parseInt(u32, width_str, 10) catch 256;
    const height = std.fmt.parseInt(u32, height_str, 10) catch 256;

    var image = viz.Image.init(allocator, width, height) catch |err| {
        std.log.err("failed to create image: {}", .{err});
        return flash.Error.IOError;
    };
    defer image.deinit();

    // Create a simple gradient
    for (image.pixels, 0..) |*pixel, idx| {
        const x = idx % width;
        const y = idx / width;
        const r = @as(u8, @intCast((x * 255) / width));
        const g = @as(u8, @intCast((y * 255) / height));
        const b = @as(u8, @intCast(128));
        pixel.* = viz.Pixel{ .r = r, .g = g, .b = b, .a = 255 };
    }

    image.writeBMPFile(output_path) catch |err| {
        std.log.err("failed to save BMP: {}", .{err});
        return flash.Error.IOError;
    };

    std.debug.print("Generated {d}x{d} BMP: {s}\n", .{ width, height, output_path });
}

fn bmpinfoCommand(ctx: flash.Context) flash.Error!void {
    const allocator = ctx.allocator;
    const input_path = ctx.getString("input").?;

    var image = viz.Image.loadBMPFile(allocator, input_path) catch |err| {
        std.log.err("failed to load BMP: {}", .{err});
        return flash.Error.IOError;
    };
    defer image.deinit();

    std.debug.print("{s}: {d}x{d}\n", .{ input_path, image.width, image.height });
}

fn textCommand(ctx: flash.Context) flash.Error!void {
    const allocator = ctx.allocator;
    const input_path = ctx.getString("input").?;
    const output_path = ctx.getString("output").?;
    const text = ctx.getString("text").?;
    const font_path = ctx.getString("font").?;
    const x_str = ctx.getString("x").?;
    const y_str = ctx.getString("y").?;

    const x = std.fmt.parseInt(u32, x_str, 10) catch 10;
    const y = std.fmt.parseInt(u32, y_str, 10) catch 10;

    var image = viz.loadImage(allocator, input_path) catch |err| {
        std.log.err("failed to load image: {}", .{err});
        return flash.Error.IOError;
    };
    defer image.deinit();

    const font_data = std.fs.cwd().readFileAlloc(font_path, allocator, @enumFromInt(10 * 1024 * 1024)) catch |err| {
        std.log.err("failed to load font: {}", .{err});
        return flash.Error.IOError;
    };
    defer allocator.free(font_data);

    const font = zfont.Font.init(allocator, font_data) catch |err| {
        std.log.err("failed to init font: {}", .{err});
        return flash.Error.IOError;
    };
    defer font.deinit();

    const rendered = font.renderText(allocator, text, .{}) catch |err| {
        std.log.err("failed to render text: {}", .{err});
        return flash.Error.IOError;
    };
    defer rendered.deinit();

    // Composite the text onto the image
    viz.composite(&image, &rendered, x, y);

    viz.saveImage(&image, output_path) catch |err| {
        std.log.err("failed to save image: {}", .{err});
        return flash.Error.IOError;
    };

    std.debug.print("Added text '{s}' to {s}, saved as {s}\n", .{ text, input_path, output_path });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.warn("GeneralPurposeAllocator detected a leak", .{});
        }
    }
    const allocator = gpa.allocator();

    var cli = VizCLI.init(allocator, (flash.CommandConfig{})
        .withSubcommands(&.{ info_cmd, brighten_cmd, contrast_cmd, blur_cmd, bench_cmd, generate_cmd, bmpinfo_cmd }));

    try cli.run();
}
