-- Aviso de caução para a Gestão Financeira / RH (10/11/2026, pedido da gerência).
-- Quando um cartão do quadro Saídas e distratos com a etiqueta CAUÇÃO (saidas_etiquetas.avisa_caucao) chega à coluna de
-- avisos de saída (saidas_colunas.aviso_captacao) ou a qualquer etapa seguinte, até antes da coluna de devoluções (a que já
-- aparece no painel, saidas_colunas.painel = 'financeiro-rh'), nasce um aviso no painel da Gestão Financeira / RH,
-- aba "Devoluções e pagamentos". Vale também quando a etiqueta é posta depois. Uma vez por cartão.
-- Ela marca "Ciente". O aviso e o "ciente" ficam no histórico do cartão. Nada é enviado por e-mail.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de saidas.sql, captacao_avisos.sql e saidas_paineis.sql.

alter table public.saidas_etiquetas add column if not exists avisa_caucao boolean not null default false;
update public.saidas_etiquetas set avisa_caucao = true where nome = 'CAUÇÃO' and grupo = 'Garantia';

create table if not exists public.saidas_caucao (
  id uuid primary key default gen_random_uuid(),
  cartao_id uuid not null unique references public.saidas_cartoes (id) on delete cascade,
  criado_em timestamptz not null default now(),
  ciente_em timestamptz,
  ciente_por text
);

alter table public.saidas_caucao enable row level security;
drop policy if exists "saidas_caucao: leitura" on public.saidas_caucao;
create policy "saidas_caucao: leitura" on public.saidas_caucao
  for select to authenticated using ((select public.pode_departamento('financeiro-rh')) or (select public.pode_saidas()));
revoke all on public.saidas_caucao from anon;
grant select on public.saidas_caucao to authenticated;

-- O cartão está "em saída" para o aviso: da coluna de avisos até antes da coluna de devoluções.
create or replace function public.saidas_em_saida(p_coluna uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.saidas_colunas c
     where c.id = p_coluna and not c.arquivada
       and c.posicao >= (select min(posicao) from public.saidas_colunas where aviso_captacao and not arquivada)
       and c.posicao < coalesce((select min(posicao) from public.saidas_colunas where painel = 'financeiro-rh' and not arquivada), 'infinity'::float8)
  );
$$;

create or replace function public.saidas_aviso_caucao()
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
  if not exists (select 1 from public.saidas_etiquetas e where e.avisa_caucao and e.id = any(new.etiquetas)) then
    return new;
  end if;
  if not public.saidas_em_saida(new.coluna_id) then
    return new;
  end if;
  insert into public.saidas_caucao (cartao_id) values (new.id) on conflict (cartao_id) do nothing returning id into v_id;
  if v_id is not null then
    insert into public.saidas_historico (cartao_id, tipo, texto, autor)
    values (new.id, 'editado', 'avisou a Gestão Financeira: inquilino com caução em saída', coalesce(auth.jwt() ->> 'email', 'portal'));
  end if;
  return new;
end;
$$;

drop trigger if exists saidas_cartoes_aviso_caucao on public.saidas_cartoes;
create trigger saidas_cartoes_aviso_caucao after insert or update of coluna_id, etiquetas, arquivado on public.saidas_cartoes
  for each row execute function public.saidas_aviso_caucao();

-- Avisos para o painel: os que ainda não foram vistos e os vistos nos últimos 30 dias, com os dados atuais do cartão.
create or replace function public.saidas_caucoes_listar()
returns table (id uuid, cartao_id uuid, titulo text, referencia text, locatario text, locador text, coluna text, arquivado boolean,
               vistoria_data date, vistoria_hora time, chaves_em date, criado_em timestamptz, ciente_em timestamptz, ciente_por text)
language sql
stable
security definer
set search_path = public
as $$
  select a.id, k.id, k.titulo, k.referencia, k.locatario, k.locador, c.nome, k.arquivado,
         k.vistoria_data, k.vistoria_hora, k.chaves_em, a.criado_em, a.ciente_em, a.ciente_por
    from public.saidas_caucao a
    join public.saidas_cartoes k on k.id = a.cartao_id
    join public.saidas_colunas c on c.id = k.coluna_id
   where public.pode_departamento('financeiro-rh') and (a.ciente_em is null or a.ciente_em > now() - interval '30 days')
   order by a.ciente_em is not null, a.criado_em desc;
$$;

revoke execute on function public.saidas_caucoes_listar() from public, anon;
grant execute on function public.saidas_caucoes_listar() to authenticated;

-- "Ciente" (ou desfazer) e registro no histórico do cartão.
create or replace function public.saidas_caucao_ciente(p_id uuid, p_ciente boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cartao uuid;
begin
  if not public.pode_departamento('financeiro-rh') then
    raise exception 'Sem permissão';
  end if;
  update public.saidas_caucao
     set ciente_em = case when p_ciente then now() end,
         ciente_por = case when p_ciente then auth.jwt() ->> 'email' end
   where id = p_id
  returning cartao_id into v_cartao;
  if v_cartao is null then
    raise exception 'Aviso não encontrado';
  end if;
  insert into public.saidas_historico (cartao_id, tipo, texto, autor)
  values (v_cartao, 'editado',
          case when p_ciente then 'Gestão Financeira ciente da caução em saída' else 'Gestão Financeira desfez o "ciente" da caução' end,
          auth.jwt() ->> 'email');
end;
$$;

revoke execute on function public.saidas_caucao_ciente(uuid, boolean) from public, anon;
grant execute on function public.saidas_caucao_ciente(uuid, boolean) to authenticated;

-- Primeira carga (10/11/2026): os cartões com caução que já estavam na coluna de avisos viram os primeiros avisos.
with novos as (
  insert into public.saidas_caucao (cartao_id)
  select k.id from public.saidas_cartoes k
    join public.saidas_colunas c on c.id = k.coluna_id and c.aviso_captacao and not c.arquivada
   where not k.arquivado and exists (select 1 from public.saidas_etiquetas e where e.avisa_caucao and e.id = any(k.etiquetas))
  on conflict (cartao_id) do nothing
  returning cartao_id
)
insert into public.saidas_historico (cartao_id, tipo, texto, autor)
select cartao_id, 'editado', 'avisou a Gestão Financeira: inquilino com caução em saída', 'portal' from novos;
