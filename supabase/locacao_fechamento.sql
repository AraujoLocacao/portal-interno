-- Fechamento do mês da Locação (locacao.html): todo dia 10 fecha-se o mês anterior (10/10 fecha setembro)
-- e só contam os contratos assinados. O ranking do mês fechado vai para o RH (tabela locacao_fechamentos). O contrato que ainda não foi assinado passa sozinho para o dia 01 do mês
-- seguinte (o mês que ainda está aberto) e entra no fechamento em que já estiver assinado.
-- A coluna data_original guarda a data em que ele foi lançado (a página mostra "veio de setembro"; o Meu painel da
-- gerência continua contando o fechamento na semana original).
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de locacao.sql.

alter table public.locacoes add column if not exists data_original date;

-- ---------- Ranking enviado ao RH ----------
-- No dia 10, o ranking do mês fechado (só assinados) é gravado aqui e aparece para o RH em
-- departamento.html?d=financeiro-rh, aba "Fechamento da Locação". Fica congelado como estava no dia 10.
create table if not exists public.locacao_fechamentos (
  mes date primary key check (extract(day from mes) = 1),
  fechado_em timestamptz not null default now(),
  ranking jsonb not null default '[]'::jsonb, -- [{corretora, locacoes, vgl, ajuda, bonificacao, bonificacao_digitada}]
  total_vgl numeric(14,2) not null default 0,
  total_ajuda numeric(14,2) not null default 0,
  total_bonificacao numeric(14,2) not null default 0
);

alter table public.locacao_fechamentos enable row level security;

drop policy if exists "locacao_fechamentos: leitura" on public.locacao_fechamentos;
create policy "locacao_fechamentos: leitura" on public.locacao_fechamentos
  for select to authenticated using (public.pode_locacao() or public.pode_departamento('financeiro-rh'));

revoke all on public.locacao_fechamentos from anon, authenticated;
grant select on public.locacao_fechamentos to authenticated;

-- Mesma tabela do ranking do locacao.html (tabelaMes): até 19.999, ajuda de 10% limitada a R$ 2.000; de 20.000, + R$ 500
-- de bonificação; de 30.000, + R$ 1.000; a partir de 40.000, ajuda de R$ 5.000 e sem bonificação.
-- A bonificação digitada no mês (locacao_bonificacoes) vale no lugar da tabela.
create or replace function public.locacao_fechamento_ranking(p_mes date)
returns void
language sql
set search_path = public
as $$
  with v as (
    select corretora, count(*) as n, sum(vgl) as vgl
      from public.locacoes
     where assinado and data >= p_mes and data < (p_mes + interval '1 month')
     group by 1
  ),
  r as (
    select corretora, coalesce(v.n, 0) as n, coalesce(v.vgl, 0) as vgl, b.valor as digitada
      from v full join (select corretora, valor from public.locacao_bonificacoes where mes = p_mes) b using (corretora)
  ),
  c as (
    select corretora, n, vgl, digitada is not null as digitada,
           case when vgl >= 40000 then 5000 else least(vgl * 0.10, 2000) end as ajuda,
           coalesce(digitada, case when vgl >= 40000 then 0 when vgl >= 30000 then 1000 when vgl >= 20000 then 500 else 0 end) as bonificacao
      from r
  )
  insert into public.locacao_fechamentos (mes, fechado_em, ranking, total_vgl, total_ajuda, total_bonificacao)
  select p_mes, now(),
         coalesce(jsonb_agg(jsonb_build_object('corretora', corretora, 'locacoes', n, 'vgl', vgl, 'ajuda', round(ajuda, 2),
                  'bonificacao', bonificacao, 'bonificacao_digitada', digitada) order by vgl desc, corretora), '[]'::jsonb),
         coalesce(sum(vgl), 0), coalesce(round(sum(ajuda), 2), 0), coalesce(sum(bonificacao), 0)
    from c
  on conflict (mes) do update
     set fechado_em = excluded.fechado_em, ranking = excluded.ranking, total_vgl = excluded.total_vgl,
         total_ajuda = excluded.total_ajuda, total_bonificacao = excluded.total_bonificacao;
$$;

revoke execute on function public.locacao_fechamento_ranking(date) from public, anon, authenticated;

create or replace function public.locacao_fechamento()
returns integer
language plpgsql
set search_path = public
as $$
declare
  v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  v_aberto date := date_trunc('month', v_hoje)::date; -- o mês atual, que continua aberto
  v_movidas integer;
begin
  -- O fechamento é só no dia 10: em qualquer outro dia não move nada.
  if extract(day from v_hoje) <> 10 then
    return 0;
  end if;
  update public.locacoes
     set data_original = coalesce(data_original, data), data = v_aberto
   where not assinado and data < v_aberto;
  get diagnostics v_movidas = row_count;
  -- Depois de mover os não assinados, grava o ranking do mês que fechou (o anterior) para o RH.
  perform public.locacao_fechamento_ranking((v_aberto - interval '1 month')::date);
  return v_movidas;
end;
$$;

revoke execute on function public.locacao_fechamento() from public, anon, authenticated;

-- Todo dia 10 às 00h05 (horário de Brasília = 03h05 UTC).
create extension if not exists pg_cron;
select cron.schedule('locacao-fechamento-dia-10', '5 3 10 * *', 'select public.locacao_fechamento()');
