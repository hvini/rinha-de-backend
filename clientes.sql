create table clientes (
    id integer primary key autoincrement not null,
    limite integer not null,
    saldo_inicial integer not null
);

insert into clientes (limite, saldo_inicial) values (100000, 0);
insert into clientes (limite, saldo_inicial) values (80000, 0);
insert into clientes (limite, saldo_inicial) values (1000000, 0);
insert into clientes (limite, saldo_inicial) values (10000000, 0);
insert into clientes (limite, saldo_inicial) values (500000, 0);

create table transacoes (
    id integer primary key autoincrement not null,
    cliente_id integer not null,
    valor integer not null,
    tipo text check (tipo in ('c', 'd')) not null,
    descricao text not null,
    realizada_em integer not null,
    foreign key (cliente_id) references clientes(id)
);