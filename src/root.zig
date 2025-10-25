const std = @import("std");
const zlib = @cImport({
    @cInclude("zlib.h");
});

const max_ppm_bytes = 1024 * 1024 * 10; // 10MB
const max_png_bytes = 1024 * 1024 * 64; // 64MB

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
    try writer.writeAll("\x89PNG\r\n\x1a\n");

    const width = image.width;
    const height = image.height;
    var ihdr_data: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr_data[0..4], width, .big);
    std.mem.writeInt(u32, ihdr_data[4..8], height, .big);
    ihdr_data[8] = 8; // bit depth
    ihdr_data[9] = 6; // RGBA
    ihdr_data[10] = 0; // compression method
    ihdr_data[11] = 0; // filter method
    ihdr_data[12] = 0; // interlace method (none)
    const ihdr_type = [_]u8{ 'I', 'H', 'D', 'R' };
    try writeChunk(writer, &ihdr_type, &ihdr_data);

    const width_usize = std.math.cast(usize, width) orelse return error.DimensionTooLarge;
    const height_usize = std.math.cast(usize, height) orelse return error.DimensionTooLarge;
    const row_stride = try std.math.mul(usize, width_usize, 4);
    const filtered_row_size = row_stride + 1;
    const raw_size = try std.math.mul(usize, filtered_row_size, height_usize);

    var raw_scanlines = std.ArrayList(u8).empty;
    defer raw_scanlines.deinit(image.allocator);
    try raw_scanlines.ensureTotalCapacity(image.allocator, raw_size);

    var y: usize = 0;
    while (y < height_usize) : (y += 1) {
        try raw_scanlines.append(image.allocator, 0); // filter type 0 (None)
        var x: usize = 0;
        while (x < width_usize) : (x += 1) {
            const pixel = image.pixels[y * width_usize + x];
            try raw_scanlines.append(image.allocator, pixel.r);
            try raw_scanlines.append(image.allocator, pixel.g);
            try raw_scanlines.append(image.allocator, pixel.b);
            try raw_scanlines.append(image.allocator, pixel.a);
        }
    }

    const compressed = try zlibCompress(image.allocator, raw_scanlines.items);
    defer image.allocator.free(compressed);
    const idat_type = [_]u8{ 'I', 'D', 'A', 'T' };
    try writeChunk(writer, &idat_type, compressed);

    const iend_type = [_]u8{ 'I', 'E', 'N', 'D' };
    try writeChunk(writer, &iend_type, &[_]u8{});
}

fn zlibCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const bound = zlib.compressBound(@as(zlib.uLong, @intCast(data.len)));
    const bound_usize = std.math.cast(usize, bound) orelse std.math.maxInt(usize);
    const min_capacity = std.math.add(usize, data.len, 64) catch std.math.maxInt(usize);
    var capacity = @max(bound_usize, min_capacity);
    if (capacity == 0) capacity = min_capacity;
    var buffer = try allocator.alloc(u8, capacity);
    errdefer allocator.free(buffer);

    var dest_len: zlib.uLongf = @intCast(capacity);
    const result = zlib.compress2(
        buffer.ptr,
        &dest_len,
        data.ptr,
        @as(zlib.uLong, @intCast(data.len)),
        zlib.Z_BEST_SPEED,
    );

    if (result == zlib.Z_MEM_ERROR) return error.OutOfMemory;
    if (result != zlib.Z_OK) return error.UnsupportedFormat;

    const final_len = @as(usize, @intCast(dest_len));
    if (final_len == buffer.len) return buffer;
    buffer = try allocator.realloc(buffer, final_len);
    return buffer;
}

fn zlibDecompress(allocator: std.mem.Allocator, data: []const u8, expected_size: usize) ![]u8 {
    var capacity: usize = if (expected_size > 0) expected_size else blk: {
        const doubled = std.math.mul(usize, data.len, 2) catch std.math.maxInt(usize);
        break :blk std.math.add(usize, doubled, 64) catch std.math.maxInt(usize);
    };
    if (capacity == 0) capacity = 1;
    var buffer = try allocator.alloc(u8, capacity);
    errdefer allocator.free(buffer);

    while (true) {
        var dest_len: zlib.uLongf = @intCast(capacity);
        const result = zlib.uncompress(
            buffer.ptr,
            &dest_len,
            data.ptr,
            @as(zlib.uLong, @intCast(data.len)),
        );

        if (result == zlib.Z_OK) {
            const final_len = @as(usize, @intCast(dest_len));
            if (final_len == buffer.len) return buffer;
            buffer = try allocator.realloc(buffer, final_len);
            return buffer;
        }

        if (result == zlib.Z_BUF_ERROR) {
            if (capacity > std.math.maxInt(usize) / 2) return error.DimensionTooLarge;
            capacity *= 2;
            buffer = try allocator.realloc(buffer, capacity);
            continue;
        }

        if (result == zlib.Z_MEM_ERROR) return error.OutOfMemory;
        return error.InvalidFormat;
    }
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
    const len_read = try reader.read(&length_bytes);
    if (len_read != length_bytes.len) return error.InvalidFormat;
    const length = std.mem.readInt(u32, &length_bytes, .big);

    var type_bytes: [4]u8 = undefined;
    const type_read = try reader.read(&type_bytes);
    if (type_read != type_bytes.len) return error.InvalidFormat;

    if (length > max_png_bytes) return error.InvalidFormat;

    const data = try allocator.alloc(u8, length);
    errdefer allocator.free(data);
    var filled: usize = 0;
    while (filled < length) {
        const read_bytes = try reader.read(data[filled..]);
        if (read_bytes == 0) return error.InvalidFormat;
        filled += read_bytes;
    }

    var crc_bytes: [4]u8 = undefined;
    const crc_read = try reader.read(&crc_bytes);
    if (crc_read != crc_bytes.len) return error.InvalidFormat;
    const expected_crc = std.mem.readInt(u32, &crc_bytes, .big);

    var crc = std.hash.Crc32.init();
    crc.update(&type_bytes);
    crc.update(data);
    if (crc.final() != expected_crc) return error.InvalidFormat;

    return Chunk{
        .type = type_bytes,
        .data = data,
        .allocator = allocator,
    };
}

fn writeChunk(writer: anytype, chunk_type: *const [4]u8, data: []const u8) !void {
    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_bytes, @intCast(data.len), .big);
    try writer.writeAll(&length_bytes);
    try writer.writeAll(chunk_type);
    try writer.writeAll(data);

    var crc = std.hash.Crc32.init();
    crc.update(chunk_type);
    crc.update(data);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try writer.writeAll(&crc_bytes);
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
    var signature: [8]u8 = undefined;
    const sig_read = try reader.read(&signature);
    if (sig_read != signature.len or !std.mem.eql(u8, &signature, "\x89PNG\r\n\x1a\n")) {
        return error.InvalidFormat;
    }

    var width_opt: ?u32 = null;
    var height_opt: ?u32 = null;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var compression_method: u8 = 0;
    var filter_method: u8 = 0;
    var interlace_method: u8 = 0;

    var idat_data = std.ArrayList(u8).empty;
    defer idat_data.deinit(allocator);

    var seen_iend = false;

    while (!seen_iend) {
        var chunk = try readChunk(allocator, reader);
        defer chunk.deinit();

        if (std.mem.eql(u8, chunk.type[0..], "IHDR")) {
            if (chunk.data.len != 13) return error.InvalidFormat;
            if (width_opt != null or height_opt != null) return error.InvalidFormat;
            width_opt = std.mem.readInt(u32, chunk.data[0..4], .big);
            height_opt = std.mem.readInt(u32, chunk.data[4..8], .big);
            bit_depth = chunk.data[8];
            color_type = chunk.data[9];
            compression_method = chunk.data[10];
            filter_method = chunk.data[11];
            interlace_method = chunk.data[12];
        } else if (std.mem.eql(u8, chunk.type[0..], "IDAT")) {
            try idat_data.appendSlice(allocator, chunk.data);
        } else if (std.mem.eql(u8, chunk.type[0..], "IEND")) {
            seen_iend = true;
        }
    }

    if (!seen_iend or width_opt == null or height_opt == null) return error.InvalidFormat;
    if (bit_depth != 8 or compression_method != 0 or filter_method != 0 or interlace_method != 0) {
        return error.UnsupportedFormat;
    }
    if (idat_data.items.len == 0) return error.InvalidFormat;

    const width = width_opt.?;
    const height = height_opt.?;

    const bytes_per_pixel = switch (color_type) {
        6 => @as(usize, 4), // RGBA
        2 => @as(usize, 3), // RGB
        0 => @as(usize, 1), // Grayscale
        else => return error.UnsupportedFormat,
    };

    const width_usize = std.math.cast(usize, width) orelse return error.DimensionTooLarge;
    const height_usize = std.math.cast(usize, height) orelse return error.DimensionTooLarge;
    const row_bytes = try std.math.mul(usize, width_usize, bytes_per_pixel);
    if (row_bytes >= std.math.maxInt(usize) - 1) return error.DimensionTooLarge;
    const filtered_row_size = row_bytes + 1;
    const expected_raw_size = try std.math.mul(usize, height_usize, filtered_row_size);

    const raw_bytes = try zlibDecompress(allocator, idat_data.items, expected_raw_size);
    defer allocator.free(raw_bytes);

    if (raw_bytes.len != expected_raw_size) return error.InvalidFormat;

    const pixel_count = try std.math.mul(usize, width_usize, height_usize);
    var pixels = try allocator.alloc(Pixel, pixel_count);
    errdefer allocator.free(pixels);

    const prev_row = try allocator.alloc(u8, row_bytes);
    defer allocator.free(prev_row);
    @memset(prev_row, 0);

    const recon_row = try allocator.alloc(u8, row_bytes);
    defer allocator.free(recon_row);

    var raw_index: usize = 0;
    var pixel_index: usize = 0;

    var y: usize = 0;
    while (y < height_usize) : (y += 1) {
        if (raw_index >= raw_bytes.len) return error.InvalidFormat;
        const filter_type = raw_bytes[raw_index];
        raw_index += 1;

        if (raw_index + row_bytes > raw_bytes.len) return error.InvalidFormat;
        const scan = raw_bytes[raw_index .. raw_index + row_bytes];
        raw_index += row_bytes;

        switch (filter_type) {
            0 => std.mem.copyForwards(u8, recon_row, scan),
            1 => {
                var i: usize = 0;
                while (i < row_bytes) : (i += 1) {
                    const left = if (i >= bytes_per_pixel) recon_row[i - bytes_per_pixel] else 0;
                    const sum = @as(u16, scan[i]) + @as(u16, left);
                    recon_row[i] = @truncate(sum);
                }
            },
            2 => {
                var i: usize = 0;
                while (i < row_bytes) : (i += 1) {
                    const up = prev_row[i];
                    const sum = @as(u16, scan[i]) + @as(u16, up);
                    recon_row[i] = @truncate(sum);
                }
            },
            3 => {
                var i: usize = 0;
                while (i < row_bytes) : (i += 1) {
                    const left = if (i >= bytes_per_pixel) recon_row[i - bytes_per_pixel] else 0;
                    const up = prev_row[i];
                    const avg = (@as(u16, left) + @as(u16, up)) / 2;
                    const sum = @as(u16, scan[i]) + avg;
                    recon_row[i] = @truncate(sum);
                }
            },
            4 => {
                var i: usize = 0;
                while (i < row_bytes) : (i += 1) {
                    const left = if (i >= bytes_per_pixel) recon_row[i - bytes_per_pixel] else 0;
                    const up = prev_row[i];
                    const up_left = if (i >= bytes_per_pixel) prev_row[i - bytes_per_pixel] else 0;
                    const predictor = paethPredictor(left, up, up_left);
                    const sum = @as(u16, scan[i]) + @as(u16, predictor);
                    recon_row[i] = @truncate(sum);
                }
            },
            else => return error.UnsupportedFormat,
        }

        var x: usize = 0;
        while (x < width_usize) : (x += 1) {
            const base = x * bytes_per_pixel;
            const pixel = switch (color_type) {
                6 => Pixel{
                    .r = recon_row[base],
                    .g = recon_row[base + 1],
                    .b = recon_row[base + 2],
                    .a = recon_row[base + 3],
                },
                2 => Pixel{
                    .r = recon_row[base],
                    .g = recon_row[base + 1],
                    .b = recon_row[base + 2],
                    .a = 255,
                },
                else => Pixel{
                    .r = recon_row[base],
                    .g = recon_row[base],
                    .b = recon_row[base],
                    .a = 255,
                },
            };
            pixels[pixel_index] = pixel;
            pixel_index += 1;
        }

        std.mem.copyForwards(u8, prev_row, recon_row);
    }

    if (raw_index != raw_bytes.len) return error.InvalidFormat;

    return .{
        .allocator = allocator,
        .width = width,
        .height = height,
        .pixels = pixels,
    };
}

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
    const ia = @as(i32, @intCast(a));
    const ib = @as(i32, @intCast(b));
    const ic = @as(i32, @intCast(c));
    const p = ia + ib - ic;
    const pa = absInt(p - ia);
    const pb = absInt(p - ib);
    const pc = absInt(p - ic);

    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn absInt(value: i32) i32 {
    return if (value < 0) -value else value;
}

test "png round trip" {
    const allocator = std.testing.allocator;
    var image = try Image.init(allocator, 2, 2);
    defer image.deinit();

    image.pixels[0] = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    image.pixels[1] = .{ .r = 0, .g = 255, .b = 0, .a = 255 };
    image.pixels[2] = .{ .r = 0, .g = 0, .b = 255, .a = 255 };
    image.pixels[3] = .{ .r = 255, .g = 255, .b = 0, .a = 255 };

    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(allocator);

    const Writer = struct {
        list: *std.ArrayList(u8),
        allocator: std.mem.Allocator,

        pub fn writeAll(self: *@This(), data: []const u8) !void {
            try self.list.appendSlice(self.allocator, data);
        }
    };

    var writer = Writer{ .list = &buffer, .allocator = allocator };
    try writePNG(&image, &writer);

    var decoded = try Image.readPNGSlice(allocator, buffer.items);
    defer decoded.deinit();

    try std.testing.expectEqual(image.width, decoded.width);
    try std.testing.expectEqual(image.height, decoded.height);
    try std.testing.expectEqual(@as(usize, image.pixels.len), decoded.pixels.len);

    for (decoded.pixels, 0..) |pixel, idx| {
        try std.testing.expectEqual(image.pixels[idx], pixel);
    }
}
