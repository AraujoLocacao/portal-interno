-- Apresentação do mês (gerencia.html, aba "Apresentação do mês"): os textos de cada mês (capa, economia, regra nova,
-- prioridades...), um registro por mês. Os números não ficam aqui: vêm sempre dos lançamentos, na hora de montar os slides.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de apresentacao.sql (is_gestor).
create table if not exists public.apresentacoes_mensais (
  mes date primary key check (extract(day from mes) = 1),
  conteudo jsonb not null default '{}',
  atualizado_em timestamptz not null default now(),
  atualizado_por text default (auth.jwt() ->> 'email')
);

alter table public.apresentacoes_mensais enable row level security;

drop policy if exists "apresentacoes_mensais: só gerência" on public.apresentacoes_mensais;
create policy "apresentacoes_mensais: só gerência" on public.apresentacoes_mensais
  for all to authenticated using (public.is_gestor()) with check (public.is_gestor());

revoke all on public.apresentacoes_mensais from anon;
grant select, insert, update, delete on public.apresentacoes_mensais to authenticated;
