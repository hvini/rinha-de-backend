const std = @import("std");
const zap = @import("zap");

alloc: std.mem.Allocator = undefined,
clients: std.AutoHashMap(usize, InternalClient) = undefined,
lock: std.Thread.Mutex = undefined,
count: usize = 0,

pub const Self = @This();

pub const InternalClient = struct {
    id: usize,
    limitebuf: f64,
    limitelen: usize,
    saldoinicialbuf: f64,
    saldoiniciallen: usize,
};

pub const Client = struct {
    id: usize,
    limite: f64,
    saldo_inicial: f64,
};

pub fn init(a: std.mem.Allocator) Self {
    return .{
        .alloc = a,
        .clients = std.AutoHashMap(usize, InternalClient).init(a),
        .lock = std.Thread.Mutex{},
    };
}

pub fn deinit(self: *Self) void {
    self.clients.deinit();
}

// the request will be freed (and its mem reused by facilio) when it's
// completed, so we take copies of the names
pub fn add(self: *Self, lim: ?f64, inicial: ?f64) !usize {
    var client: InternalClient = undefined;
    client.limitelen = 0;
    client.saldoiniciallen = 0;

    if (lim) |limite| {
        client.limitebuf = limite;
        client.limitelen = 1;
    }

    if (inicial) |saldo_inicial| {
        client.saldoinicialbuf = saldo_inicial;
        client.saldoiniciallen = 1;
    }

    // We lock only on insertion, deletion, and listing
    self.lock.lock();
    defer self.lock.unlock();
    client.id = self.count + 1;
    if (self.clients.put(client.id, client)) {
        self.count += 1;
        return client.id;
    } else |err| {
        std.debug.print("add error: {}\n", .{err});
        // make sure we pass on the error
        return err;
    }
}

pub fn get(self: *Self, id: usize) ?Client {
    // we don't care about locking here, as our usage-pattern is unlikely to
    // get a client by id that is not known yet
    if (self.clients.getPtr(id)) |pClient| {
        return .{
            .id = pClient.id,
            .limite = pClient.limitebuf,
            .saldo_inicial = pClient.saldoinicialbuf,
        };
    }
    return null;
}

pub fn toJSON(self: *Self) ![]const u8 {
    self.lock.lock();
    defer self.lock.unlock();

    // We create a Client list that's JSON-friendly
    // NOTE: we could also implement the whole JSON writing ourselves here,
    // working directly with InternalClient elements of the clients hashmap.
    // might actually save some memory
    // TODO: maybe do it directly with the client.items
    var l: std.ArrayList(Client) = std.ArrayList(Client).init(self.alloc);
    defer l.deinit();

    // the potential race condition is fixed by jsonifying with the mutex locked
    var it = JsonClientIteratorWithRaceCondition.init(&self.clients);
    while (it.next()) |client| {
        try l.append(client);
    }
    std.debug.assert(self.clients.count() == l.items.len);
    std.debug.assert(self.count == l.items.len);
    return std.json.stringifyAlloc(self.alloc, l.items, .{});
}

//
// Note: the following code is kept in here because it taught us a lesson
//
pub fn listWithRaceCondition(self: *Self, out: *std.ArrayList(Client)) !void {
    // We lock only on insertion, deletion, and listing
    self.lock.lock();
    defer self.lock.unlock();
    var it = JsonClientIteratorWithRaceCondition.init(&self.clients);
    while (it.next()) |client| {
        try out.append(client);
    }
    std.debug.assert(self.clients.count() == out.items.len);
    std.debug.assert(self.count == out.items.len);
}

const JsonClientIteratorWithRaceCondition = struct {
    it: std.AutoHashMap(usize, InternalClient).ValueIterator = undefined,
    const This = @This();

    // careful:
    // - Self refers to the file's struct
    // - This refers to the JsonClientIterator struct
    pub fn init(internal_clients: *std.AutoHashMap(usize, InternalClient)) This {
        return .{
            .it = internal_clients.valueIterator(),
        };
    }

    pub fn next(this: *This) ?Client {
        if (this.it.next()) |pClient| {
            // we get a pointer to the internal client. so it should be safe to
            // create slices from its first and last name buffers
            //
            // SEE ABOVE NOTE regarding race condition why this is can be problematic
            var client: Client = .{
                // we don't need .* syntax but want to make it obvious
                .id = pClient.*.id,
                .limite = pClient.*.limitebuf,
                .saldo_inicial = pClient.*.saldoinicialbuf,
            };
            if (pClient.*.limitelen == 0) {
                client.limite = undefined;
            }
            if (pClient.*.saldoiniciallen == 0) {
                client.saldo_inicial = undefined;
            }
            return client;
        }
        return null;
    }
};
