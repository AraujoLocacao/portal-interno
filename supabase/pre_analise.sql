-- Controle de pré-análise (página pre-analise.html).
-- Tudo restrito: só gestores (tabela "gestores") e os e-mails da tabela "pre_analise_acesso" leem e gravam.
-- Os dados dos clientes ficam só aqui no banco, nunca no repositório (que é público).
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de supabase/avisos.sql.

create table if not exists public.pre_analise_acesso (
  email text primary key
);

alter table public.pre_analise_acesso enable row level security;
-- Sem policies: a lista de acessos não é exposta pela API.

create or replace function public.pode_pre_analise()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_gestor() or exists (
    select 1 from public.pre_analise_acesso
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

grant execute on function public.pode_pre_analise() to anon, authenticated;

-- Corretoras e garantias ficam em tabelas próprias para poder cruzar depois com leads, visitas, fechamentos e VGL.
create table if not exists public.corretoras (
  nome text primary key check (char_length(nome) between 1 and 40),
  ativa boolean not null default true
);

create table if not exists public.garantias (
  nome text primary key check (char_length(nome) between 1 and 40),
  ativa boolean not null default true
);

create table if not exists public.pre_analises (
  id uuid primary key default gen_random_uuid(),
  data date not null default current_date,
  corretora text references public.corretoras (nome) on update cascade,
  cliente text not null check (char_length(cliente) between 1 and 200),
  referencia text check (char_length(referencia) <= 20),
  situacao text not null check (situacao in ('APROVADO', 'RECUSADO', 'EM ANÁLISE')),
  garantias text[] not null default '{}',
  observacao text check (char_length(observacao) <= 500),
  criado_em timestamptz not null default now(),
  criado_por text default (auth.jwt() ->> 'email')
);

create index if not exists pre_analises_data_idx on public.pre_analises (data);
create index if not exists pre_analises_corretora_idx on public.pre_analises (corretora);

alter table public.corretoras enable row level security;
alter table public.garantias enable row level security;
alter table public.pre_analises enable row level security;

drop policy if exists "corretoras: acesso pré-análise" on public.corretoras;
create policy "corretoras: acesso pré-análise" on public.corretoras
  for all to authenticated using (public.pode_pre_analise()) with check (public.pode_pre_analise());

drop policy if exists "garantias: acesso pré-análise" on public.garantias;
create policy "garantias: acesso pré-análise" on public.garantias
  for all to authenticated using (public.pode_pre_analise()) with check (public.pode_pre_analise());

drop policy if exists "pre_analises: acesso pré-análise" on public.pre_analises;
create policy "pre_analises: acesso pré-análise" on public.pre_analises
  for all to authenticated using (public.pode_pre_analise()) with check (public.pode_pre_analise());

revoke all on public.pre_analise_acesso, public.corretoras, public.garantias, public.pre_analises from anon;
grant select, insert, update on public.corretoras, public.garantias to authenticated;
grant select, insert, update, delete on public.pre_analises to authenticated;

insert into public.corretoras (nome) values
  ('ANA'), ('FRAN'), ('MARIA'), ('NATHALIA'), ('SIMONE'), ('THAYNA')
on conflict do nothing;

insert into public.garantias (nome) values
  ('LOFT'), ('CREDALUGA'), ('POTTENCIAL'), ('PORTO'), ('ALPOP'), ('SEU FIADOR'), ('CAUÇÃO')
on conflict do nothing;
