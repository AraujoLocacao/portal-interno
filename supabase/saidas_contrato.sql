-- Contrato do imóvel no cartão de saída (03/11/2026, pedido da gerência). Liga o cartão do quadro Saídas e distratos aos
-- cartões do Quadro de contratos com a mesma referência (sem o /n). É uma consulta ao vivo, nada é copiado: os valores do
-- início da locação podem ter mudado (reajustes, aditivos), e a tela avisa isso.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de saidas.sql, quadro.sql e locacao.sql.

create or replace function public.saidas_contratos(p_cartao uuid)
returns table (id uuid, titulo text, coluna text, criado_em timestamptz, descricao text, mesmo_locatario boolean,
               data_locacao date, aluguel numeric, garantia text, corretora text, captadora text)
language sql
stable
security definer
set search_path = public
as $$
  select q.id, q.titulo, c.nome, q.criado_em, q.descricao,
         coalesce(nullif(k.locatario, ''), '') <> '' and position(upper(split_part(trim(k.locatario), ' ', 1)) in upper(q.titulo)) > 0,
         l.data, l.vgl, l.garantia, l.corretora, l.captadora
    from public.saidas_cartoes k
    join public.quadro_cartoes q on upper(q.referencia) = upper(split_part(k.referencia, '/', 1)) and not q.modelo
    join public.quadro_colunas c on c.id = q.coluna_id
    left join public.locacoes l on l.id = q.locacao_id
   where k.id = p_cartao and public.pode_saidas()
   order by 6 desc, q.criado_em desc;
$$;

revoke execute on function public.saidas_contratos(uuid) from public, anon;
grant execute on function public.saidas_contratos(uuid) to authenticated;

-- Rescisão ligada ao cartão de saída: o botão "Calcular rescisão" do cartão abre a calculadora do Contas a Pagar com o
-- locatário, o endereço e a entrega das chaves preenchidos; ao salvar, a rescisão guarda o cartão (saida_id) e o cartão
-- mostra a rescisão salva para quem tem acesso ao Contas a Pagar.
alter table public.dep_rescisoes add column if not exists saida_id uuid references public.saidas_cartoes (id) on delete set null;
create index if not exists dep_rescisoes_saida_idx on public.dep_rescisoes (saida_id);
