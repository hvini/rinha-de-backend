const std = @import("std");
const zap = @import("zap");
const ClientWeb = @import("clientweb.zig");
const c = @import("c.zig");
const errors = @import("errors.zig");
const sqlite = @import("sqlite.zig");

fn on_request(r: zap.Request) void {
    if (r.path) |the_path| {
        std.debug.print("PATH: {s}\n", .{the_path});
    }

    if (r.query) |the_query| {
        std.debug.print("QUERY: {s}\n", .{the_query});
    }
    r.sendBody("<html><body><h1>Hello from ZAP!!!</h1></body></html>") catch return;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .thread_safe = true,
    }){};
    var allocator = gpa.allocator();

    // we scope everything that can allocate within this block for leak detection
    {
        // setup listener
        var listener = zap.Endpoint.Listener.init(
            allocator,
            .{
                .port = 3000,
                .on_request = on_request,
                .log = true,
                .max_body_size = 100 * 1024 * 1024,
            },
        );
        defer listener.deinit();

        const db = try sqlite.Database.init(.{
            .mode = sqlite.Database.Mode.ReadWrite,
            .path = "data.db",
        });
        defer db.deinit();

        // /clients endpoint
        var clientWeb = ClientWeb.init(allocator, db, "/clientes");

        // register endpoints with the listener
        try listener.register(clientWeb.endpoint());

        // listen
        try listener.listen();

        std.debug.print("Listening on 0.0.0.0:3000\n", .{});

        // and run
        zap.start(.{
            .threads = 2000,
            // IMPORTANT! It is crucial to only have a single worker for this example to work!
            // Multiple workers would have multiple copies of the clients hashmap.
            //
            // Since zap is quite fast, you can do A LOT with a single worker.
            // Try it with `zig build run-endpoint -Drelease-fast`
            .workers = 1,
        });
    }

    // show potential memory leaks when ZAP is shut down
    const has_leaked = gpa.detectLeaks();
    std.log.debug("Has leaked: {}\n", .{has_leaked});
}
