const std = @import("std");
const zap = @import("zap");
const sqlite = @import("sqlite.zig");

alloc: std.mem.Allocator = undefined,
lock: std.Thread.Mutex = undefined,
transactions: std.AutoHashMap(usize, InternalTransaction) = undefined,
_db: sqlite.Database = undefined,

pub const Self = @This();

pub const Client = struct {
    id: usize,
    limite: u64,
    saldo_inicial: u64,
};

pub const DbTransaction = struct {
    id: usize,
    cliente_id: usize,
    valor: u64,
    tipo: sqlite.Text,
    descricao: sqlite.Text,
    realizada_em: sqlite.Text,
};

pub const Transaction = struct {
    valor: u64,
    tipo: []const u8,
    descricao: []const u8,
    realizada_em: []const u8,
};

pub const InternalTransaction = struct {
    valorbuf: u64,
    valorlen: usize,
    tipobuf: [512]u8,
    tipolen: usize,
    descricaobuf: [512]u8,
    descricaolen: usize,
    realizadaembuf: [512]u8,
    realizadaemlen: usize,
};

pub fn init(a: std.mem.Allocator, db: sqlite.Database) Self {
    return .{
        ._db = db,
        .alloc = a,
        .transactions = std.AutoHashMap(usize, InternalTransaction).init(a),
        .lock = std.Thread.Mutex{},
    };
}

pub fn deinit(self: *Self) void {
    self.transactions.deinit();
}

pub fn add(self: *Self, id: usize, valor: u64, tipo: []const u8, descricao: []const u8) ![]const u8 {
    // We lock only on insertion, deletion, and listing
    self.lock.lock();
    defer self.lock.unlock();

    const stmt = try self._db.prepare(struct { cliente_id: usize, valor: u64, tipo: sqlite.Text, descricao: sqlite.Text }, void, "INSERT INTO transacoes (cliente_id, valor, tipo, descricao) VALUES (:cliente_id, :valor, :tipo, :descricao)");
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
    const client = try self._db.prepare(struct { id: usize }, Client, "SELECT * FROM clientes WHERE id = :id");
    defer client.deinit();

    try client.bind(.{ .id = id });
    defer client.reset();

    var c: Client = undefined;
    if (try client.step()) |pClient| {
        c = pClient;
    } else {
        return std.json.stringifyAlloc(self.alloc, .{}, .{});
    }

    const transactions = try self._db.prepare(struct { cliente_id: usize }, DbTransaction, "SELECT * FROM transacoes WHERE cliente_id = :cliente_id ORDER BY realizada_em DESC LIMIT 10");
    defer transactions.deinit();

    try transactions.bind(.{ .cliente_id = id });
    defer transactions.reset();

    self.transactions.deinit();
    self.transactions = std.AutoHashMap(usize, InternalTransaction).init(self.alloc);

    while (try transactions.step()) |pTransacao| {
        var internal: InternalTransaction = undefined;

        internal.valorbuf = pTransacao.valor;
        internal.valorlen = 0;
        std.mem.copy(u8, internal.tipobuf[0..], pTransacao.tipo.data);
        internal.tipolen = pTransacao.tipo.data.len;
        std.mem.copy(u8, internal.descricaobuf[0..], pTransacao.descricao.data);
        internal.descricaolen = pTransacao.descricao.data.len;
        std.mem.copy(u8, internal.realizadaembuf[0..], pTransacao.realizada_em.data);
        internal.realizadaemlen = pTransacao.realizada_em.data.len;

        self.lock.lock();
        defer self.lock.unlock();
        try self.transactions.put(pTransacao.id, internal);
    }

    return try self.toJSON(c);
}

pub fn toJSON(self: *Self, client: Client) ![]const u8 {
    self.lock.lock();
    defer self.lock.unlock();

    var l: std.ArrayList(Transaction) = std.ArrayList(Transaction).init(self.alloc);
    defer l.deinit();

    var it = JsonIteratorWithRaceCondition.init(&self.transactions);
    while (it.next()) |transaction| {
        try l.append(transaction);
    }

    var result = .{
        .saldo = .{
            .total = client.saldo_inicial,
            .data_extrato = std.time.timestamp(),
            .limite = client.limite,
        },
        .ultimas_transacoes = l.items,
    };

    return std.json.stringifyAlloc(self.alloc, result, .{});
}

const JsonIteratorWithRaceCondition = struct {
    it: std.AutoHashMap(usize, InternalTransaction).ValueIterator = undefined,
    const This = @This();

    pub fn init(internal_transactions: *std.AutoHashMap(usize, InternalTransaction)) This {
        return .{
            .it = internal_transactions.valueIterator(),
        };
    }

    pub fn next(this: *This) ?Transaction {
        if (this.it.next()) |pTransaction| {
            var transaction: Transaction = .{
                .valor = pTransaction.*.valorbuf,
                .tipo = pTransaction.*.tipobuf[0..pTransaction.*.tipolen],
                .descricao = pTransaction.*.descricaobuf[0..pTransaction.*.descricaolen],
                .realizada_em = pTransaction.*.realizadaembuf[0..pTransaction.*.realizadaemlen],
            };
            if (pTransaction.*.tipolen == 0) {
                transaction.tipo = "";
            }
            if (pTransaction.*.descricaolen == 0) {
                transaction.descricao = "";
            }
            if (pTransaction.*.realizadaemlen == 0) {
                transaction.realizada_em = "";
            }
            return transaction;
        }
        return null;
    }
};
