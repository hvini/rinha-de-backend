pub const InternalTransaction = struct {
    valorbuf: i64,
    valorlen: usize,
    tipobuf: [512]u8,
    tipolen: usize,
    descricaobuf: [512]u8,
    descricaolen: usize,
    realizadaembuf: i64,
    realizadaemlen: usize,
};
