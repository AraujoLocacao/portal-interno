-- Acesso geral: e-mails que entram em todos os departamentos e funções (Pré-análise, Atendimento, Locação, Quadro,
-- Captação com todos os quadros e os departamentos da página departamento.html), sem serem gestores:
-- não entram no Meu painel da gerência nem publicam avisos no mural.
-- Liberado em 02/10/2026 para financeiro@ e supervisora@ (pedido da gerência).
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de avisos.sql, pre_analise.sql, atendimento.sql,
-- locacao.sql, departamentos.sql e captacao.sql (as funções abaixo substituem as de lá, com o acesso geral a mais).

create table if not exists public.acesso_geral (
  email text primary key
);

alter table public.acesso_geral enable row level security;
-- Sem policies: a lista não é exposta pela API.
revoke all on public.acesso_geral from anon, authenticated;

create or replace function public.tem_acesso_geral()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.acesso_geral
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

grant execute on function public.tem_acesso_geral() to anon, authenticated;

create or replace function public.pode_pre_analise()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_gestor() or public.tem_acesso_geral() or exists (
    select 1 from public.pre_analise_acesso
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

create or replace function public.pode_atendimento()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_gestor() or public.tem_acesso_geral() or exists (
    select 1 from public.atendimento_acesso
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

-- O quadro de contratos (pode_quadro) vem junto: ele usa pode_locacao ou pode_pre_analise.
create or replace function public.pode_locacao()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_gestor() or public.tem_acesso_geral() or exists (
    select 1 from public.locacao_acesso
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

-- Captação: o acesso geral abre todos os quadros ativos das captadoras (o modelo e a criação de quadros seguem só da gerência).
create or replace function public.pode_captacao_quadro(p_quadro uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_gestor() or exists (
    select 1 from public.captacao_quadros
    where id = p_quadro and not modelo and ativo
      and (public.tem_acesso_geral() or lower(email) = lower(coalesce(auth.jwt() ->> 'email', '')))
  );
$$;

create or replace function public.pode_captacao()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_gestor() or public.tem_acesso_geral() or exists (
    select 1 from public.captacao_quadros
    where not modelo and ativo and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

create or replace function public.pode_departamento(p_departamento text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_gestor() or public.tem_acesso_geral() or exists (
    select 1 from public.departamento_acesso
    where departamento = p_departamento
      and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  ) or (p_departamento = 'captacao' and public.pode_captacao());
$$;

insert into public.acesso_geral (email) values
  ('financeiro@araujolocacao.com.br'),
  ('supervisora@araujolocacao.com.br')
on conflict (email) do nothing;
