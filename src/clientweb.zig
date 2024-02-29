const std = @import("std");
const zap = @import("zap");
const Clients = @import("clients.zig");
const Client = @import("structs/client.zig").Client;
const TransactionDto = @import("structs/transaction_dto.zig").TransactionDto;
const sqlite = @import("wrapper/sqlite.zig");

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
            var i: usize = 0;
            while (i < 3) {
                if (self._clients.get(id)) |data| {
                    if (self._clients.toJSON(data.client, data.transactions)) |json| {
                        defer self.alloc.free(json);
                        r.sendJson(json) catch return;
                    } else |_| {
                        r.setStatus(zap.StatusCode.bad_request);
                        r.markAsFinished(true);
                        return;
                    }
                } else |err| switch (err) {
                    error.SQLITE_BUSY => {
                        i += 1;
                        if (i <= 3) {
                            std.time.sleep(90000);
                            continue;
                        }
                        r.setStatus(zap.StatusCode.internal_server_error);
                        r.markAsFinished(true);
                        return;
                    },
                    else => {
                        r.setStatus(zap.StatusCode.not_found);
                        r.markAsFinished(true);
                        return;
                    },
                }
            }
        }
    }
}

fn postClient(e: *zap.Endpoint, r: zap.Request) void {
    const self = @fieldParentPtr(Self, "ep", e);
    if (r.path) |path| {
        if (r.body) |body| {
            if (std.json.parseFromSlice(TransactionDto, self.alloc, body, .{})) |u| {
                defer u.deinit();
                if (self.clientIdFromPath(path)) |id| {
                    var i: usize = 0;
                    while (i < 3) {
                        if (self._clients.get(id)) |data| {
                            if (self._clients.add(data.client, u.value)) |json| {
                                defer self.alloc.free(json);
                                r.sendJson(json) catch return;
                            } else |err| switch (err) {
                                error.SQLITE_BUSY => {
                                    i += 1;
                                    if (i <= 3) {
                                        std.time.sleep(90000);
                                        continue;
                                    }
                                    r.setStatus(zap.StatusCode.internal_server_error);
                                    r.markAsFinished(true);
                                    return;
                                },
                                else => {
                                    //422
                                    r.setStatus(zap.StatusCode.bad_request);
                                    r.markAsFinished(true);
                                    return;
                                },
                            }
                        } else |err| switch (err) {
                            error.SQLITE_BUSY => {
                                i += 1;
                                if (i <= 3) {
                                    std.time.sleep(90000);
                                    continue;
                                }
                                r.setStatus(zap.StatusCode.internal_server_error);
                                r.markAsFinished(true);
                                return;
                            },
                            else => {
                                r.setStatus(zap.StatusCode.not_found);
                                r.markAsFinished(true);
                                return;
                            },
                        }
                    }
                }
            } else |_| {
                //422
                r.setStatus(zap.StatusCode.bad_request);
                r.markAsFinished(true);
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
