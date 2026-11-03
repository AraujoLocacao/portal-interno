-- Números da Pós-locação para o Meu painel da gerência (03/11/2026, pedido da gerência: área "Pós", como Captação e Locação).
-- Lê o quadro Saídas e distratos: histórico de colunas (inclusive o que veio do Trello) e os campos de data do cartão.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de saidas.sql e saidas_datas.sql.

create or replace function public.saidas_painel_gerencia(p_mes date)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with lim as (
    select date_trunc('month', p_mes)::date ini, (date_trunc('month', p_mes) + interval '1 month')::date fim
  ), aviso as (  -- primeira entrada de cada cartão em "AVISOS DE SAÍDA"
    select h.cartao_id, min(h.criado_em at time zone 'America/Sao_Paulo')::date dia
      from saidas_historico h
     where h.tipo in ('criado', 'movido') and h.para_coluna ilike 'AVISOS DE SA%'
     group by h.cartao_id
  ), concl as (  -- primeira entrada em "DISTRATOS CONCLUÍDOS"
    select h.cartao_id, min(h.criado_em at time zone 'America/Sao_Paulo')::date dia
      from saidas_historico h
     where h.tipo in ('criado', 'movido') and h.para_coluna ilike 'DISTRATOS CONCLU%'
     group by h.cartao_id
  ), meses as (
    select generate_series(date_trunc('month', p_mes) - interval '5 months', date_trunc('month', p_mes), interval '1 month')::date m
  )
  select case when not public.is_gestor() then null else jsonb_build_object(
    'avisos', (select count(*) from aviso, lim where dia >= ini and dia < fim),
    'vistorias_feitas', (select count(*) from saidas_cartoes k, lim where vistoria_data >= ini and vistoria_data < fim and vistoria_data <= current_date),
    'vistorias_agendadas', (select count(*) from saidas_cartoes k, lim where not k.arquivado and vistoria_data >= greatest(ini, current_date + 1) and vistoria_data < fim),
    'chaves', (select count(*) from saidas_cartoes k, lim where chaves_em >= ini and chaves_em < fim),
    'concluidos', (select count(*) from concl, lim where dia >= ini and dia < fim),
    'tempo_medio', (select round(avg(k.chaves_em - a.dia)) from saidas_cartoes k join aviso a on a.cartao_id = k.id, lim
                     where k.chaves_em >= ini and k.chaves_em < fim and k.chaves_em between a.dia and a.dia + 365),
    'em_cobranca', (select count(*) from saidas_cartoes k join saidas_colunas c on c.id = k.coluna_id
                     where not k.arquivado and not c.arquivada and (c.nome ilike 'DISTRATOS EM COBRANÇA%' or c.nome ilike 'AGUARDANDO PAGAMENTO%'
                       or c.nome ilike 'ACORDOS DE PARCELAMENTO%' or c.nome ilike 'ACIONADO%' or c.nome ilike 'ONDA SEGURA%')),
    'na_justica', (select count(*) from saidas_cartoes k join saidas_colunas c on c.id = k.coluna_id
                    where not k.arquivado and c.nome ilike 'COBRANÇA JUDICIAL%'),
    'etapas', (select jsonb_agg(jsonb_build_object('coluna', c.nome, 'n', (select count(*) from saidas_cartoes k where k.coluna_id = c.id and not k.arquivado)) order by c.posicao)
                 from saidas_colunas c where not c.arquivada),
    'meses', (select jsonb_agg(jsonb_build_object('mes', to_char(m, 'YYYY-MM'),
                 'avisos', (select count(*) from aviso where dia >= m and dia < (m + interval '1 month')::date),
                 'chaves', (select count(*) from saidas_cartoes where chaves_em >= m and chaves_em < (m + interval '1 month')::date),
                 'concluidos', (select count(*) from concl where dia >= m and dia < (m + interval '1 month')::date)) order by m) from meses)
  ) end;
$$;

revoke execute on function public.saidas_painel_gerencia(date) from public, anon;
grant execute on function public.saidas_painel_gerencia(date) to authenticated;
