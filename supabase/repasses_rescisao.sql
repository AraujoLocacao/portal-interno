-- Proprietário · Repasses: calculadora de rescisão (28/09/2026).
-- O código da calculadora fica no bucket privado "departamentos", em ferramentas/repasses/calculadora-rescisao.html
-- (fora do site público). A página departamento.html?d=repasses baixa o arquivo depois do login e abre num iframe isolado.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de supabase/departamentos.sql.

-- Leitura da pasta ferramentas/<departamento>/ para quem tem acesso ao departamento.
-- Enviar e trocar o arquivo: só a gerência ("ferramentas" não é departamento, então ninguém mais passa nas outras regras).
drop policy if exists "departamentos: ler ferramentas" on storage.objects;
create policy "departamentos: ler ferramentas" on storage.objects
  for select to authenticated using (bucket_id = 'departamentos' and (storage.foldername(name))[1] = 'ferramentas' and public.pode_departamento((storage.foldername(name))[2]));

-- Quem usa a calculadora (além da gerência).
insert into public.departamento_acesso (email, departamento) values
  ('financeiro@araujolocacao.com.br', 'repasses'),
  ('supervisora@araujolocacao.com.br', 'repasses')
on conflict do nothing;

-- ---------- Rescisões salvas (28/09/2026) ----------
-- O botão "Salvar rescisão" da calculadora grava aqui tudo o que foi preenchido (estado, em JSON). Os anexos não são salvos.
-- As colunas locatario, imovel, entrega_chaves e saldo (negativo = a devolver) servem só para a lista.
create table if not exists public.dep_rescisoes (
  id uuid primary key default gen_random_uuid(),
  departamento text not null references public.departamentos (slug) on update cascade,
  locatario text check (char_length(locatario) <= 200),
  imovel text check (char_length(imovel) <= 300),
  entrega_chaves date,
  saldo numeric(14, 2),
  estado jsonb not null,
  criado_em timestamptz not null default now(),
  criado_por text default (auth.jwt() ->> 'email'),
  atualizado_em timestamptz not null default now(),
  atualizado_por text default (auth.jwt() ->> 'email'),
  check (octet_length(estado::text) < 2000000)
);

create index if not exists dep_rescisoes_departamento_idx on public.dep_rescisoes (departamento, atualizado_em desc);

create or replace function public.dep_rescisoes_atualizado()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.atualizado_em := now();
  new.atualizado_por := auth.jwt() ->> 'email';
  new.criado_em := old.criado_em;
  new.criado_por := old.criado_por;
  return new;
end;
$$;

drop trigger if exists dep_rescisoes_atualizado on public.dep_rescisoes;
create trigger dep_rescisoes_atualizado before update on public.dep_rescisoes
  for each row execute function public.dep_rescisoes_atualizado();

alter table public.dep_rescisoes enable row level security;

drop policy if exists "dep_rescisoes: acesso do departamento" on public.dep_rescisoes;
create policy "dep_rescisoes: acesso do departamento" on public.dep_rescisoes
  for all to authenticated using (public.pode_departamento(departamento)) with check (public.pode_departamento(departamento));

revoke all on public.dep_rescisoes from anon;
grant select, insert, update, delete on public.dep_rescisoes to authenticated;
