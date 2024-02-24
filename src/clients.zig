const std = @import("std");
const zap = @import("zap");
const sqlite = @import("sqlite.zig");

alloc: std.mem.Allocator = undefined,
lock: std.Thread.Mutex = undefined,
transactions: std.AutoArrayHashMap(i64, InternalTransaction) = undefined,
_db: sqlite.Database = undefined,

pub const Self = @This();

pub const Client = struct {
    id: usize,
    limite: u64,
    saldo_inicial: u64,
};

pub const DbTransaction = struct {
    cliente_id: usize,
    valor: u64,
    tipo: sqlite.Text,
    descricao: sqlite.Text,
    realizada_em: i64,
};

pub const Transaction = struct {
    valor: u64,
    tipo: []const u8,
    descricao: []const u8,
    realizada_em: i64,
};

pub const InternalTransaction = struct {
    valorbuf: u64,
    valorlen: usize,
    tipobuf: [512]u8,
    tipolen: usize,
    descricaobuf: [512]u8,
    descricaolen: usize,
    realizadaembuf: i64,
    realizadaemlen: usize,
};

pub fn init(a: std.mem.Allocator, db: sqlite.Database) Self {
    return .{
        ._db = db,
        .alloc = a,
        .transactions = std.AutoArrayHashMap(i64, InternalTransaction).init(a),
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

    const stmt = try self._db.prepare(DbTransaction, void, "INSERT INTO transacoes (cliente_id, valor, tipo, descricao, realizada_em) VALUES (:cliente_id, :valor, :tipo, :descricao, :realizada_em)");
    defer stmt.deinit();

    try stmt.exec(.{
        .cliente_id = id,
        .valor = valor,
        .tipo = sqlite.text(tipo),
        .descricao = sqlite.text(descricao),
        .realizada_em = std.time.timestamp(),
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
    self.transactions = std.AutoArrayHashMap(i64, InternalTransaction).init(self.alloc);

    while (try transactions.step()) |pTransacao| {
        var internal: InternalTransaction = undefined;

        internal.valorbuf = pTransacao.valor;
        internal.valorlen = 0;
        std.mem.copy(u8, internal.tipobuf[0..], pTransacao.tipo.data);
        internal.tipolen = pTransacao.tipo.data.len;
        std.mem.copy(u8, internal.descricaobuf[0..], pTransacao.descricao.data);
        internal.descricaolen = pTransacao.descricao.data.len;
        internal.realizadaembuf = pTransacao.realizada_em;
        internal.realizadaemlen = 0;

        self.lock.lock();
        defer self.lock.unlock();
        try self.transactions.put(pTransacao.realizada_em, internal);
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
    it: std.AutoArrayHashMap(i64, InternalTransaction).Iterator = undefined,
    const This = @This();

    pub fn init(internal_transactions: *std.AutoArrayHashMap(i64, InternalTransaction)) This {
        return .{
            .it = internal_transactions.iterator(),
        };
    }

    pub fn next(this: *This) ?Transaction {
        if (this.it.next()) |pTransaction| {
            var transaction: Transaction = .{
                .valor = pTransaction.value_ptr.valorbuf,
                .tipo = pTransaction.value_ptr.tipobuf[0..pTransaction.value_ptr.tipolen],
                .descricao = pTransaction.value_ptr.descricaobuf[0..pTransaction.value_ptr.descricaolen],
                .realizada_em = pTransaction.value_ptr.realizadaembuf,
            };
            if (pTransaction.value_ptr.tipolen == 0) {
                transaction.tipo = "";
            }
            if (pTransaction.value_ptr.descricaolen == 0) {
                transaction.descricao = "";
            }
            return transaction;
        }
        return null;
    }
};
