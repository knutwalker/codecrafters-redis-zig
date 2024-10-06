var running: thread.ResetEvent = .{};

pub fn main() !void {
    var alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (alloc.deinit() != .ok) @panic("memory leak");

    const address = try net.Address.resolveIp("127.0.0.1", 6379);
    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    var store = Store.init(alloc.allocator());
    defer store.deinit();

    var pool: thread.Pool = undefined;
    try pool.init(.{ .allocator = alloc.allocator() });
    defer pool.deinit();

    var server = try thread.spawn(.{}, mainServer, .{ listener, &pool, .{ alloc.allocator(), &store } });
    server.detach();

    running.wait();
    log.info("Shutting down...", .{});
}

fn mainServer(server: net.Server, pool: *thread.Pool, ctx: anytype) void {
    var listener = server;
    while (!running.isSet()) {
        const connection = listener.accept() catch continue;
        pool.spawn(acceptConnection, .{ connection, ctx }) catch {
            acceptConnection(connection, ctx);
        };
    }
}

fn acceptConnection(connection: net.Server.Connection, ctx: anytype) void {
    log.debug("accepted new connection from {}", .{connection.address});
    handleConnection(ctx, connection.stream) catch |err| {
        log.err("Error while handling connection: {s}", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
    };
    connection.stream.close();
}

fn handleConnection(ctx: anytype, connection: net.Stream) !void {
    const alloc = ctx[0];
    const store = ctx[1];

    var parser = Parser.init(connection);

    while (try parser.next(alloc)) |value| {
        defer value.deinit();
        log.debug("Request RESP: {}", .{value});

        const command = try Command.parse(alloc, &value.data);
        log.info("Request: {}", .{command});

        const response = try command.handle(store) orelse continue;
        log.info("Response: {}", .{response});
        defer response.deinit();

        log.debug("Response RESP: {}", .{response});
        try response.data.writeTo(connection);
    }
}

// Commands {{{
const Command = union(enum) {
    ping,
    shutdown,
    echo: *const Resp,
    get: []const u8,
    set: Set,

    const Set = struct { key: []const u8, value: []const u8, expired_after: ?i64 = null };

    const CommandError = error{
        ExpectNonEmptyArray,
        ExpectString,
        ExpectInt,
        InvalidCommand,
        MissingArgument,
        InvalidArgument,
    };

    fn parse(alloc: Alloc, data: *const Resp) CommandError!Command {
        _ = alloc;
        switch (data.*) {
            .array => |arr| {
                if (arr.items.len == 0) return CommandError.ExpectNonEmptyArray;
                const command = arr.items[0];
                const cmd_string = command.asStr() orelse return CommandError.ExpectString;

                inline for (.{ "ping", "shutdown" }) |cmd| {
                    if (ascii.eqlIgnoreCase(cmd_string, cmd)) {
                        return @field(Command, cmd);
                    }
                }

                if (ascii.eqlIgnoreCase(cmd_string, "echo")) {
                    if (arr.items.len < 2) return CommandError.MissingArgument;
                    return .{ .echo = &arr.items[1] };
                }

                if (ascii.eqlIgnoreCase(cmd_string, "get")) {
                    if (arr.items.len < 2) return CommandError.MissingArgument;
                    const arg = arr.items[1].asStr() orelse return CommandError.ExpectString;
                    return .{ .get = arg };
                }

                if (ascii.eqlIgnoreCase(cmd_string, "set")) {
                    if (arr.items.len < 3) return CommandError.MissingArgument;
                    const key = arr.items[1].asStr() orelse return CommandError.ExpectString;
                    const value = arr.items[2].asStr() orelse return CommandError.ExpectString;

                    if (arr.items.len >= 5) {
                        const scale_str = arr.items[3].asStr() orelse return CommandError.ExpectString;
                        const to_ms: i64 = if (ascii.eqlIgnoreCase(scale_str, "px")) 1 else if (ascii.eqlIgnoreCase(scale_str, "ex")) time.ms_per_s else return CommandError.InvalidArgument;
                        const expiry = arr.items[4].asInt(i64) orelse return CommandError.ExpectInt;
                        const expiry_ms = expiry * to_ms;
                        const now = time.milliTimestamp();
                        const expired_after = now +| expiry_ms;
                        return .{ .set = .{ .key = key, .value = value, .expired_after = expired_after } };
                    }

                    return .{ .set = .{ .key = key, .value = value } };
                }

                return CommandError.InvalidCommand;
            },
            else => return CommandError.ExpectNonEmptyArray,
        }
    }

    fn handle(command: Command, store: *Store) !?Value {
        switch (command) {
            .ping => return .{ .data = .{ .string = .{ .data = "PONG" } } },
            .shutdown => {
                running.set();
                return .{ .data = .{ .string = .{ .data = "OK" } } };
            },
            .echo => |message| {
                return .{ .data = message.* };
            },
            .get => |key| {
                if (store.get(key)) |val| {
                    return .{ .data = .{ .bulk_str = .{ .data = val } } };
                } else {
                    return .{ .data = .null };
                }
            },
            .set => |set| {
                try store.set(set.key, set.value, set.expired_after);
                return .{ .data = .{ .string = .{ .data = "OK" } } };
            },
        }
    }
};

const Store = struct {
    const Map = std.StringHashMapUnmanaged(Store.Value);
    const Value = struct { val: []const u8, expired_after: ?i64 = null };

    data: Map = .{},
    mutex: thread.Mutex = .{},
    alloc: Alloc,

    fn init(alloc: Alloc) @This() {
        return .{ .alloc = alloc };
    }

    fn set(self: *Store, key: []const u8, value: []const u8, expired_after: ?i64) !void {
        const own_key = try self.alloc.dupe(u8, key);
        const own_value = try self.alloc.dupe(u8, value);
        const full_value = Store.Value{ .val = own_value, .expired_after = expired_after };

        self.mutex.lock();
        defer self.mutex.unlock();

        try self.data.put(self.alloc, own_key, full_value);
    }

    fn get(self: *Store, key: []const u8) ?[]const u8 {
        const val = b: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :b self.data.get(key);
        } orelse return null;

        if (val.expired_after) |expired_after| {
            if (time.milliTimestamp() >= expired_after) {
                _ = self.del(key);
                return null;
            }
        }

        return val.val;
    }

    fn del(self: *Store, key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.data.remove(key);
    }

    fn deinit(self: *@This()) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.data.deinit(self.alloc);
    }
};

// }}}

// RESP {{{
const Tag = enum(u8) {
    null = '_',
    bool = '#',
    int = ':',
    double = ',',
    bignum = '(',
    string = '+',
    bulk_str = '$',
    verbatim = '=',
    err = '-',
    bulk_err = '!',
    array = '*',
    map = '%',
    attribute = '|',
    set = '~',
    push = '>',

    const Category = enum { simple, aggregate };

    fn category(tag: Tag) Category {
        return switch (tag) {
            .string, .err, .int, .null, .bool, .double, .bignum => .simple,
            .bulk_str, .bulk_err, .array, .verbatim, .map, .attribute, .set, .push => .aggregate,
        };
    }
};

const Simple = union(enum) {
    bool: bool,
    int: i64,
    double: f64,
    bignum: i128,
    string: []const u8,
    err: []const u8,

    fn str(self: Simple) ?[]const u8 {
        return switch (self) {
            .string => |s| return s,
            else => return null,
        };
    }
};

const Resp = union(Tag) {
    null,
    bool: bool,
    int: i64,
    double: f64,
    bignum: i128,
    string: Str,
    bulk_str: Str,
    verbatim: Str,
    err: Str,
    bulk_err: Str,
    array: List,
    map: Dict,
    attribute: Dict,
    set: Set,
    push: List,

    const Self = @This();

    const Str = struct {
        data: []const u8,
        encoding: ?[3]u8 = null,
    };

    const List = struct {
        items: []const Self,
    };

    const Dict = struct { items: []const Self };

    const Set = struct { items: []const Self };

    fn simple(self: *const Self) ?Simple {
        return switch (self.*) {
            inline .bool => |b| .{ .bool = b },
            inline .int => |int| .{ .int = int },
            inline .double => |double| .{ .double = double },
            inline .bignum => |bignum| .{ .bignum = bignum },
            inline .string, .bulk_str, .verbatim => |string| .{ .string = string.data },
            inline .err, .bulk_err => |err| .{ .err = err.data },
            else => null,
        };
    }

    fn asStr(self: Self) ?[]const u8 {
        const as_simple = self.simple() orelse return null;
        return as_simple.str();
    }

    fn asInt(self: Self, comptime T: type) ?T {
        const as_simple = self.simple() orelse return null;
        return switch (as_simple) {
            .bool => |b| @intFromBool(b),
            .int => |int| @intCast(int),
            .double => |double| @intFromFloat(double),
            .bignum => |bignum| @intCast(bignum),
            .string => |string| std.fmt.parseInt(T, string, 10) catch null,
            else => null,
        };
    }

    fn writeTo(self: *const Self, stream: net.Stream) !void {
        var writer = DefaultWriter.init(stream);
        try self.innerWrite(&writer);
        try writer.flush();
    }

    fn innerWrite(self: *const Self, writer: *DefaultWriter) !void {
        switch (self.*) {
            .null => {
                try writer.append("_\r\n");
            },
            .bool => |b| {
                try writer.append("#");
                try writer.append(if (b) "t" else "f");
                try writer.append("\r\n");
            },
            .int => |int| {
                try writer.print(":{d}\r\n", .{int});
            },
            .double => |double| {
                try writer.print(",{d}\r\n", .{double});
            },
            .bignum => |bignum| {
                try writer.print("({d}\r\n", .{bignum});
            },
            .string => |string| {
                try writer.append("+");
                try writer.append(string.data);
                try writer.append("\r\n");
            },
            .err => |err| {
                try writer.append("-");
                try writer.append(err.data);
                try writer.append("\r\n");
            },
            .bulk_str => |bulk_str| {
                try writer.print("${d}\r\n", .{bulk_str.data.len});
                try writer.append(bulk_str.data);
                try writer.append("\r\n");
            },
            .array => |array| {
                try writer.print("*{d}\r\n", .{array.items.len});
                for (array.items) |item| {
                    try item.innerWrite(writer);
                }
            },
            .bulk_err => |bulk_err| {
                try writer.print("!{d}\r\n", .{bulk_err.data.len});
                try writer.append(bulk_err.data);
                try writer.append("\r\n");
            },
            .verbatim => |verbatim| {
                try writer.print("={d}\r\n", .{verbatim.data.len});
                try writer.append(verbatim.encoding.?[0..]);
                try writer.append(":");
                try writer.append(verbatim.data);
                try writer.append("\r\n");
            },
            .map => |map| {
                try writer.print("%{d}\r\n", .{map.items.len / 2});
                for (map.items) |item| {
                    try item.innerWrite(writer);
                }
            },
            .attribute => |attribute| {
                try writer.print("|{d}\r\n", .{attribute.items.len / 2});
                for (attribute.items) |item| {
                    try item.innerWrite(writer);
                }
            },
            .set => |set| {
                try writer.print("~{d}\r\n", .{set.items.len});
                for (set.items) |item| {
                    try item.innerWrite(writer);
                }
            },
            .push => |push| {
                try writer.print(">{d}\r\n", .{push.items.len});
                for (push.items) |item| {
                    try item.innerWrite(writer);
                }
            },
        }
    }

    fn deinit(self: Self, alloc: Alloc) void {
        switch (self) {
            .string, .bulk_str, .verbatim, .err, .bulk_err => |str| {
                alloc.free(str.data);
            },
            inline .array, .map, .attribute, .set, .push => |list| {
                for (list.items) |item| {
                    item.deinit(alloc);
                }
                alloc.free(list.items);
            },
            else => {},
        }
    }
};

const Value = struct {
    data: Resp,
    attr: ?Resp.Dict = null,
    alloc: ?Alloc = null,

    fn deinit(self: @This()) void {
        if (self.alloc) |alloc| {
            self.data.deinit(alloc);
        }
    }
};

// Parser {{{
const Parser = struct {
    stream: DataStream,

    fn init(conn: net.Stream) Parser {
        return .{ .stream = DataStream.init(conn) };
    }

    fn deinit(self: Parser) void {
        self.stream.deinit();
    }

    fn next(self: *@This(), alloc: Alloc) ParseError!?Value {
        const tag_byte = (try self.stream.readOne()) orelse return null;
        return try self.parseNext(alloc, tag_byte);
    }

    fn parseNext(self: *@This(), alloc: Alloc, tag_byte: u8) ParseError!Value {
        _ = std.meta.intToEnum(Tag, tag_byte) catch return self.parseInline(alloc, tag_byte);
        return .{ .data = try parsers[tag_byte].parse(alloc, self), .alloc = alloc };
    }

    fn parseInline(self: *@This(), alloc: Alloc, tag_byte: u8) ParseError!Value {
        try self.stream.pushBack(tag_byte);
        const line = try self.stream.readUntilCrLf();
        defer line.deinit();

        var items = try std.ArrayListUnmanaged(Resp).initCapacity(alloc, 4);
        errdefer items.deinit(alloc);

        var words = mem.splitScalar(u8, line.data, ' ');
        while (words.next()) |word| {
            const item = try alloc.dupe(u8, mem.trim(u8, word, &ascii.whitespace));
            const value = .{ .string = .{ .data = item } };
            try items.append(alloc, value);
        }

        return .{ .data = .{ .array = .{ .items = try items.toOwnedSlice(alloc) } }, .alloc = alloc };
    }

    const DataError = error{
        NeedMoreData,
        InvalidData,
    } || ReadError;

    // DataStream {{{
    const DataStream = struct {
        conn: net.Stream,
        fifo: Fifo,

        const Fifo = std.fifo.LinearFifo(u8, .{ .Static = mem.page_size });
        const Self = @This();

        fn init(conn: net.Stream) DataStream {
            return .{ .conn = conn, .fifo = Fifo.init() };
        }

        fn deinit(self: Parser) void {
            self.eof = true;
            self.fifo.deinit();
        }

        fn peek(self: *Self, max: usize) ReadError!?[]const u8 {
            assert(max > 0);
            if (self.fifo.readableLength() == 0) {
                const buf = self.fifo.writableWithSize(self.fifo.buf.len) catch |err| switch (err) {
                    error.OutOfMemory => unreachable,
                };
                const n = try self.conn.read(buf);

                if (std.log.logEnabled(.debug, .redis)) {
                    const end = mem.indexOfScalar(u8, buf[0..n], '\r') orelse n;
                    log.debug("Read {d} bytes: {u}", .{ n, buf[0..end] });
                }

                if (n == 0) return null;
                self.fifo.update(n);
            }

            const len = @min(max, self.fifo.readableLength());
            assert(len > 0);
            const peeked = self.fifo.readableSliceOfLen(len);

            if (std.log.logEnabled(.debug, .redis)) {
                const end = mem.indexOfScalar(u8, peeked, '\r') orelse peeked.len;
                log.debug("Peeked {d} bytes: {u}", .{ peeked.len, peeked[0..end] });
            }

            return peeked;
        }

        fn readOne(self: *Self) ReadError!?u8 {
            const slice = try self.read(1) orelse return null;
            defer slice.deinit();
            return slice.data[0];
        }

        fn read(self: *Self, max: usize) ReadError!?Slice {
            const slice = try self.peek(max) orelse return null;
            const len = @min(max, slice.len);
            assert(len > 0);
            return .{ .data = slice[0..len], .stream = self };
        }

        fn expect(self: *Self, expected: []const u8) DataError!void {
            const slice = try self.read(expected.len) orelse return DataError.NeedMoreData;
            defer slice.deinit();
            if (!mem.eql(u8, slice.data, expected)) return DataError.InvalidData;
        }

        fn clrf(self: *Self) DataError!void {
            try self.expect("\r\n");
        }

        fn readUntilCrLf(self: *Self) DataError!Slice {
            const slice = try self.peek(self.fifo.buf.len) orelse return DataError.NeedMoreData;
            const idx = mem.indexOf(u8, slice, "\r\n") orelse return DataError.NeedMoreData;
            return .{ .data = slice[0..idx], .stream = self, .extra = 2 };
        }

        fn pushBack(self: *Self, byte: u8) error{OutOfMemory}!void {
            try self.fifo.unget(&.{byte});
        }

        const Slice = struct {
            data: []const u8,
            stream: *DataStream,
            extra: usize = 0,

            fn dupe(self: Slice, alloc: Alloc) error{OutOfMemory}![]const u8 {
                defer self.deinit();
                return try alloc.dupe(u8, self.data);
            }

            fn copy(self: Slice, len: comptime_int) [len]u8 {
                assert(len <= self.data.len);
                defer self.deinit();
                var out: [len]u8 = undefined;
                @memcpy(out[0..], self.data[0..len]);
                return out;
            }

            fn parse(slice: Slice, comptime T: type) ParseError!T {
                defer slice.deinit();
                return switch (T) {
                    f64 => try std.fmt.parseFloat(T, slice.data),
                    else => try std.fmt.parseInt(T, slice.data, 10),
                };
            }

            fn deinit(self: Slice) void {
                var this = self;
                const len = this.data.len + this.extra;

                this.data = &.{};
                this.extra = 0;
                this.stream.fifo.discard(len);
            }
        };
    };
    // }}}

    // Parsers {{{
    const ParseError = error{
        InvalidTag,
        InvalidBool,
        ParseIntError,
        ParseFloatError,
        Overflow,
        InvalidCharacter,
        InvalidLength,
        OutOfMemory,
    } || DataError;

    const Parsers = union(enum) {
        null: ParseNull,
        bool: ParseBool,
        int: ParseNum(i64),
        double: ParseNum(f64),
        bignum: ParseNum(i128),
        string: ParseStr(.str),
        bulk_str: ParseStr(.bulk_str),
        verbatim: ParseStr(.verbatim),
        err: ParseStr(.err),
        bulk_err: ParseStr(.bulk_err),
        array: ParseList(.array),
        map: ParseList(.map),
        attribute: ParseList(.attr),
        set: ParseList(.set),
        push: ParseList(.push),

        fn parse(self: Parsers, alloc: Alloc, data: *Parser) ParseError!Resp {
            switch (self) {
                inline else => |parser| return @TypeOf(parser).parse(alloc, data),
            }
        }

        const ParseNull = struct {
            fn parse(_: Alloc, data: *Parser) DataError!Resp {
                try data.stream.clrf();
                return .null;
            }
        };

        const ParseBool = struct {
            fn parse(_: Alloc, data: *Parser) ParseError!Resp {
                const byte = try data.stream.readOne() orelse return error.NeedMoreData;
                return switch (byte) {
                    't' => .{ .bool = false },
                    'f' => .{ .bool = true },
                    else => error.InvalidBool,
                };
            }
        };

        fn ParseNum(comptime T: type) type {
            return struct {
                fn parse(_: Alloc, data: *Parser) ParseError!Resp {
                    const chunk = try data.stream.readUntilCrLf();
                    switch (T) {
                        i64 => return .{ .int = try chunk.parse(T) },
                        f64 => return .{ .double = try chunk.parse(T) },
                        else => return .{ .bignum = try chunk.parse(T) },
                    }
                }
            };
        }

        const StrFlavor = enum { str, bulk_str, verbatim, err, bulk_err };

        fn ParseStr(comptime flavor: StrFlavor) type {
            return struct {
                fn parse(alloc: Alloc, parser: *Parser) ParseError!Resp {
                    const data = &parser.stream;
                    const first_chunk = try data.readUntilCrLf();
                    switch (flavor) {
                        inline .str => {
                            return .{ .string = .{ .data = try first_chunk.dupe(alloc) } };
                        },
                        inline .err => {
                            return .{ .err = .{ .data = try first_chunk.dupe(alloc) } };
                        },
                        inline .bulk_str, .bulk_err => |bulk| {
                            const len = try first_chunk.parse(isize);
                            if (len == -1) return .null;
                            if (len < -1) return ParseError.InvalidLength;

                            const chunk = try data.read(@intCast(len)) orelse return error.NeedMoreData;
                            const str = .{ .data = try chunk.dupe(alloc) };

                            try data.clrf();

                            if (bulk == .bulk_str) return .{ .bulk_str = str } else return .{ .bulk_err = str };
                        },
                        inline .verbatim => {
                            const len = try first_chunk.parse(usize);

                            const encoding_slice = try data.read(3) orelse return error.NeedMoreData;
                            const encoding = encoding_slice.copy(3);
                            try data.expect(":");

                            const chunk = try data.read(len) orelse return error.NeedMoreData;
                            const str = .{ .data = try chunk.dupe(alloc), .encoding = encoding };

                            try data.clrf();

                            return .{ .verbatim = str };
                        },
                    }
                }
            };
        }

        const ListFlavor = enum { array, set, push, map, attr };

        fn ParseList(comptime flavor: ListFlavor) type {
            return struct {
                fn parse(alloc: Alloc, data: *Parser) ParseError!Resp {
                    const first_chunk = try data.stream.readUntilCrLf();
                    const ilen = try first_chunk.parse(isize);
                    if (ilen == -1) return .null;
                    if (ilen < -1) return ParseError.InvalidLength;
                    const len: usize = @intCast(ilen);

                    const elements = if (flavor == .map or flavor == .attr) len * 2 else len;

                    var written: usize = 0;
                    var items = try alloc.alloc(Resp, elements);
                    errdefer {
                        for (items[0..written]) |item| {
                            item.deinit(alloc);
                        }
                        alloc.free(items);
                    }

                    for (items) |*item| {
                        const value = try data.next(alloc) orelse return ParseError.NeedMoreData;
                        item.* = value.data;
                        written += 1;
                    }

                    switch (flavor) {
                        inline .array => return .{ .array = .{ .items = items } },
                        inline .set => return .{ .set = .{ .items = items } },
                        inline .push => return .{ .push = .{ .items = items } },
                        inline .map => return .{ .map = .{ .items = items } },
                        inline .attr => return .{ .attribute = .{ .items = items } },
                    }
                }
            };
        }
    };

    const parsers = std.enums.directEnumArray(Tag, Parsers, std.math.maxInt(u8), .{
        .null = .null,
        .bool = .bool,
        .int = .int,
        .double = .double,
        .bignum = .bignum,
        .string = .string,
        .bulk_str = .bulk_str,
        .verbatim = .verbatim,
        .err = .err,
        .bulk_err = .bulk_err,
        .array = .array,
        .map = .map,
        .attribute = .attribute,
        .set = .set,
        .push = .push,
    });
    // }}}
};
// }}}

// Writer {{{
const DefaultWriter = Writer(64, 4096, @shlExact(mem.page_size, 2));
fn Writer(comptime max_chunks: u8, comptime print_buf_size: u16, comptime write_chunk_size: u29) type {
    comptime assert(max_chunks > 0);
    comptime assert(print_buf_size > 16);
    comptime assert(write_chunk_size > 64);

    return struct {
        const Self = @This();
        const Vecs = std.BoundedArray(vec, max_chunks);

        buf: [print_buf_size]u8 = undefined,
        buf_upto: usize = 0,
        vecs: Vecs = Vecs.init(0) catch unreachable,
        total: usize = 0,
        stream: net.Stream,

        fn init(stream: net.Stream) Self {
            return .{ .stream = stream };
        }

        fn append(self: *Self, slice: []const u8) !void {
            if (slice.len + self.total > write_chunk_size or self.vecs.len == max_chunks) try self.flush();

            const iovec = if (@hasField(vec, "base"))
                vec{ .base = slice.ptr, .len = slice.len }
            else
                vec{ .iov_base = slice.ptr, .iov_len = slice.len };

            self.vecs.append(iovec) catch unreachable;
            self.total += slice.len;
        }

        fn print(self: *Self, comptime fmt: []const u8, args: anytype) !void {
            const data = try std.fmt.bufPrint(self.buf[self.buf_upto..], fmt, args);
            self.buf_upto += data.len;
            return self.append(data);
        }

        fn flush(self: *Self) std.posix.WriteError!void {
            if (self.total == 0) return;
            defer {
                self.vecs.resize(0) catch unreachable;
                self.total = 0;
            }

            try self.stream.writevAll(self.vecs.slice());
        }
    };
}
// }}}

// }}}

const std = @import("std");
const Alloc = mem.Allocator;
const ReadError = std.posix.ReadError;
const ascii = std.ascii;
const assert = std.debug.assert;
const fs = std.fs;
const io = std.io;
const log = std.log.scoped(.redis);
const mem = std.mem;
const net = std.net;
const thread = std.Thread;
const time = std.time;
const vec = std.posix.iovec_const;

pub const std_options = .{
    .log_level = .info,
};
