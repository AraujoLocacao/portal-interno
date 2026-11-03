-- Colunas do quadro Saídas e distratos que aparecem no painel de um departamento (03/11/2026).
-- "DISTRATOS COM DEVOLUÇÃO DE CAUÇÃO E/ OU PAGAMENTO" aparece na Gestão Financeira / RH (aba "Devoluções e pagamentos").
-- É uma vista do quadro: o cartão sai do painel quando sai da coluna. Nada é copiado.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de saidas.sql e acesso_geral.sql.

alter table public.saidas_colunas add column if not exists painel text;
update public.saidas_colunas set painel = 'financeiro-rh'
 where nome in ('DISTRATOS COM DEVOLUÇÃO DE CAUÇÃO E/ OU PAGAMENTO - atualizado', 'DISTRATOS COM DEVOLUÇÃO DE CAUÇÃO E/OU PAGAMENTO') and not arquivada;

create or replace function public.saidas_painel(p_departamento text)
returns table (id uuid, titulo text, referencia text, coluna text, movido_em timestamptz, prazo timestamptz, prazo_ok boolean,
               etiquetas text[], descricao text, comentarios int)
language sql
stable
security definer
set search_path = public
as $$
  select k.id, k.titulo, k.referencia, c.nome, k.movido_em, k.prazo, k.prazo_ok,
         coalesce((select array_agg(e.nome order by e.nome) from public.saidas_etiquetas e where e.id = any(k.etiquetas) and e.nome <> ''), '{}'),
         k.descricao, (select count(*)::int from public.saidas_historico h where h.cartao_id = k.id and h.tipo = 'comentario')
    from public.saidas_cartoes k
    join public.saidas_colunas c on c.id = k.coluna_id and c.painel = p_departamento and not c.arquivada
   where not k.arquivado and public.pode_departamento(p_departamento)
   order by k.movido_em;
$$;

revoke execute on function public.saidas_painel(text) from public, anon;
grant execute on function public.saidas_painel(text) to authenticated;
