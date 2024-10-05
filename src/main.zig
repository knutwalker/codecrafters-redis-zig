pub fn main() !void {
    const address = try net.Address.resolveIp("127.0.0.1", 6379);

    var listener = try address.listen(.{
        .reuse_address = true,
    });
    defer listener.deinit();

    while (true) {
        const connection = try listener.accept();

        log.debug("accepted new connection from {}", .{connection.address});
        try connection.stream.writeAll("+PONG\r\n");
        connection.stream.close();
    }
}

const std = @import("std");
const ascii = std.ascii;
const fs = std.fs;
const io = std.io;
const log = std.log;
const mem = std.mem;
const net = std.net;
const thread = std.Thread;
