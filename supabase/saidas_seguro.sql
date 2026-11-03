-- Cancelamento do seguro incêndio (03/11/2026, pedido da gerência).
-- Quando um cartão do quadro Saídas e distratos entra em "SAÍDAS PARA CÁLCULO - FINANCEIRO" (saidas_colunas.seguro_cancelar),
-- nasce um pedido que aparece no Contas a Pagar, junto da calculadora de rescisão. O financeiro abre o e-mail já pronto
-- para a corretora (Atlântico Seguros), com cópia para financeiro.locacao@ e financeiro.apagar@, envia pelo próprio
-- e-mail e marca "Enviado" (ou "Não se aplica"). O portal não envia e-mail sozinho. Tudo fica no histórico do cartão.
-- O cartão ganhou os campos endereço, locatário e locador (os nomes, se vazios, saem do título).
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de saidas.sql e captacao_avisos.sql (app.importando).

alter table public.saidas_cartoes add column if not exists endereco text check (char_length(endereco) <= 300);
alter table public.saidas_cartoes add column if not exists locatario text check (char_length(locatario) <= 200);
alter table public.saidas_cartoes add column if not exists locador text check (char_length(locador) <= 200);

alter table public.saidas_colunas add column if not exists seguro_cancelar boolean not null default false;
update public.saidas_colunas set seguro_cancelar = true where nome = 'SAÍDAS PARA CÁLCULO - FINANCEIRO' and not arquivada;

-- financeiro.locacao@ entra no Contas a Pagar (calculadora e pedidos de cancelamento), como o financeiro.apagar@.
insert into public.departamento_acesso (departamento, email)
select 'repasses', 'financeiro.locacao@araujolocacao.com.br'
 where not exists (select 1 from public.departamento_acesso where departamento = 'repasses' and lower(email) = 'financeiro.locacao@araujolocacao.com.br');

create table if not exists public.saidas_seguro (
  id uuid primary key default gen_random_uuid(),
  cartao_id uuid not null unique references public.saidas_cartoes (id) on delete cascade,
  criado_em timestamptz not null default now(),
  situacao text not null default 'pendente' check (situacao in ('pendente', 'enviado', 'nao_se_aplica')),
  resolvido_em timestamptz,
  resolvido_por text
);

alter table public.saidas_seguro enable row level security;
drop policy if exists "saidas_seguro: leitura" on public.saidas_seguro;
create policy "saidas_seguro: leitura" on public.saidas_seguro
  for select to authenticated using (public.pode_saidas() or public.pode_departamento('repasses'));
revoke all on public.saidas_seguro from anon;
grant select on public.saidas_seguro to authenticated;

-- Cartão entrou (criado ou movido) na coluna de cálculo => pedido de cancelamento do seguro, uma vez por cartão.
create or replace function public.saidas_pedido_seguro()
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
  if not exists (select 1 from public.saidas_colunas where id = new.coluna_id and seguro_cancelar) then
    return new;
  end if;
  insert into public.saidas_seguro (cartao_id) values (new.id) on conflict (cartao_id) do nothing returning id into v_id;
  if v_id is not null then
    insert into public.saidas_historico (cartao_id, tipo, texto, autor)
    values (new.id, 'editado', 'pediu ao financeiro o cancelamento do seguro incêndio', coalesce(auth.jwt() ->> 'email', 'portal'));
  end if;
  return new;
end;
$$;

drop trigger if exists saidas_cartoes_pedido_seguro on public.saidas_cartoes;
create trigger saidas_cartoes_pedido_seguro after insert or update of coluna_id on public.saidas_cartoes
  for each row execute function public.saidas_pedido_seguro();

-- Pedidos para o Contas a Pagar: pendentes e os resolvidos nos últimos 30 dias, com os dados atuais do cartão.
create or replace function public.saidas_seguros_listar()
returns table (id uuid, cartao_id uuid, titulo text, referencia text, endereco text, locatario text, locador text, coluna text,
               criado_em timestamptz, situacao text, resolvido_em timestamptz, resolvido_por text)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, k.id, k.titulo, k.referencia, k.endereco, k.locatario, k.locador, c.nome, s.criado_em, s.situacao, s.resolvido_em, s.resolvido_por
    from public.saidas_seguro s
    join public.saidas_cartoes k on k.id = s.cartao_id
    join public.saidas_colunas c on c.id = k.coluna_id
   where public.pode_departamento('repasses') and (s.situacao = 'pendente' or s.resolvido_em > now() - interval '30 days')
   order by s.situacao <> 'pendente', s.criado_em;
$$;

revoke execute on function public.saidas_seguros_listar() from public, anon;
grant execute on function public.saidas_seguros_listar() to authenticated;

-- Marca o pedido como enviado à corretora (ou "não se aplica") e registra no histórico do cartão.
create or replace function public.saidas_seguro_resolver(p_id uuid, p_situacao text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cartao uuid;
begin
  if not public.pode_departamento('repasses') then
    raise exception 'Sem permissão';
  end if;
  if p_situacao not in ('enviado', 'nao_se_aplica', 'pendente') then
    raise exception 'Situação inválida';
  end if;
  update public.saidas_seguro
     set situacao = p_situacao,
         resolvido_em = case when p_situacao = 'pendente' then null else now() end,
         resolvido_por = case when p_situacao = 'pendente' then null else auth.jwt() ->> 'email' end
   where id = p_id
  returning cartao_id into v_cartao;
  if v_cartao is null then
    raise exception 'Pedido não encontrado';
  end if;
  insert into public.saidas_historico (cartao_id, tipo, texto, autor)
  values (v_cartao, 'editado',
          case p_situacao when 'enviado' then 'enviou à corretora o pedido de cancelamento do seguro incêndio'
                          when 'nao_se_aplica' then 'marcou que o cancelamento do seguro incêndio não se aplica'
                          else 'reabriu o pedido de cancelamento do seguro incêndio' end,
          auth.jwt() ->> 'email');
end;
$$;

revoke execute on function public.saidas_seguro_resolver(uuid, text) from public, anon;
grant execute on function public.saidas_seguro_resolver(uuid, text) to authenticated;
