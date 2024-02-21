create table clientes (
    id integer primary key autoincrement,
    limite float,
    saldo_inicial float
);

insert into clientes (limite, saldo_inicial) values (100000, 0);
insert into clientes (limite, saldo_inicial) values (80000, 0);
insert into clientes (limite, saldo_inicial) values (1000000, 0);
insert into clientes (limite, saldo_inicial) values (10000000, 0);
insert into clientes (limite, saldo_inicial) values (500000, 0);

create table transacoes (
    id integer primary key autoincrement,
    cliente_id integer,
    valor float,
    tipo text,
    descricao text,
    realizada_em datetime default current_timestamp,
    foreign key (cliente_id) references clientes(id)
);