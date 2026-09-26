-- Quadro de contratos (página quadro.html): a esteira da locação no formato do Trello "Contratos de Locação",
-- compartilhada entre a Locação e a Pré-análise. Cada locação lançada na planilha (tabela locacoes) vira um cartão.
-- Tudo restrito: gestores, locacao_acesso e pre_analise_acesso.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de locacao.sql e pre_analise.sql.

create or replace function public.pode_quadro()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.pode_locacao() or public.pode_pre_analise();
$$;

grant execute on function public.pode_quadro() to anon, authenticated;

create table if not exists public.quadro_colunas (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (char_length(nome) between 1 and 120),
  posicao integer not null default 0,
  entrada boolean not null default false, -- coluna onde nascem os cartões das locações novas
  trello_id text unique
);

create table if not exists public.quadro_etiquetas (
  id uuid primary key default gen_random_uuid(),
  nome text not null unique check (char_length(nome) between 1 and 60),
  cor text not null default 'blue',
  trello_id text unique
);

create table if not exists public.quadro_cartoes (
  id uuid primary key default gen_random_uuid(),
  coluna_id uuid not null references public.quadro_colunas (id),
  posicao double precision not null default 0,
  titulo text not null check (char_length(titulo) between 1 and 300),
  referencia text,
  descricao text not null default '' check (char_length(descricao) <= 20000),
  etiquetas uuid[] not null default '{}',
  locacao_id uuid references public.locacoes (id) on delete set null,
  modelo boolean not null default false,
  trello_id text unique,
  trello_url text,
  anexos_trello integer not null default 0,
  criado_em timestamptz not null default now(),
  criado_por text default (auth.jwt() ->> 'email'),
  movido_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create index if not exists quadro_cartoes_coluna_idx on public.quadro_cartoes (coluna_id);
create index if not exists quadro_cartoes_locacao_idx on public.quadro_cartoes (locacao_id);
create index if not exists quadro_cartoes_referencia_idx on public.quadro_cartoes (referencia);

-- Histórico de cada cartão: comentários, criação, mudanças de coluna (inclusive o histórico importado do Trello).
create table if not exists public.quadro_historico (
  id uuid primary key default gen_random_uuid(),
  cartao_id uuid not null references public.quadro_cartoes (id) on delete cascade,
  tipo text not null check (tipo in ('comentario', 'criado', 'movido', 'arquivado', 'restaurado', 'editado')),
  texto text check (char_length(texto) <= 20000),
  de_coluna text,
  para_coluna text,
  autor text default (auth.jwt() ->> 'email'),
  criado_em timestamptz not null default now()
);

create index if not exists quadro_historico_cartao_idx on public.quadro_historico (cartao_id, criado_em);

-- Quantidade de comentários por cartão (para o ícone no cartão, sem carregar o histórico todo).
create or replace view public.quadro_comentarios with (security_invoker = true) as
  select cartao_id, count(*)::int as comentarios from public.quadro_historico where tipo = 'comentario' group by cartao_id;

alter table public.quadro_colunas enable row level security;
alter table public.quadro_etiquetas enable row level security;
alter table public.quadro_cartoes enable row level security;
alter table public.quadro_historico enable row level security;

drop policy if exists "quadro_colunas: acesso" on public.quadro_colunas;
create policy "quadro_colunas: acesso" on public.quadro_colunas
  for all to authenticated using (public.pode_quadro()) with check (public.pode_quadro());
drop policy if exists "quadro_etiquetas: acesso" on public.quadro_etiquetas;
create policy "quadro_etiquetas: acesso" on public.quadro_etiquetas
  for all to authenticated using (public.pode_quadro()) with check (public.pode_quadro());
drop policy if exists "quadro_cartoes: acesso" on public.quadro_cartoes;
create policy "quadro_cartoes: acesso" on public.quadro_cartoes
  for all to authenticated using (public.pode_quadro()) with check (public.pode_quadro());
-- Histórico: todos leem e comentam; só o autor apaga o próprio comentário.
drop policy if exists "quadro_historico: leitura" on public.quadro_historico;
create policy "quadro_historico: leitura" on public.quadro_historico
  for select to authenticated using (public.pode_quadro());
drop policy if exists "quadro_historico: comentar" on public.quadro_historico;
create policy "quadro_historico: comentar" on public.quadro_historico
  for insert to authenticated with check (public.pode_quadro() and tipo in ('comentario', 'criado', 'editado') and autor = auth.jwt() ->> 'email');
drop policy if exists "quadro_historico: apagar o próprio comentário" on public.quadro_historico;
create policy "quadro_historico: apagar o próprio comentário" on public.quadro_historico
  for delete to authenticated using (public.pode_quadro() and tipo = 'comentario' and autor = auth.jwt() ->> 'email');

revoke all on public.quadro_colunas, public.quadro_etiquetas, public.quadro_cartoes, public.quadro_historico, public.quadro_comentarios from anon;
grant select, insert, update, delete on public.quadro_colunas, public.quadro_etiquetas, public.quadro_cartoes to authenticated;
grant select, insert, delete on public.quadro_historico to authenticated;
grant select on public.quadro_comentarios to authenticated;

-- Move o cartão (coluna e posição) e registra no histórico, numa operação só.
create or replace function public.quadro_mover(p_cartao uuid, p_coluna uuid, p_posicao double precision)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_de uuid;
begin
  if not public.pode_quadro() then
    raise exception 'Sem permissão';
  end if;
  select coluna_id into v_de from public.quadro_cartoes where id = p_cartao for update;
  if not found then
    raise exception 'Cartão não encontrado';
  end if;
  update public.quadro_cartoes
     set coluna_id = p_coluna, posicao = p_posicao, atualizado_em = now(),
         movido_em = case when v_de <> p_coluna then now() else movido_em end
   where id = p_cartao;
  if v_de <> p_coluna then
    insert into public.quadro_historico (cartao_id, tipo, de_coluna, para_coluna, autor)
    select p_cartao, 'movido', (select nome from public.quadro_colunas where id = v_de), (select nome from public.quadro_colunas where id = p_coluna), auth.jwt() ->> 'email';
  end if;
end;
$$;

revoke execute on function public.quadro_mover(uuid, uuid, double precision) from public, anon;
grant execute on function public.quadro_mover(uuid, uuid, double precision) to authenticated;

-- Locação nova na planilha => cartão novo na coluna de entrada, com o modelo de descrição do Trello já preenchido.
-- Se já existir um cartão com a mesma REF sem locação ligada (criado nos últimos 120 dias), liga nele em vez de criar outro.
create or replace function public.quadro_cartao_da_locacao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cartao uuid;
  v_coluna uuid;
  v_garantia text;
begin
  select id into v_cartao from public.quadro_cartoes
   where locacao_id is null and upper(referencia) = upper(new.referencia) and criado_em > now() - interval '120 days'
   order by criado_em desc limit 1;
  if v_cartao is not null then
    update public.quadro_cartoes set locacao_id = new.id, atualizado_em = now() where id = v_cartao;
    return new;
  end if;
  select id into v_coluna from public.quadro_colunas order by entrada desc, posicao limit 1;
  if v_coluna is null then
    return new;
  end if;
  v_garantia := coalesce(new.garantia, '');
  insert into public.quadro_cartoes (coluna_id, posicao, titulo, referencia, descricao, locacao_id, criado_por)
  values (v_coluna,
          coalesce((select min(posicao) from public.quadro_cartoes where coluna_id = v_coluna), 65536) - 1024,
          upper(new.referencia) || ' - ' || new.proponente || ' - ',
          upper(new.referencia),
          'Aluguel: R$ ' || translate(to_char(new.vgl, 'FM999,999,990.00'), ',.', '.,') || E'\nEntrada:\nVencimento:\n\nGarantia: ' || v_garantia ||
          E'\n**LIXO:**\n**SEGURO INCENDIO**\n**CHAVES:**\n**SINDICO:**\n**UC:**\n**ÁGUA:**\n**VISTORIA:**\n\nMORADORES:\n\n_CORRETORA: ' || new.corretora ||
          E'_\nCAPTADORA: ' || coalesce(new.captadora, '') || E'\n\n**FECHADO DIA: ' || to_char(new.data, 'DD/MM/YYYY') || E'**\n\n_**INFORMAÇÕES KENLO IMOB]**_',
          new.id, coalesce(auth.jwt() ->> 'email', new.criado_por))
  returning id into v_cartao;
  insert into public.quadro_historico (cartao_id, tipo, para_coluna, texto, autor)
  values (v_cartao, 'criado', (select nome from public.quadro_colunas where id = v_coluna), 'Criado a partir da planilha de locações', coalesce(auth.jwt() ->> 'email', new.criado_por));
  return new;
end;
$$;

drop trigger if exists locacoes_cria_cartao on public.locacoes;
create trigger locacoes_cria_cartao after insert on public.locacoes
  for each row execute function public.quadro_cartao_da_locacao();

-- Locação excluída da planilha => o cartão criado por ela sai do quadro (com o histórico).
-- Cartões importados do Trello (trello_id preenchido) só se desligam da planilha (on delete set null), para não perder o histórico antigo.
create or replace function public.quadro_exclui_cartao_da_locacao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.quadro_cartoes where locacao_id = old.id and trello_id is null;
  return old;
end;
$$;

drop trigger if exists locacoes_exclui_cartao on public.locacoes;
create trigger locacoes_exclui_cartao before delete on public.locacoes
  for each row execute function public.quadro_exclui_cartao_da_locacao();
