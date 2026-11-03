-- Saídas e distratos (página saidas.html): o quadro do antigo Trello "SAÍDAS - DISTRATOS" (aviso de saída, vistoria,
-- reparos, cálculo, distrato, cobrança e acionamento das garantias), com o histórico importado do Trello.
-- Acesso: gestores, acesso geral e quem tem os departamentos Pós-locação, Contas a Pagar (repasses), Cobrança ou Boletos.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de departamentos.sql e acesso_geral.sql.

create or replace function public.pode_saidas()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.pode_departamento('pos-locacao') or public.pode_departamento('repasses')
      or public.pode_departamento('cobranca') or public.pode_departamento('boletos');
$$;

grant execute on function public.pode_saidas() to anon, authenticated;

create table if not exists public.saidas_colunas (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (char_length(nome) between 1 and 160),
  posicao double precision not null default 0,
  arquivada boolean not null default false, -- colunas arquivadas no Trello: os cartões delas só aparecem em "Arquivados"
  trello_id text unique
);

create table if not exists public.saidas_etiquetas (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (char_length(nome) between 0 and 80),
  cor text not null default 'blue',
  trello_id text unique
);

create table if not exists public.saidas_cartoes (
  id uuid primary key default gen_random_uuid(),
  coluna_id uuid not null references public.saidas_colunas (id),
  posicao double precision not null default 0,
  titulo text not null check (char_length(titulo) between 1 and 500),
  referencia text,
  descricao text not null default '' check (char_length(descricao) <= 30000),
  etiquetas uuid[] not null default '{}',
  membros text[] not null default '{}',   -- nomes de quem está no cartão (no Trello: membros)
  prazo timestamptz,                      -- data de entrega do Trello
  prazo_ok boolean not null default false,
  checklists jsonb not null default '[]', -- [{"nome": "...", "itens": [{"texto": "...", "feito": true}]}]
  anexos jsonb not null default '[]',     -- [{"nome": "...", "url": "...", "data": "..."}] (os arquivos ficam no Trello)
  arquivado boolean not null default false,
  arquivado_em timestamptz,
  trello_id text unique,
  trello_url text,
  criado_em timestamptz not null default now(),
  criado_por text default (auth.jwt() ->> 'email'),
  movido_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create index if not exists saidas_cartoes_coluna_idx on public.saidas_cartoes (coluna_id);
create index if not exists saidas_cartoes_referencia_idx on public.saidas_cartoes (referencia);
create index if not exists saidas_cartoes_arquivado_idx on public.saidas_cartoes (arquivado);

create table if not exists public.saidas_historico (
  id uuid primary key default gen_random_uuid(),
  cartao_id uuid not null references public.saidas_cartoes (id) on delete cascade,
  tipo text not null check (tipo in ('comentario', 'criado', 'movido', 'arquivado', 'restaurado', 'editado')),
  texto text check (char_length(texto) <= 30000),
  de_coluna text,
  para_coluna text,
  autor text default (auth.jwt() ->> 'email'),
  criado_em timestamptz not null default now(),
  trello_id text unique
);

create index if not exists saidas_historico_cartao_idx on public.saidas_historico (cartao_id, criado_em);

create or replace view public.saidas_comentarios with (security_invoker = true) as
  select cartao_id, count(*)::int as comentarios from public.saidas_historico where tipo = 'comentario' group by cartao_id;

alter table public.saidas_colunas enable row level security;
alter table public.saidas_etiquetas enable row level security;
alter table public.saidas_cartoes enable row level security;
alter table public.saidas_historico enable row level security;

drop policy if exists "saidas_colunas: acesso" on public.saidas_colunas;
create policy "saidas_colunas: acesso" on public.saidas_colunas
  for all to authenticated using (public.pode_saidas()) with check (public.pode_saidas());
drop policy if exists "saidas_etiquetas: acesso" on public.saidas_etiquetas;
create policy "saidas_etiquetas: acesso" on public.saidas_etiquetas
  for all to authenticated using (public.pode_saidas()) with check (public.pode_saidas());
drop policy if exists "saidas_cartoes: acesso" on public.saidas_cartoes;
create policy "saidas_cartoes: acesso" on public.saidas_cartoes
  for all to authenticated using (public.pode_saidas()) with check (public.pode_saidas());
-- Histórico: todos leem e comentam; só o autor apaga o próprio comentário.
drop policy if exists "saidas_historico: leitura" on public.saidas_historico;
create policy "saidas_historico: leitura" on public.saidas_historico
  for select to authenticated using (public.pode_saidas());
drop policy if exists "saidas_historico: comentar" on public.saidas_historico;
create policy "saidas_historico: comentar" on public.saidas_historico
  for insert to authenticated with check (public.pode_saidas() and tipo in ('comentario', 'criado', 'editado', 'arquivado', 'restaurado') and autor = auth.jwt() ->> 'email');
drop policy if exists "saidas_historico: apagar o próprio comentário" on public.saidas_historico;
create policy "saidas_historico: apagar o próprio comentário" on public.saidas_historico
  for delete to authenticated using (public.pode_saidas() and tipo = 'comentario' and autor = auth.jwt() ->> 'email');

revoke all on public.saidas_colunas, public.saidas_etiquetas, public.saidas_cartoes, public.saidas_historico, public.saidas_comentarios from anon;
grant select, insert, update, delete on public.saidas_colunas, public.saidas_etiquetas, public.saidas_cartoes to authenticated;
grant select, insert, delete on public.saidas_historico to authenticated;
grant select on public.saidas_comentarios to authenticated;

-- Move o cartão (coluna e posição) e registra no histórico, numa operação só.
create or replace function public.saidas_mover(p_cartao uuid, p_coluna uuid, p_posicao double precision)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_de uuid;
begin
  if not public.pode_saidas() then
    raise exception 'Sem permissão';
  end if;
  select coluna_id into v_de from public.saidas_cartoes where id = p_cartao for update;
  if not found then
    raise exception 'Cartão não encontrado';
  end if;
  update public.saidas_cartoes
     set coluna_id = p_coluna, posicao = p_posicao, atualizado_em = now(),
         movido_em = case when v_de <> p_coluna then now() else movido_em end
   where id = p_cartao;
  if v_de <> p_coluna then
    insert into public.saidas_historico (cartao_id, tipo, de_coluna, para_coluna, autor)
    select p_cartao, 'movido', (select nome from public.saidas_colunas where id = v_de), (select nome from public.saidas_colunas where id = p_coluna), auth.jwt() ->> 'email';
  end if;
end;
$$;

revoke execute on function public.saidas_mover(uuid, uuid, double precision) from public, anon;
grant execute on function public.saidas_mover(uuid, uuid, double precision) to authenticated;
