pub const Transaction = struct {
    valor: i64,
    tipo: []const u8,
    descricao: []const u8,
    realizada_em: [20]u8,
};