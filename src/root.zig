const std = @import("std");
// const zpack = @import("zpack");
const zfont = @import("zfont");
const flash = @import("flash");
const phantom = @import("phantom");

const max_ppm_bytes = 1024 * 1024 * 10; // 10MB

pub const Pixel = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,
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

    pub fn applyContrast(self: *Image, factor: f32) void {
        for (self.pixels) |*pixel| {
            pixel.r = contrastChannel(pixel.r, factor);
            pixel.g = contrastChannel(pixel.g, factor);
            pixel.b = contrastChannel(pixel.b, factor);
        }
    }

    pub fn applyBlur(self: *Image) !void {
        // Simple 3x3 box blur
        const temp_pixels = try self.allocator.alloc(Pixel, self.pixels.len);
        defer self.allocator.free(temp_pixels);
        std.mem.copyForwards(Pixel, temp_pixels, self.pixels);

        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                var sum_r: u32 = 0;
                var sum_g: u32 = 0;
                var sum_b: u32 = 0;
                var count: u32 = 0;

                var dy: i32 = -1;
                while (dy <= 1) : (dy += 1) {
                    var dx: i32 = -1;
                    while (dx <= 1) : (dx += 1) {
                        const nx = @as(i32, @intCast(x)) + dx;
                        const ny = @as(i32, @intCast(y)) + dy;
                        if (nx >= 0 and nx < self.width and ny >= 0 and ny < self.height) {
                            const idx = (@as(usize, @intCast(ny)) * @as(usize, @intCast(self.width))) + @as(usize, @intCast(nx));
                            const pixel = temp_pixels[@intCast(idx)];
                            sum_r += pixel.r;
                            sum_g += pixel.g;
                            sum_b += pixel.b;
                            count += 1;
                        }
                    }
                }

                const avg_r = sum_r / count;
                const avg_g = sum_g / count;
                const avg_b = sum_b / count;
                const idx = (y * self.width) + x;
                self.pixels[@intCast(idx)] = Pixel{ .r = @intCast(avg_r), .g = @intCast(avg_g), .b = @intCast(avg_b), .a = 255 };
            }
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

            pub fn writeInt(writer: *@This(), value: anytype, endian: std.builtin.Endian) !void {
                var bytes: [@sizeOf(@TypeOf(value))]u8 = undefined;
                std.mem.writeInt(@TypeOf(value), &bytes, value, endian);
                try writer.file.writeAll(&bytes);
            }

            pub fn writeByte(writer: *@This(), byte: u8) !void {
                try writer.file.writeAll(&[_]u8{byte});
            }
        };

        var writer = FileWriter{ .file = &file };
        try self.writePPM(&writer);
    }

    pub fn loadPPMFile(allocator: std.mem.Allocator, path: []const u8) !Image {
        const data = try std.fs.cwd().readFileAlloc(path, allocator, @enumFromInt(max_ppm_bytes));
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

    pub fn loadBMPFile(allocator: std.mem.Allocator, path: []const u8) !Image {
        const data = try std.fs.cwd().readFileAlloc(path, allocator, @enumFromInt(max_ppm_bytes));
        defer allocator.free(data);

        return readBMPSlice(allocator, data);
    }

    pub fn writeBMPFile(self: *const Image, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        const FileWriter = struct {
            file: *std.fs.File,

            pub fn writeAll(writer: *@This(), data: []const u8) !void {
                try writer.file.writeAll(data);
            }

            pub fn writeInt(writer: *@This(), value: anytype, endian: std.builtin.Endian) !void {
                var bytes: [@sizeOf(@TypeOf(value))]u8 = undefined;
                std.mem.writeInt(@TypeOf(value), &bytes, value, endian);
                try writer.file.writeAll(&bytes);
            }

            pub fn writeByte(writer: *@This(), byte: u8) !void {
                try writer.file.writeAll(&[_]u8{byte});
            }
        };

        var writer = FileWriter{ .file = &file };
        try writeBMP(self, &writer);
    }

    pub fn loadPNGFile(allocator: std.mem.Allocator, path: []const u8) !Image {
        const data = try std.fs.cwd().readFileAlloc(path, allocator, @enumFromInt(max_ppm_bytes));
        defer allocator.free(data);

        return readPNGSlice(allocator, data);
    }

    pub fn writePNGFile(self: *const Image, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        const FileWriter = struct {
            file: *std.fs.File,

            pub fn writeAll(writer: *@This(), data: []const u8) !void {
                try writer.file.writeAll(data);
            }

            pub fn writeInt(writer: *@This(), value: anytype, endian: std.builtin.Endian) !void {
                var bytes: [@sizeOf(@TypeOf(value))]u8 = undefined;
                std.mem.writeInt(@TypeOf(value), &bytes, value, endian);
                try writer.file.writeAll(&bytes);
            }

            pub fn writeByte(writer: *@This(), byte: u8) !void {
                try writer.file.writeAll(&[_]u8{byte});
            }
        };

        var writer = FileWriter{ .file = &file };
        try writePNG(self, &writer);
    }

    pub fn loadJPEGFile(allocator: std.mem.Allocator, path: []const u8) !Image {
        const data = try std.fs.cwd().readFileAlloc(path, allocator, @enumFromInt(max_ppm_bytes));
        defer allocator.free(data);

        return readJPEGSlice(allocator, data);
    }

    pub fn writeJPEGFile(image: *const Image, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        var buffer: [4096]u8 = undefined;
        const writer = file.writer(&buffer);
        return writeJPEG(image, writer);
    }

    pub fn readPPMSlice(allocator: std.mem.Allocator, data: []const u8) !Image {
        var reader = SliceReader{ .data = data };
        return parsePPM(allocator, &reader);
    }

    pub fn readBMPSlice(allocator: std.mem.Allocator, data: []const u8) !Image {
        var reader = SliceReader{ .data = data };
        return parseBMP(allocator, &reader);
    }

    pub fn readPNGSlice(allocator: std.mem.Allocator, data: []const u8) !Image {
        var reader = SliceReader{ .data = data };
        return parsePNG(allocator, &reader);
    }

    pub fn readJPEGSlice(allocator: std.mem.Allocator, data: []const u8) !Image {
        var reader = SliceReader{ .data = data };
        return parseJPEG(allocator, &reader);
    }
};

pub fn composite(image: *Image, other: *const Image, x: i32, y: i32) void {
    var dy: u32 = 0;
    while (dy < other.height) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < other.width) : (dx += 1) {
            const sx = @as(i32, x) + @as(i32, @intCast(dx));
            const sy = @as(i32, y) + @as(i32, @intCast(dy));
            if (sx >= 0) {
                const usx = @as(u32, @intCast(sx));
                if (usx < image.width and sy >= 0) {
                    const usy = @as(u32, @intCast(sy));
                    if (usy < image.height) {
                        const pixel = other.pixels[dy * other.width + dx];
                        // Simple alpha blend
                        const bg = image.pixels[usy * image.width + usx];
                        const a = @as(f32, @floatFromInt(pixel.a)) / 255.0;
                        const r = @as(u8, @intFromFloat(@as(f32, @floatFromInt(bg.r)) * (1 - a) + @as(f32, @floatFromInt(pixel.r)) * a));
                        const g = @as(u8, @intFromFloat(@as(f32, @floatFromInt(bg.g)) * (1 - a) + @as(f32, @floatFromInt(pixel.g)) * a));
                        const b = @as(u8, @intFromFloat(@as(f32, @floatFromInt(bg.b)) * (1 - a) + @as(f32, @floatFromInt(pixel.b)) * a));
                        image.pixels[usy * image.width + usx] = .{ .r = r, .g = g, .b = b, .a = 255 };
                    }
                }
            }
        }
    }
}

pub fn loadImage(allocator: std.mem.Allocator, path: []const u8) !Image {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".ppm")) {
        return Image.loadPPMFile(allocator, path);
    } else if (std.mem.eql(u8, ext, ".bmp")) {
        return Image.loadBMPFile(allocator, path);
    } else if (std.mem.eql(u8, ext, ".png")) {
        return Image.loadPNGFile(allocator, path);
    } else if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) {
        return Image.loadJPEGFile(allocator, path);
    } else {
        return error.UnsupportedFormat;
    }
}

pub fn saveImage(image: *const Image, path: []const u8) !void {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".ppm")) {
        return image.writePPMFile(path);
    } else if (std.mem.eql(u8, ext, ".bmp")) {
        return image.writeBMPFile(path);
    } else if (std.mem.eql(u8, ext, ".png")) {
        return image.writePNGFile(path);
    } else if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) {
        return image.writeJPEGFile(path);
    } else {
        return error.UnsupportedFormat;
    }
}

fn scaleChannel(value: u8, factor: f32) u8 {
    const scaled = @as(f32, @floatFromInt(value)) * factor;
    const clamped = std.math.clamp(scaled, 0.0, 255.0);
    return @as(u8, @intFromFloat(clamped + 0.5));
}

fn contrastChannel(value: u8, factor: f32) u8 {
    const normalized = @as(f32, @floatFromInt(value)) / 255.0;
    const adjusted = (normalized - 0.5) * factor + 0.5;
    const clamped = std.math.clamp(adjusted, 0.0, 1.0);
    return @as(u8, @intFromFloat(clamped * 255.0 + 0.5));
}

const SliceReader = struct {
    data: []const u8,
    pos: usize = 0,

    pub fn readByte(self: *@This()) !u8 {
        if (self.pos >= self.data.len) return error.EndOfStream;
        const byte = self.data[self.pos];
        self.pos += 1;
        return byte;
    }

    pub fn read(self: *@This(), buffer: []u8) !usize {
        const available = self.data.len - self.pos;
        const to_read = @min(buffer.len, available);
        @memcpy(buffer[0..to_read], self.data[self.pos..self.pos + to_read]);
        self.pos += to_read;
        return to_read;
    }

    pub fn readExact(self: *@This(), buffer: []u8) !void {
        const read_count = try self.read(buffer);
        if (read_count != buffer.len) return error.EndOfStream;
    }
};

fn readLE32(reader: *SliceReader) !u32 {
    const b1 = try reader.readByte();
    const b2 = try reader.readByte();
    const b3 = try reader.readByte();
    const b4 = try reader.readByte();
    return @as(u32, b1) |
           (@as(u32, b2) << 8) |
           (@as(u32, b3) << 16) |
           (@as(u32, b4) << 24);
}

pub fn writeBMP(image: *const Image, writer: anytype) !void {
    // BMP file header (14 bytes)
    try writer.writeAll("BM"); // signature
    const row_size = image.width * 3;
    const padding = (4 - (row_size % 4)) % 4;
    const padded_row_size = row_size + padding;
    const data_size = padded_row_size * image.height;
    const file_size = 14 + 40 + data_size; // headers + pixel data
    try writer.writeInt(@as(u32, file_size), .little);
    try writer.writeInt(@as(u32, 0), .little); // reserved
    try writer.writeInt(@as(u32, 54), .little); // data offset

    // DIB header (BITMAPINFOHEADER, 40 bytes)
    try writer.writeInt(@as(u32, 40), .little); // header size
    try writer.writeInt(@as(i32, @intCast(image.width)), .little);
    try writer.writeInt(@as(i32, @intCast(image.height)), .little); // positive for bottom-up
    try writer.writeInt(@as(u16, 1), .little); // planes
    try writer.writeInt(@as(u16, 24), .little); // bpp
    try writer.writeInt(@as(u32, 0), .little); // compression
    try writer.writeInt(@as(u32, data_size), .little); // image size
    try writer.writeInt(@as(u32, 2835), .little); // x pixels per meter (72 DPI)
    try writer.writeInt(@as(u32, 2835), .little); // y pixels per meter (72 DPI)
    try writer.writeInt(@as(u32, 0), .little); // colors used
    try writer.writeInt(@as(u32, 0), .little); // important colors

    // Pixel data (BGR, bottom-up)
    var y: i32 = @intCast(image.height - 1);
    while (y >= 0) : (y -= 1) {
        const row_start = @as(usize, @intCast(y)) * @as(usize, @intCast(image.width));
        var x: usize = 0;
        while (x < image.width) : (x += 1) {
            const pixel = image.pixels[row_start + x];
            try writer.writeByte(pixel.b);
            try writer.writeByte(pixel.g);
            try writer.writeByte(pixel.r);
        }
        // Padding
        var p: usize = 0;
        while (p < padding) : (p += 1) {
            try writer.writeByte(0);
        }
    }
}

pub fn writePNG(image: *const Image, writer: anytype) !void {
    _ = image;
    _ = writer;
    return error.UnsupportedFormat;
}

pub fn parseJPEG(allocator: std.mem.Allocator, reader: anytype) !Image {
    _ = allocator;
    _ = reader;
    return error.UnsupportedFormat;
}

pub fn writeJPEG(image: *const Image, writer: anytype) !void {
    _ = image;
    _ = writer;
    return error.UnsupportedFormat;
}

const Chunk = struct {
    type: [4]u8,
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Chunk) void {
        self.allocator.free(self.data);
        self.* = undefined;
    }
};

fn readChunk(allocator: std.mem.Allocator, reader: anytype) !Chunk {
    var length_bytes: [4]u8 = undefined;
    _ = try reader.read(&length_bytes);
    const length = std.mem.readInt(u32, &length_bytes, .big);

    var type_bytes: [4]u8 = undefined;
    _ = try reader.read(&type_bytes);

    const data = try allocator.alloc(u8, length);
    errdefer allocator.free(data);
    _ = try reader.read(data);

    var crc_bytes: [4]u8 = undefined;
    _ = try reader.read(&crc_bytes);
    // CRC check ignored for now

    return Chunk{
        .type = type_bytes,
        .data = data,
        .allocator = allocator,
    };
}

fn parsePPM(allocator: std.mem.Allocator, reader: *SliceReader) !Image {
    // Skip P6
    if (try reader.readByte() != 'P' or try reader.readByte() != '6') return error.InvalidData;
    _ = try reader.readByte(); // space

    // Read width
    var width: u32 = 0;
    while (true) {
        const byte = try reader.readByte();
        if (byte == ' ') break;
        width = width * 10 + (byte - '0');
    }

    // Read height
    var height: u32 = 0;
    while (true) {
        const byte = try reader.readByte();
        if (byte == '\n') break;
        height = height * 10 + (byte - '0');
    }

    // Skip 255\n
    while (try reader.readByte() != '\n') {}

    const width_usize = std.math.cast(usize, width) orelse return error.DimensionTooLarge;
    const height_usize = std.math.cast(usize, height) orelse return error.DimensionTooLarge;
    const pixel_count = try std.math.mul(usize, width_usize, height_usize);
    var pixels = try allocator.alloc(Pixel, pixel_count);
    errdefer allocator.free(pixels);

    var i: usize = 0;
    while (i < pixel_count) : (i += 1) {
        const r = try reader.readByte();
        const g = try reader.readByte();
        const b = try reader.readByte();
        pixels[i] = .{ .r = r, .g = g, .b = b, .a = 255 };
    }

    return .{
        .allocator = allocator,
        .width = width,
        .height = height,
        .pixels = pixels,
    };
}

fn parseBMP(allocator: std.mem.Allocator, reader: *SliceReader) !Image {
    // Read BMP file header
    var signature: [2]u8 = undefined;
    try reader.readExact(&signature);
    if (!std.mem.eql(u8, &signature, "BM")) return error.InvalidData;

    _ = try readLE32(reader); // file_size
    _ = try readLE32(reader); // reserved
    _ = try readLE32(reader); // data_offset

    // Read DIB header
    const dib_size = try readLE32(reader);
    if (dib_size != 40) return error.UnsupportedFormat; // Only support BITMAPINFOHEADER

    const width_i32 = try readLE32(reader);
    const height_i32 = try readLE32(reader);
    const width = std.math.cast(u32, width_i32) orelse return error.DimensionTooLarge;
    const height_abs = std.math.cast(u32, if (height_i32 < 0) -height_i32 else height_i32) orelse return error.DimensionTooLarge;

    const planes = try reader.readByte() | (@as(u16, try reader.readByte()) << 8);
    if (planes != 1) return error.UnsupportedFormat;

    const bpp = try reader.readByte() | (@as(u16, try reader.readByte()) << 8);
    if (bpp != 24) return error.UnsupportedFormat; // Only support 24-bit BMP

    const compression = try readLE32(reader);
    if (compression != 0) return error.UnsupportedFormat; // No compression

    // Skip image size, x/y pixels per meter, colors used, important colors
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        _ = try reader.readByte();
    }

    const width_usize = std.math.cast(usize, width) orelse return error.DimensionTooLarge;
    const height_usize = std.math.cast(usize, height_abs) orelse return error.DimensionTooLarge;
    const pixel_count = width_usize * height_usize;
    var pixels = try allocator.alloc(Pixel, pixel_count);
    errdefer allocator.free(pixels);

    // Read pixel data (BGR format, bottom-up if height positive)
    const bottom_up = height_i32 > 0;
    var y: i32 = if (bottom_up) @as(i32, @intCast(height_abs)) - 1 else 0;
    const y_step: i32 = if (bottom_up) -1 else 1;
    const y_end = if (bottom_up) -1 else @as(i32, @intCast(height_abs));

    while (y != y_end) {
        const row_index = if (bottom_up) @as(u32, @intCast(y)) else height_abs - 1 - @as(u32, @intCast(y));
        const row_start = @as(usize, row_index) * width_usize;
        var x: usize = 0;
        while (x < width_usize) : (x += 1) {
            const b = try reader.readByte();
            const g = try reader.readByte();
            const r = try reader.readByte();
            pixels[row_start + x] = .{ .r = r, .g = g, .b = b, .a = 255 };
        }
        // Skip padding
        const row_size = width_usize * 3;
        const padding = (4 - (row_size % 4)) % 4;
        var p: usize = 0;
        while (p < padding) : (p += 1) {
            _ = try reader.readByte();
        }
        y += y_step;
    }

    return .{
        .allocator = allocator,
        .width = width,
        .height = height_abs,
        .pixels = pixels,
    };
}

fn parsePNG(allocator: std.mem.Allocator, reader: anytype) !Image {
    _ = allocator;
    _ = reader;
    return error.UnsupportedFormat;
}
