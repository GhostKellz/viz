const std = @import("std");

const max_ppm_bytes = 256 * 1024 * 1024; // 256 MiB safeguard for prototype loader.

pub const Pixel = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8 = 255,

    pub fn fromRGBA(r: u8, g: u8, b: u8, a: u8) Pixel {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
};

pub const Image = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    pixels: []Pixel,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !Image {
        if (width == 0 or height == 0) return error.EmptyImage;
        const width_usize = std.math.cast(usize, width) orelse return error.DimensionTooLarge;
        const height_usize = std.math.cast(usize, height) orelse return error.DimensionTooLarge;
        const pixel_count = try std.math.mul(usize, width_usize, height_usize);
        const pixels = try allocator.alloc(Pixel, pixel_count);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *Image) void {
        if (self.pixels.len != 0) {
            self.allocator.free(self.pixels);
        }
        self.* = undefined;
    }

    pub fn fill(self: *Image, color: Pixel) void {
        for (self.pixels) |*pixel| {
            pixel.* = color;
        }
    }

    pub fn setPixel(self: *Image, x: u32, y: u32, pixel: Pixel) !void {
        const idx = try self.indexOf(x, y);
        self.pixels[idx] = pixel;
    }

    pub fn getPixel(self: *const Image, x: u32, y: u32) !Pixel {
        const idx = try self.indexOf(x, y);
        return self.pixels[idx];
    }

    fn indexOf(self: *const Image, x: u32, y: u32) !usize {
        if (x >= self.width or y >= self.height) return error.OutOfBounds;
        const width_usize = std.math.cast(usize, self.width) orelse return error.DimensionTooLarge;
        const row_offset = try std.math.mul(usize, std.math.cast(usize, y) orelse return error.DimensionTooLarge, width_usize);
        return row_offset + (std.math.cast(usize, x) orelse return error.DimensionTooLarge);
    }

    pub fn applyBrightness(self: *Image, factor: f32) void {
        for (self.pixels) |*pixel| {
            pixel.r = scaleChannel(pixel.r, factor);
            pixel.g = scaleChannel(pixel.g, factor);
            pixel.b = scaleChannel(pixel.b, factor);
        }
    }

    pub fn writePPMFile(self: *const Image, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        const FileWriter = struct {
            file: *std.fs.File,

            pub fn writeAll(writer: *@This(), data: []const u8) !void {
                try writer.file.writeAll(data);
            }
        };

        var writer = FileWriter{ .file = &file };
        try self.writePPM(&writer);
    }

    pub fn loadPPMFile(allocator: std.mem.Allocator, path: []const u8) !Image {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const data = try file.readToEndAlloc(allocator, max_ppm_bytes);
        defer allocator.free(data);

        return readPPMSlice(allocator, data);
    }

    pub fn writePPM(self: *const Image, writer: anytype) !void {
        var header_buffer: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buffer, "P6\n{d} {d}\n255\n", .{ self.width, self.height });
        try writer.writeAll(header);
        for (self.pixels) |pixel| {
            try writer.writeAll(&[_]u8{ pixel.r, pixel.g, pixel.b });
        }
    }

    pub fn readPPMSlice(allocator: std.mem.Allocator, data: []const u8) !Image {
        var reader = SliceReader{ .data = data };
        return parsePPM(allocator, &reader);
    }
};

fn scaleChannel(value: u8, factor: f32) u8 {
    const scaled = @as(f32, @floatFromInt(value)) * factor;
    const clamped = std.math.clamp(scaled, 0.0, 255.0);
    return @as(u8, @intFromFloat(clamped + 0.5));
}

const SliceReader = struct {
    data: []const u8,
    pos: usize = 0,

    fn readByte(self: *@This()) !u8 {
        if (self.pos >= self.data.len) return error.EndOfStream;
        const byte = self.data[self.pos];
        self.pos += 1;
        return byte;
    }

    fn readExact(self: *@This(), dest: []u8) !void {
        if (dest.len == 0) return;
        if (self.data.len - self.pos < dest.len) return error.EndOfStream;
        std.mem.copyForwards(u8, dest, self.data[self.pos .. self.pos + dest.len]);
        self.pos += dest.len;
    }
};

const TokenBuffer = struct {
    data: [64]u8 = undefined,
    len: usize = 0,

    fn reset(self: *@This()) void {
        self.len = 0;
    }

    fn append(self: *@This(), byte: u8) !void {
        if (self.len >= self.data.len) return error.TokenTooLong;
        self.data[self.len] = byte;
        self.len += 1;
    }

    fn slice(self: *@This()) []const u8 {
        return self.data[0..self.len];
    }
};

fn parsePPM(allocator: std.mem.Allocator, reader: *SliceReader) !Image {
    var token_buf = TokenBuffer{};

    const magic = try nextToken(reader, &token_buf);
    if (!std.mem.eql(u8, magic, "P6")) return error.UnsupportedFormat;

    const width_token = try nextToken(reader, &token_buf);
    const width = try std.fmt.parseInt(u32, width_token, 10);

    const height_token = try nextToken(reader, &token_buf);
    const height = try std.fmt.parseInt(u32, height_token, 10);

    const max_token = try nextToken(reader, &token_buf);
    const max_color = try std.fmt.parseInt(u32, max_token, 10);
    if (max_color != 255) return error.UnsupportedMaxValue;

    const width_usize = std.math.cast(usize, width) orelse return error.DimensionTooLarge;
    const height_usize = std.math.cast(usize, height) orelse return error.DimensionTooLarge;
    const pixel_count = try std.math.mul(usize, width_usize, height_usize);
    var pixels = try allocator.alloc(Pixel, pixel_count);
    errdefer allocator.free(pixels);

    var index: usize = 0;
    while (index < pixel_count) : (index += 1) {
        var rgb: [3]u8 = undefined;
        try reader.readExact(&rgb);
        pixels[index] = .{ .r = rgb[0], .g = rgb[1], .b = rgb[2], .a = 255 };
    }

    return .{
        .allocator = allocator,
        .width = width,
        .height = height,
        .pixels = pixels,
    };
}

fn nextToken(reader: *SliceReader, buf: *TokenBuffer) ![]const u8 {
    buf.reset();

    while (true) {
        const byte = reader.readByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (buf.len != 0) {
                    return buf.slice();
                }
                return error.UnexpectedEof;
            },
            else => return err,
        };

        switch (byte) {
            ' ', '\n', '\r', '\t' => {
                if (buf.len != 0) return buf.slice();
                continue;
            },
            '#' => {
                while (true) {
                    const comment_byte = reader.readByte() catch |err| switch (err) {
                        error.EndOfStream => break,
                        else => return err,
                    };
                    if (comment_byte == '\n') break;
                }
                if (buf.len != 0) return buf.slice();
            },
            else => try buf.append(byte),
        }
    }
}

test "Image init and fill" {
    const allocator = std.testing.allocator;
    var image = try Image.init(allocator, 2, 2);
    defer image.deinit();

    const color = Pixel{ .r = 10, .g = 20, .b = 30, .a = 255 };
    image.fill(color);

    try std.testing.expectEqual(color, try image.getPixel(0, 0));
    try std.testing.expectEqual(color, try image.getPixel(1, 1));
}

test "Image brightness adjustment" {
    const allocator = std.testing.allocator;
    var image = try Image.init(allocator, 1, 1);
    defer image.deinit();

    try image.setPixel(0, 0, Pixel{ .r = 100, .g = 120, .b = 140, .a = 200 });
    image.applyBrightness(1.5);

    const pixel = try image.getPixel(0, 0);
    try std.testing.expect(pixel.r == 150);
    try std.testing.expect(pixel.g == 180);
    try std.testing.expect(pixel.b == 210);
    try std.testing.expect(pixel.a == 200);
}

test "PPM roundtrip" {
    const allocator = std.testing.allocator;
    var image = try Image.init(allocator, 2, 2);
    defer image.deinit();

    try image.setPixel(0, 0, Pixel{ .r = 255, .g = 0, .b = 0, .a = 255 });
    try image.setPixel(1, 0, Pixel{ .r = 0, .g = 255, .b = 0, .a = 255 });
    try image.setPixel(0, 1, Pixel{ .r = 0, .g = 0, .b = 255, .a = 255 });
    try image.setPixel(1, 1, Pixel{ .r = 255, .g = 255, .b = 255, .a = 255 });

    const BufferWriter = struct {
        buffer: []u8,
        pos: usize = 0,

        pub fn writeAll(self: *@This(), data: []const u8) error{NoSpaceLeft}!void {
            if (data.len > self.buffer.len - self.pos) return error.NoSpaceLeft;
            std.mem.copyForwards(u8, self.buffer[self.pos .. self.pos + data.len], data);
            self.pos += data.len;
        }

        pub fn written(self: *const @This()) []const u8 {
            return self.buffer[0..self.pos];
        }
    };

    var storage: [512]u8 = undefined;
    var buffer_writer = BufferWriter{ .buffer = &storage };
    try image.writePPM(&buffer_writer);

    var decoded = try Image.readPPMSlice(allocator, buffer_writer.written());
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u32, 2), decoded.width);
    try std.testing.expectEqual(@as(u32, 2), decoded.height);
    try std.testing.expectEqual(try image.getPixel(0, 0), try decoded.getPixel(0, 0));
    try std.testing.expectEqual(try image.getPixel(1, 1), try decoded.getPixel(1, 1));
}

test "pixel bounds checking" {
    const allocator = std.testing.allocator;
    var image = try Image.init(allocator, 2, 2);
    defer image.deinit();

    try std.testing.expectError(error.OutOfBounds, image.getPixel(2, 0));
    try std.testing.expectError(error.OutOfBounds, image.setPixel(0, 3, Pixel{ .r = 0, .g = 0, .b = 0, .a = 255 }));
}
