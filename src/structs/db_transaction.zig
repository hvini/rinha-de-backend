const sqlite = @import("../wrapper/sqlite.zig");

pub const DbTransaction = struct {
    cliente_id: usize,
    valor: i64,
    tipo: sqlite.Text,
    descricao: sqlite.Text,
    realizada_em: i64,
};
