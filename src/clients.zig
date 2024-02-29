const std = @import("std");
const zap = @import("zap");
const sqlite = @import("wrapper/sqlite.zig");
const Client = @import("structs/client.zig").Client;
const Transaction = @import("structs/transaction.zig").Transaction;
const InternalTransaction = @import("structs/internal_transaction.zig").InternalTransaction;
const DbTransaction = @import("structs/db_transaction.zig").DbTransaction;
const TransactionDto = @import("structs/transaction_dto.zig").TransactionDto;

alloc: std.mem.Allocator = undefined,
lock: std.Thread.Mutex = undefined,
_db: sqlite.Database = undefined,

pub const A = struct {
    client: Client,
    transactions: std.AutoArrayHashMap(i64, InternalTransaction),
};

pub const Self = @This();

pub fn init(a: std.mem.Allocator, db: sqlite.Database) Self {
    return .{
        ._db = db,
        .alloc = a,
        .lock = std.Thread.Mutex{},
    };
}

pub fn add(self: *Self, client: Client, u: TransactionDto) ![]const u8 {
    if (!std.mem.eql(u8, u.tipo[0..], "d") and !std.mem.eql(u8, u.tipo[0..], "c")) {
        return error.InvalidType;
    }

    if (u.descricao.len == 0 or u.descricao.len > 10) {
        return error.InvalidDescription;
    }

    var total = client.saldo_inicial;
    if (std.mem.eql(u8, u.tipo[0..], "d")) {
        total -= u.valor;
        if (std.math.absCast(total) > client.limite) {
            return error.LimitExceeded;
        }
    } else {
        total += u.valor;
    }

    // update client
    const clientStmt = try self._db.prepare(struct { id: usize, saldo_inicial: i64 }, void, "UPDATE clientes SET saldo_inicial = :saldo_inicial WHERE id = :id");
    defer clientStmt.deinit();

    try clientStmt.exec(.{
        .id = client.id,
        .saldo_inicial = total,
    });

    self.lock.lock();
    defer self.lock.unlock();

    // create transaction
    const transactionStmt = try self._db.prepare(DbTransaction, void, "INSERT INTO transacoes (cliente_id, valor, tipo, descricao, realizada_em) VALUES (:cliente_id, :valor, :tipo, :descricao, :realizada_em)");
    defer transactionStmt.deinit();

    try transactionStmt.exec(.{
        .cliente_id = client.id,
        .valor = u.valor,
        .tipo = sqlite.text(u.tipo),
        .descricao = sqlite.text(u.descricao),
        .realizada_em = std.time.timestamp(),
    });

    return std.json.stringifyAlloc(self.alloc, .{
        .limite = client.limite,
        .saldo = total,
    }, .{});
}

pub fn get(self: *Self, id: usize) !A {
    self.lock.lock();
    defer self.lock.unlock();

    const client = try self._db.prepare(struct { id: usize }, Client, "SELECT * FROM clientes WHERE id = :id");
    defer client.deinit();

    try client.bind(.{ .id = id });
    defer client.reset();

    var c: Client = undefined;
    if (try client.step()) |pClient| {
        c = pClient;
    } else {
        return error.ClientNotFound;
    }

    const transactions = try self._db.prepare(struct { cliente_id: usize }, DbTransaction, "SELECT * FROM transacoes WHERE cliente_id = :cliente_id ORDER BY realizada_em DESC LIMIT 10");
    defer transactions.deinit();

    try transactions.bind(.{ .cliente_id = id });
    defer transactions.reset();

    var list = std.AutoArrayHashMap(i64, InternalTransaction).init(self.alloc);
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

        try list.put(pTransacao.realizada_em, internal);
    }

    return A{ .client = c, .transactions = list };
}

pub const DateTime = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
};

pub fn fromTimestamp(ts: u64) DateTime {
    const SECONDS_PER_DAY = 86400;
    const DAYS_PER_YEAR = 365;
    const DAYS_IN_4YEARS = 1461;
    const DAYS_IN_100YEARS = 36524;
    const DAYS_IN_400YEARS = 146097;
    const DAYS_BEFORE_EPOCH = 719468;

    const seconds_since_midnight: u64 = @rem(ts, SECONDS_PER_DAY);
    var day_n: u64 = DAYS_BEFORE_EPOCH + ts / SECONDS_PER_DAY;
    var temp: u64 = 0;

    temp = 4 * (day_n + DAYS_IN_100YEARS + 1) / DAYS_IN_400YEARS - 1;
    var year: u16 = @intCast(100 * temp);
    day_n -= DAYS_IN_100YEARS * temp + temp / 4;

    temp = 4 * (day_n + DAYS_PER_YEAR + 1) / DAYS_IN_4YEARS - 1;
    year += @intCast(temp);
    day_n -= DAYS_PER_YEAR * temp + temp / 4;

    var month: u8 = @intCast((5 * day_n + 2) / 153);
    const day: u8 = @intCast(day_n - (@as(u64, @intCast(month)) * 153 + 2) / 5 + 1);

    month += 3;
    if (month > 12) {
        month -= 12;
        year += 1;
    }

    return DateTime{ .year = year, .month = month, .day = day, .hour = @intCast(seconds_since_midnight / 3600), .minute = @intCast(seconds_since_midnight % 3600 / 60), .second = @intCast(seconds_since_midnight % 60) };
}

pub fn toRFC3339(dt: DateTime) [20]u8 {
    var buf: [20]u8 = undefined;
    _ = std.fmt.formatIntBuf(buf[0..4], dt.year, 10, .lower, .{ .width = 4, .fill = '0' });
    buf[4] = '-';
    paddingTwoDigits(buf[5..7], dt.month);
    buf[7] = '-';
    paddingTwoDigits(buf[8..10], dt.day);
    buf[10] = 'T';

    paddingTwoDigits(buf[11..13], dt.hour);
    buf[13] = ':';
    paddingTwoDigits(buf[14..16], dt.minute);
    buf[16] = ':';
    paddingTwoDigits(buf[17..19], dt.second);
    buf[19] = 'Z';

    return buf;
}

fn paddingTwoDigits(buf: *[2]u8, value: u8) void {
    switch (value) {
        0 => buf.* = "00".*,
        1 => buf.* = "01".*,
        2 => buf.* = "02".*,
        3 => buf.* = "03".*,
        4 => buf.* = "04".*,
        5 => buf.* = "05".*,
        6 => buf.* = "06".*,
        7 => buf.* = "07".*,
        8 => buf.* = "08".*,
        9 => buf.* = "09".*,
        else => _ = std.fmt.formatIntBuf(buf, value, 10, .lower, .{}),
    }
}

pub fn toJSON(self: *Self, client: Client, transactions: std.AutoArrayHashMap(i64, InternalTransaction)) ![]const u8 {
    self.lock.lock();
    defer self.lock.unlock();

    var l: std.ArrayList(Transaction) = std.ArrayList(Transaction).init(self.alloc);
    defer l.deinit();

    var it = JsonIteratorWithRaceCondition.init(&transactions);
    while (it.next()) |transaction| {
        try l.append(transaction);
    }

    const dt = fromTimestamp(@intCast(std.time.timestamp()));
    var result = .{
        .saldo = .{
            .total = client.saldo_inicial,
            .data_extrato = toRFC3339(dt),
            .limite = client.limite,
        },
        .ultimas_transacoes = l.items,
    };

    return std.json.stringifyAlloc(self.alloc, result, .{});
}

const JsonIteratorWithRaceCondition = struct {
    it: std.AutoArrayHashMap(i64, InternalTransaction).Iterator = undefined,
    const This = @This();

    pub fn init(internal_transactions: *const std.AutoArrayHashMap(i64, InternalTransaction)) This {
        return .{
            .it = internal_transactions.iterator(),
        };
    }

    pub fn next(this: *This) ?Transaction {
        if (this.it.next()) |pTransaction| {
            const dt = fromTimestamp(@intCast(pTransaction.value_ptr.realizadaembuf));
            var transaction: Transaction = .{
                .valor = pTransaction.value_ptr.valorbuf,
                .tipo = pTransaction.value_ptr.tipobuf[0..pTransaction.value_ptr.tipolen],
                .descricao = pTransaction.value_ptr.descricaobuf[0..pTransaction.value_ptr.descricaolen],
                .realizada_em = toRFC3339(dt),
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
