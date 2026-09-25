-- Meu painel (página gerencia.html): exclusivo da gerência (e-mails da tabela "gestores").
-- Cruza os leads do atendimento (leads_diarios) e as análises da pré-análise (pre_analises) com os resultados
-- por corretor e semana: leads do próprio corretor, visitas, propostas, fechamentos e VGL.
-- Por enquanto os resultados são lançados pela gerência; no futuro propostas e VGL virão de outro departamento.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de avisos.sql, pre_analise.sql e atendimento.sql.

-- Uma linha por semana + corretor. "data" = primeiro dia da semana, "ate" = último dia
-- (semana de segunda a domingo, cortada na virada do mês, como no relatório: 01 a 06/09, 07 a 13/09...).
create table if not exists public.resultados_semanais (
  id uuid primary key default gen_random_uuid(),
  data date not null,
  ate date not null check (ate >= data and ate - data <= 6),
  unidade text not null references public.unidades (nome) on update cascade,
  corretora text not null references public.corretoras (nome) on update cascade,
  leads_corretor integer not null default 0 check (leads_corretor between 0 and 10000),
  visitas integer not null default 0 check (visitas between 0 and 10000),
  propostas integer not null default 0 check (propostas between 0 and 10000),
  fechamentos integer not null default 0 check (fechamentos between 0 and 10000),
  vgl numeric(12,2) not null default 0 check (vgl between 0 and 100000000),
  ordem smallint not null default 0,
  criado_em timestamptz not null default now(),
  criado_por text default (auth.jwt() ->> 'email'),
  unique (data, corretora)
);

create index if not exists resultados_semanais_data_idx on public.resultados_semanais (data);

alter table public.resultados_semanais enable row level security;

drop policy if exists "resultados_semanais: só gerência" on public.resultados_semanais;
create policy "resultados_semanais: só gerência" on public.resultados_semanais
  for all to authenticated using (public.is_gestor()) with check (public.is_gestor());

revoke all on public.resultados_semanais from anon;
grant select, insert, update, delete on public.resultados_semanais to authenticated;

-- Salva a semana inteira de uma vez: apaga o que havia na semana e grava as linhas novas.
-- p_linhas = [{"unidade": "ITAJAÍ", "corretora": "FRAN", "leads_corretor": 1, "visitas": 1, "propostas": 1, "fechamentos": 2, "vgl": 6000, "ordem": 0}, ...]
create or replace function public.resultados_salvar_semana(p_data date, p_ate date, p_linhas jsonb, p_data_anterior date default null)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not public.is_gestor() then
    raise exception 'Sem permissão';
  end if;
  delete from public.resultados_semanais where data = p_data or data = p_data_anterior;
  insert into public.resultados_semanais (data, ate, unidade, corretora, leads_corretor, visitas, propostas, fechamentos, vgl, ordem)
  select p_data, p_ate, l.unidade, l.corretora, coalesce(l.leads_corretor, 0), coalesce(l.visitas, 0), coalesce(l.propostas, 0),
         coalesce(l.fechamentos, 0), coalesce(l.vgl, 0), coalesce(l.ordem, 0)
    from jsonb_to_recordset(p_linhas) as l(unidade text, corretora text, leads_corretor integer, visitas integer, propostas integer,
                                           fechamentos integer, vgl numeric, ordem smallint);
end;
$$;

revoke execute on function public.resultados_salvar_semana(date, date, jsonb, date) from public, anon;
grant execute on function public.resultados_salvar_semana(date, date, jsonb, date) to authenticated;

-- Setembro/2026, do "Relatório Stefani" (planilha Google): semanas de 01 a 06, 07 a 13 e 14 a 20/09.
insert into public.resultados_semanais (data, ate, unidade, corretora, leads_corretor, visitas, propostas, fechamentos, vgl, ordem, criado_por)
select v.data::date, v.ate::date, v.unidade, v.corretora, v.lc, v.vis, v.prop, v.fech, v.vgl, v.ordem, 'gerencia@araujolocacao.com.br'
from (values
  ('2026-09-01', '2026-09-06', 'ITAJAÍ',     'FRAN',     1, 1, 1, 2,  6000, 0),
  ('2026-09-01', '2026-09-06', 'ITAJAÍ',     'MARIA',    2, 2, 1, 2,  3750, 1),
  ('2026-09-01', '2026-09-06', 'ITAJAÍ',     'NATHALIA', 2, 5, 2, 1,  1900, 2),
  ('2026-09-01', '2026-09-06', 'NAVEGANTES', 'SIMONE',   0, 0, 0, 0,     0, 3),
  ('2026-09-07', '2026-09-13', 'ITAJAÍ',     'FRAN',     1, 1, 1, 1,  2700, 0),
  ('2026-09-07', '2026-09-13', 'ITAJAÍ',     'MARIA',    0, 0, 0, 1,  2000, 1),
  ('2026-09-07', '2026-09-13', 'ITAJAÍ',     'NATHALIA', 3, 0, 0, 0,     0, 2),
  ('2026-09-07', '2026-09-13', 'ITAJAÍ',     'THAYNA',   8, 0, 0, 0,     0, 3),
  ('2026-09-07', '2026-09-13', 'NAVEGANTES', 'ANA',      1, 1, 0, 0,     0, 4),
  ('2026-09-14', '2026-09-20', 'ITAJAÍ',     'FRAN',     1, 0, 1, 1,  1900, 0),
  ('2026-09-14', '2026-09-20', 'ITAJAÍ',     'MARIA',    5, 0, 2, 1, 11000, 1),
  ('2026-09-14', '2026-09-20', 'ITAJAÍ',     'NATHALIA', 0, 1, 1, 2,  4800, 2),
  ('2026-09-14', '2026-09-20', 'ITAJAÍ',     'THAYNA',   1, 3, 2, 1,  1200, 3),
  ('2026-09-14', '2026-09-20', 'NAVEGANTES', 'ANA',      0, 3, 2, 2,  4300, 4)
) as v(data, ate, unidade, corretora, lc, vis, prop, fech, vgl, ordem)
on conflict (data, corretora) do nothing;
