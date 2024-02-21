const std = @import("std");
const zap = @import("zap");
const sqlite = @import("sqlite.zig");

alloc: std.mem.Allocator = undefined,
lock: std.Thread.Mutex = undefined,
_db: sqlite.Database = undefined,

pub const Self = @This();

pub const Client = struct {
    id: usize,
    limite: f64,
    saldo_inicial: f64,
};

pub const Transacao = struct {
    id: usize,
    cliente_id: usize,
    valor: f64,
    tipo: []const u8,
    descricao: []const u8,
    realizada_em: []const u8,
};

pub fn init(a: std.mem.Allocator, db: sqlite.Database) Self {
    return .{
        ._db = db,
        .alloc = a,
        .lock = std.Thread.Mutex{},
    };
}

pub fn add(self: *Self, id: usize, valor: f64, tipo: []const u8, descricao: []const u8) ![]const u8 {
    // We lock only on insertion, deletion, and listing
    self.lock.lock();
    defer self.lock.unlock();

    const stmt = try self._db.prepare(struct { cliente_id: usize, valor: f64, tipo: sqlite.Text, descricao: sqlite.Text }, void, "INSERT INTO transacoes (cliente_id, valor, tipo, descricao) VALUES (:cliente_id, :valor, :tipo, :descricao)");
    defer stmt.deinit();

    try stmt.exec(.{
        .cliente_id = id,
        .valor = valor,
        .tipo = sqlite.text(tipo),
        .descricao = sqlite.text(descricao),
    });

    return std.json.stringifyAlloc(self.alloc, .{}, .{});
}

pub fn get(self: *Self, id: usize) ![]const u8 {
    const stmt = try self._db.prepare(struct { id: usize }, Client, "SELECT * FROM clientes WHERE id = :id");
    defer stmt.deinit();

    {
        try stmt.bind(.{ .id = id });
        defer stmt.reset();

        if (try stmt.step()) |pClient| {
            var client: Client = .{
                .id = pClient.id,
                .limite = pClient.limite,
                .saldo_inicial = pClient.saldo_inicial,
            };
            return std.json.stringifyAlloc(self.alloc, client, .{});
        } else {
            return std.json.stringifyAlloc(self.alloc, .{}, .{});
        }
    }
}