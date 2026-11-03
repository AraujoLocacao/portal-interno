-- Avisos de saída para a Captação (03/11/2026, pedido da gerência).
-- Quando um cartão entra na coluna de aviso de saída do quadro Saídas e distratos (saidas_colunas.aviso_captacao,
-- hoje "AVISOS DE SAÍDA - PÓS LOCAÇÃO"), nasce um aviso na aba "Avisos de saída" da Captação. Todas as captadoras veem;
-- a primeira que clicar em "Pegar" recebe o cartão no próprio quadro (primeira coluna, etiqueta PÓS e a da cidade).
-- O quadro de saídas registra no histórico o envio e quem pegou. A importação do Trello não gera avisos (app.importando).
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de saidas.sql e captacao.sql.

alter table public.saidas_colunas add column if not exists aviso_captacao boolean not null default false;
update public.saidas_colunas set aviso_captacao = true where nome = 'AVISOS DE SAÍDA - PÓS LOCAÇÃO' and not arquivada;

create table if not exists public.captacao_avisos (
  id uuid primary key default gen_random_uuid(),
  saida_id uuid not null unique references public.saidas_cartoes (id) on delete cascade,
  criado_em timestamptz not null default now(),
  pego_quadro uuid references public.captacao_quadros (id) on delete set null,
  pego_por text,
  pego_em timestamptz,
  cartao_id uuid references public.captacao_cartoes (id) on delete set null
);

alter table public.captacao_avisos enable row level security;
-- Sem policies: a lista sai pela função captacao_avisos_listar (as captadoras não leem o quadro de saídas).
revoke all on public.captacao_avisos from anon, authenticated;

-- Cartão entrou (criado ou movido) na coluna de aviso de saída => aviso para a Captação, uma vez por cartão.
create or replace function public.saidas_aviso_captacao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if coalesce(current_setting('app.importando', true), '') = 'on' or new.arquivado then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.coluna_id = new.coluna_id then
    return new;
  end if;
  if not exists (select 1 from public.saidas_colunas where id = new.coluna_id and aviso_captacao) then
    return new;
  end if;
  insert into public.captacao_avisos (saida_id) values (new.id) on conflict (saida_id) do nothing returning id into v_id;
  if v_id is not null then
    insert into public.saidas_historico (cartao_id, tipo, texto, autor)
    values (new.id, 'editado', 'enviou o aviso de saída para a Captação', coalesce(auth.jwt() ->> 'email', 'portal'));
  end if;
  return new;
end;
$$;

drop trigger if exists saidas_cartoes_aviso_captacao on public.saidas_cartoes;
create trigger saidas_cartoes_aviso_captacao after insert or update of coluna_id on public.saidas_cartoes
  for each row execute function public.saidas_aviso_captacao();

-- Cidade pelas etiquetas do cartão de saídas (ITAJAÍ / NAVEGANTES).
create or replace function public.saidas_cidade(p_etiquetas uuid[])
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case when bool_or(upper(nome) = 'NAVEGANTES') then 'NAVEGANTES' when bool_or(upper(nome) = 'ITAJAÍ') then 'ITAJAÍ' end
    from public.saidas_etiquetas where id = any(p_etiquetas);
$$;

revoke execute on function public.saidas_cidade(uuid[]) from public, anon;

-- Avisos em aberto e os pegos nos últimos 30 dias, com os dados atuais do cartão de saídas.
create or replace function public.captacao_avisos_listar()
returns table (id uuid, referencia text, titulo text, descricao text, cidade text, aviso_em text, criado_em timestamptz,
               pego_por text, pego_em timestamptz, coluna text)
language sql
stable
security definer
set search_path = public
as $$
  select a.id, k.referencia, k.titulo, k.descricao, public.saidas_cidade(k.etiquetas),
         substring(k.descricao from '(?i)aviso de sa[ií]da:?\**\s*(\d{1,2}/\d{1,2}/\d{2,4})'),
         a.criado_em, coalesce(q.nome, a.pego_por), a.pego_em, c.nome
    from public.captacao_avisos a
    join public.saidas_cartoes k on k.id = a.saida_id
    join public.saidas_colunas c on c.id = k.coluna_id
    left join public.captacao_quadros q on q.id = a.pego_quadro
   where public.pode_captacao() and (a.pego_em is null or a.pego_em > now() - interval '30 days')
   order by a.pego_em is not null, a.criado_em desc;
$$;

revoke execute on function public.captacao_avisos_listar() from public, anon;
grant execute on function public.captacao_avisos_listar() to authenticated;

-- A captadora pega o aviso: vira cartão na primeira coluna do quadro dela. Só uma pega (trava a linha).
create or replace function public.captacao_pegar_aviso(p_aviso uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_q public.captacao_quadros;
  v_a public.captacao_avisos;
  v_s public.saidas_cartoes;
  v_col uuid;
  v_colnome text;
  v_cidade text;
  v_etq uuid[];
  v_cartao uuid;
begin
  select * into v_q from public.captacao_quadros where not modelo and ativo and lower(email) = v_email order by posicao limit 1;
  if v_q.id is null then
    raise exception 'Só as captadoras com quadro podem pegar o aviso';
  end if;
  select * into v_a from public.captacao_avisos where id = p_aviso for update;
  if v_a.id is null then
    raise exception 'Aviso não encontrado';
  end if;
  if v_a.pego_em is not null then
    raise exception 'Este aviso já foi pego por %', coalesce((select nome from public.captacao_quadros where id = v_a.pego_quadro), v_a.pego_por);
  end if;
  select * into v_s from public.saidas_cartoes where id = v_a.saida_id;
  select id, nome into v_col, v_colnome from public.captacao_colunas where quadro_id = v_q.id order by posicao limit 1;
  if v_col is null then
    raise exception 'O seu quadro não tem colunas';
  end if;
  v_cidade := public.saidas_cidade(v_s.etiquetas);
  select coalesce(array_agg(id), '{}') into v_etq from public.captacao_etiquetas
   where quadro_id = v_q.id and (upper(nome) in ('PÓS', 'POS') or upper(nome) = v_cidade);
  insert into public.captacao_cartoes (quadro_id, coluna_id, posicao, titulo, referencia, descricao, etiquetas, criado_por)
  values (v_q.id, v_col,
          coalesce((select min(posicao) from public.captacao_cartoes where quadro_id = v_q.id and coluna_id = v_col), 65536) - 1024,
          left(v_s.titulo, 300), v_s.referencia,
          left('Aviso de saída da Pós-locação, enviado em ' || to_char(v_a.criado_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY') || E'.\n\n' || v_s.descricao, 20000),
          v_etq, v_email)
  returning id into v_cartao;
  insert into public.captacao_historico (cartao_id, tipo, para_coluna, texto, autor)
  values (v_cartao, 'criado', v_colnome, 'Aviso de saída da Pós-locação', v_email);
  update public.captacao_avisos set pego_quadro = v_q.id, pego_por = v_email, pego_em = now(), cartao_id = v_cartao where id = v_a.id;
  insert into public.saidas_historico (cartao_id, tipo, texto, autor)
  values (v_s.id, 'editado', 'pegou o aviso na Captação (quadro ' || v_q.nome || ')', v_email);
  return v_cartao;
end;
$$;

revoke execute on function public.captacao_pegar_aviso(uuid) from public, anon;
grant execute on function public.captacao_pegar_aviso(uuid) to authenticated;
