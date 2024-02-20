const std = @import("std");
const zap = @import("zap");
const Clients = @import("clients.zig");
const Client = Clients.Client;
const sqlite = @import("sqlite.zig");

// an Endpoint

pub const Self = @This();

alloc: std.mem.Allocator = undefined,
ep: zap.Endpoint = undefined,
_clients: Clients = undefined,

pub fn init(a: std.mem.Allocator, db: sqlite.Database, client_path: []const u8) Self {
    return .{
        .alloc = a,
        ._clients = Clients.init(a, db),
        .ep = zap.Endpoint.init(.{
            .path = client_path,
            .get = getClient,
            .post = postClient,
            .options = optionsClient,
        }),
    };
}

pub fn deinit(self: *Self) void {
    self._clients.deinit();
}

pub fn clients(self: *Self) *Clients {
    return &self._clients;
}

pub fn endpoint(self: *Self) *zap.Endpoint {
    return &self.ep;
}

fn clientIdFromPath(self: *Self, path: []const u8) ?usize {
    if (path.len >= self.ep.settings.path.len + 2) {
        if (path[self.ep.settings.path.len] != '/') {
            return null;
        }
        // get next slash position
        var i: usize = self.ep.settings.path.len + 1;
        while (i < path.len and path[i] != '/') : (i += 1) {}
        if (i == path.len) {
            return null;
        }
        const idstr = path[self.ep.settings.path.len + 1 .. i];
        return std.fmt.parseUnsigned(usize, idstr, 10) catch null;
    }
    return null;
}

fn getClient(e: *zap.Endpoint, r: zap.Request) void {
    const self = @fieldParentPtr(Self, "ep", e);
    if (r.path) |path| {
        if (self.clientIdFromPath(path)) |id| {
            if (self._clients.get(id)) |json| {
                defer self.alloc.free(json);
                if (json.len == 2) {
                    r.setStatus(zap.StatusCode.not_found);
                    r.markAsFinished(true);
                    return;
                }
                r.sendJson(json) catch return;
            } else |err| {
                std.debug.print("GET error: {}\n", .{err});
                return;
            }
        }
    }
}

fn postClient(e: *zap.Endpoint, r: zap.Request) void {
    const self = @fieldParentPtr(Self, "ep", e);
    if (r.body) |body| {
        var maybe_client: ?std.json.Parsed(Client) = std.json.parseFromSlice(Client, self.alloc, body, .{}) catch null;
        if (maybe_client) |u| {
            defer u.deinit();
            if (self._clients.add(u.value.limite, u.value.saldo_inicial)) |id| {
                var jsonbuf: [128]u8 = undefined;
                if (zap.stringifyBuf(&jsonbuf, .{ .status = "OK", .id = id }, .{})) |json| {
                    r.sendJson(json) catch return;
                }
            } else |err| {
                std.debug.print("ADDING error: {}\n", .{err});
                return;
            }
        }
    }
}

fn optionsClient(e: *zap.Endpoint, r: zap.Request) void {
    _ = e;
    r.setHeader("Access-Control-Allow-Origin", "*") catch return;
    r.setHeader("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS") catch return;
    r.setStatus(zap.StatusCode.no_content);
    r.markAsFinished(true);
}
