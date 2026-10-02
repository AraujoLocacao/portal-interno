-- Aba "RH" do departamento Gestão Financeira / RH (departamento.html?d=financeiro-rh): colaboradores com aniversário de vida
-- e de empresa. O cadastro é restrito a quem tem acesso ao departamento (gestores + departamento_acesso).
-- O portal (página inicial, sem login) mostra só os avisos: nome, tipo e dia, pela função aniversarios_portal.
-- O aniversário de vida guarda só dia e mês (sem o ano de nascimento).
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de supabase/departamentos.sql (pode_departamento).

create table if not exists public.rh_colaboradores (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (char_length(nome) between 1 and 80),
  funcao text check (char_length(funcao) <= 80),
  nascimento_dia smallint check (nascimento_dia between 1 and 31),
  nascimento_mes smallint check (nascimento_mes between 1 and 12),
  admissao date,
  ativo boolean not null default true,
  observacao text check (char_length(observacao) <= 500),
  criado_em timestamptz not null default now(),
  criado_por text default (auth.jwt() ->> 'email'),
  atualizado_em timestamptz not null default now(),
  atualizado_por text default (auth.jwt() ->> 'email'),
  constraint rh_nascimento_completo check ((nascimento_dia is null) = (nascimento_mes is null)),
  constraint rh_nascimento_valido check (nascimento_dia is null or nascimento_dia <=
    case when nascimento_mes = 2 then 29 when nascimento_mes in (4, 6, 9, 11) then 30 else 31 end)
);

create or replace function public.rh_tocar()
returns trigger language plpgsql as $$
begin
  new.atualizado_em := now();
  new.atualizado_por := auth.jwt() ->> 'email';
  return new;
end $$;

drop trigger if exists rh_colaboradores_tocar on public.rh_colaboradores;
create trigger rh_colaboradores_tocar before update on public.rh_colaboradores
  for each row execute function public.rh_tocar();

alter table public.rh_colaboradores enable row level security;

drop policy if exists "rh_colaboradores: departamento RH" on public.rh_colaboradores;
create policy "rh_colaboradores: departamento RH" on public.rh_colaboradores
  for all to authenticated
  using (public.pode_departamento('financeiro-rh'))
  with check (public.pode_departamento('financeiro-rh'));

revoke all on public.rh_colaboradores from anon;
grant select, insert, update, delete on public.rh_colaboradores to authenticated;

-- Próxima vez que um dia/mês acontece a partir de uma data (hoje inclusive). 29/02 vira 28/02 nos anos que não são bissextos.
create or replace function public.rh_proxima(p_dia int, p_mes int, p_base date)
returns date language plpgsql immutable as $$
declare
  ano int := extract(year from p_base);
  d date;
begin
  if p_dia is null or p_mes is null then return null; end if;
  for i in 0..1 loop
    d := make_date(ano + i, p_mes,
      least(p_dia, extract(day from (make_date(ano + i, p_mes, 1) + interval '1 month' - interval '1 day'))::int));
    if d >= p_base then return d; end if;
  end loop;
  return d;
end $$;

-- Avisos do portal: aniversários de vida e de empresa de hoje até p_dias à frente (horário de Brasília).
-- Aberta a todos (o portal não tem login): devolve só nome, tipo, dia e, no de empresa, quantos anos de casa.
create or replace function public.aniversarios_portal(p_dias int default 30)
returns table (nome text, tipo text, dia date, anos int)
language sql stable security definer set search_path = public as $$
  with hoje as (select (now() at time zone 'America/Sao_Paulo')::date as h),
  ev as (
    select c.nome, 'vida'::text as tipo, public.rh_proxima(c.nascimento_dia, c.nascimento_mes, hoje.h) as dia, null::int as anos
    from public.rh_colaboradores c, hoje
    where c.ativo and c.nascimento_dia is not null
    union all
    select c.nome, 'empresa', p.dia, (extract(year from p.dia) - extract(year from c.admissao))::int
    from public.rh_colaboradores c, hoje,
      lateral (select public.rh_proxima(extract(day from c.admissao)::int, extract(month from c.admissao)::int, hoje.h) as dia) p
    where c.ativo and c.admissao is not null
  )
  select ev.nome, ev.tipo, ev.dia, ev.anos from ev, hoje
  where ev.dia between hoje.h and hoje.h + least(greatest(coalesce(p_dias, 30), 0), 366)
    and (ev.anos is null or ev.anos >= 1)
  order by ev.dia, ev.tipo desc, ev.nome;
$$;

revoke all on function public.aniversarios_portal(int) from public;
grant execute on function public.aniversarios_portal(int) to anon, authenticated;
