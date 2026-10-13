-- Fechamento do mês da Locação (locacao.html): todo dia 10 fecha-se o mês anterior (10/10 fecha setembro)
-- e só contam os contratos assinados. O contrato que ainda não foi assinado passa sozinho para o dia 01 do mês
-- seguinte (o mês que ainda está aberto) e entra no fechamento em que já estiver assinado.
-- A coluna data_original guarda a data em que ele foi lançado (a página mostra "veio de setembro"; o Meu painel da
-- gerência continua contando o fechamento na semana original).
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de locacao.sql.

alter table public.locacoes add column if not exists data_original date;

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
  return v_movidas;
end;
$$;

revoke execute on function public.locacao_fechamento() from public, anon, authenticated;

-- Todo dia 10 às 00h05 (horário de Brasília = 03h05 UTC).
create extension if not exists pg_cron;
select cron.schedule('locacao-fechamento-dia-10', '5 3 10 * *', 'select public.locacao_fechamento()');
