-- Possíveis clientes para a Captação (11/11/2026, pedido da gerência).
-- Anúncios de aluguel feitos pelo próprio dono (OLX e Eemovel), em Itajaí e Navegantes, a partir de R$ 4.000.
-- A coleta roda numa tarefa agendada (possiveis-clientes-captacao, dias úteis às 12h, Claude in Chrome) e grava aqui
-- pela Management API (fora da API pública); os passos estão em automacoes/possiveis-clientes.
-- Antes de gravar, a coleta cruza com os imóveis do CRM Superlógica (todos os status): o que for o mesmo endereço
-- entra como 'nosso' e não aparece; o que for parecido (mesmo bairro e área ou valor perto) aparece com aviso.
-- Telefone do anunciante NÃO é coletado: a captadora abre o anúncio e fala pelo portal de origem.
-- Na aba "Possíveis clientes" da Captação, a primeira captadora que clicar em "Pegar" recebe o cartão no próprio quadro.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de captacao.sql.

create table if not exists public.captacao_possiveis (
  id uuid primary key default gen_random_uuid(),
  fonte text not null check (fonte in ('olx', 'eemovel')),
  fonte_id text not null,                 -- número do anúncio na OLX / chave do anúncio no Eemovel
  link text,
  titulo text not null default '',
  tipo text,                              -- casa, apartamento, comercial...
  valor numeric,
  condominio numeric,
  iptu numeric,
  cidade text,                            -- ITAJAÍ / NAVEGANTES
  bairro text,
  rua text,
  cep text,
  area numeric,
  quartos int,
  banheiros int,
  vagas int,
  anunciado_em date,
  encontrado_em timestamptz not null default now(),
  visto_em timestamptz not null default now(), -- última coleta em que o anúncio ainda estava no ar
  nosso_ref text,                         -- imóvel do CRM com o mesmo endereço (ou parecido)
  nosso_tipo text check (nosso_tipo in ('igual', 'parecido')),
  nosso_info text,
  situacao text not null default 'novo' check (situacao in ('novo', 'pego', 'descartado', 'nosso')),
  pego_quadro uuid references public.captacao_quadros (id) on delete set null,
  pego_por text,
  pego_em timestamptz,
  cartao_id uuid references public.captacao_cartoes (id) on delete set null,
  descartado_por text,
  descartado_em timestamptz,
  motivo text,
  unique (fonte, fonte_id)
);

-- Canal de contato do anúncio (pedido de 11/11/2026: só anúncio com contato). Ex.: "chat", "chat, telefone", "site".
-- Só o tipo de canal: o número do telefone NÃO é guardado. Anúncio sem nenhum canal não entra na lista.
alter table public.captacao_possiveis add column if not exists contato text;

create index if not exists captacao_possiveis_situacao_idx on public.captacao_possiveis (situacao, visto_em);

alter table public.captacao_possiveis enable row level security;
-- Sem policies: a tela usa as funções abaixo; a coleta grava como postgres pela Management API.
revoke all on public.captacao_possiveis from anon, authenticated;

-- Lista da aba: os novos ainda no ar (vistos nos últimos 4 dias) e com contato, e os pegos/descartados dos últimos 30 dias.
drop function if exists public.captacao_possiveis_listar();
create or replace function public.captacao_possiveis_listar()
returns table (id uuid, fonte text, link text, titulo text, tipo text, valor numeric, condominio numeric, iptu numeric,
               cidade text, bairro text, rua text, cep text, area numeric, quartos int, banheiros int, vagas int,
               anunciado_em date, encontrado_em timestamptz, visto_em timestamptz, nosso_ref text, nosso_tipo text,
               nosso_info text, situacao text, pego_por text, pego_em timestamptz, descartado_por text,
               descartado_em timestamptz, motivo text, contato text)
language sql
stable
security definer
set search_path = public
as $$
  select p.id, p.fonte, p.link, p.titulo, p.tipo, p.valor, p.condominio, p.iptu, p.cidade, p.bairro, p.rua, p.cep,
         p.area, p.quartos, p.banheiros, p.vagas, p.anunciado_em, p.encontrado_em, p.visto_em, p.nosso_ref, p.nosso_tipo,
         p.nosso_info, p.situacao, coalesce(q.nome, p.pego_por), p.pego_em, p.descartado_por, p.descartado_em, p.motivo, p.contato
    from public.captacao_possiveis p
    left join public.captacao_quadros q on q.id = p.pego_quadro
   where public.pode_captacao()
     and ((p.situacao = 'novo' and p.visto_em > now() - interval '4 days' and coalesce(p.contato, '') not in ('', 'nenhum'))
          or (p.situacao = 'pego' and p.pego_em > now() - interval '30 days')
          or (p.situacao = 'descartado' and p.descartado_em > now() - interval '30 days'))
   order by p.situacao <> 'novo', p.valor desc nulls last, p.encontrado_em desc;
$$;

revoke execute on function public.captacao_possiveis_listar() from public, anon;
grant execute on function public.captacao_possiveis_listar() to authenticated;

-- A captadora pega: vira cartão na primeira coluna do quadro dela, com a etiqueta da cidade. Só uma pega (trava a linha).
create or replace function public.captacao_pegar_possivel(p_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_q public.captacao_quadros;
  v_p public.captacao_possiveis;
  v_col uuid;
  v_colnome text;
  v_etq uuid[];
  v_cartao uuid;
  v_brl text;
  v_desc text;
begin
  select * into v_q from public.captacao_quadros where not modelo and ativo and lower(email) = v_email order by posicao limit 1;
  if v_q.id is null then
    raise exception 'Só as captadoras com quadro podem pegar';
  end if;
  select * into v_p from public.captacao_possiveis where id = p_id for update;
  if v_p.id is null then
    raise exception 'Anúncio não encontrado';
  end if;
  if v_p.situacao = 'pego' then
    raise exception 'Este anúncio já foi pego por %', coalesce((select nome from public.captacao_quadros where id = v_p.pego_quadro), v_p.pego_por);
  end if;
  if v_p.situacao <> 'novo' then
    raise exception 'Este anúncio não está mais disponível';
  end if;
  select id, nome into v_col, v_colnome from public.captacao_colunas where quadro_id = v_q.id order by posicao limit 1;
  if v_col is null then
    raise exception 'O seu quadro não tem colunas';
  end if;
  -- Etiqueta "PROSPECÇÃO DIGITAL IMOBILIÁRIA" (pedido da gerência em 11/11/2026): marca o que veio desta lista, para
  -- acompanhar quantos imóveis captados e fechados saíram da prospecção digital. Criada no quadro se ainda não existir.
  insert into public.captacao_etiquetas (quadro_id, nome, cor) values (v_q.id, 'PROSPECÇÃO DIGITAL IMOBILIÁRIA', 'pink')
  on conflict (quadro_id, nome) do nothing;
  select coalesce(array_agg(id), '{}') into v_etq from public.captacao_etiquetas
   where quadro_id = v_q.id and (upper(nome) = upper(coalesce(v_p.cidade, '')) or nome = 'PROSPECÇÃO DIGITAL IMOBILIÁRIA');
  v_brl := case when v_p.valor is null then '' else 'R$ ' || translate(to_char(v_p.valor, 'FM999,999,990'), ',', '.') end;
  v_desc := 'Possível cliente: anúncio do próprio dono na ' || case v_p.fonte when 'olx' then 'OLX' else 'Eemovel' end
         || ', encontrado em ' || to_char(v_p.encontrado_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY') || E'.\n\n'
         || coalesce(v_p.titulo, '') || E'\n'
         || 'Aluguel: ' || v_brl
         || coalesce(E'\nCondomínio: R$ ' || translate(to_char(nullif(v_p.condominio, 0), 'FM999,999,990'), ',', '.'), '')
         || coalesce(E'\nIPTU: R$ ' || translate(to_char(nullif(v_p.iptu, 0), 'FM999,999,990'), ',', '.'), '')
         || E'\nEndereço do anúncio: ' || concat_ws(', ', nullif(v_p.rua, ''), nullif(v_p.bairro, ''), initcap(lower(coalesce(v_p.cidade, ''))), nullif(v_p.cep, ''))
         || coalesce(E'\nÁrea: ' || nullif(v_p.area, 0)::text || ' m²', '')
         || coalesce(E'\nQuartos: ' || v_p.quartos::text, '')
         || coalesce(E'\nAnunciado em: ' || to_char(v_p.anunciado_em, 'DD/MM/YYYY'), '')
         || case when v_p.nosso_ref is not null then E'\n\nATENÇÃO: parecido com o ' || v_p.nosso_ref || ' do CRM (' || coalesce(v_p.nosso_info, '') || '). Confira antes de ligar.' else '' end
         || E'\n\nAnúncio: ' || coalesce(v_p.link, '')
         || coalesce(E'\nContato pelo anúncio: ' || replace(replace(nullif(v_p.contato, ''), 'chat', 'chat da ' || case v_p.fonte when 'olx' then 'OLX' else 'origem' end), 'site', 'formulário do site'), '')
         || E'\n\nPara falar com o dono, abra o anúncio e use o chat ou o botão de telefone do próprio site.'
         || E'\nPara achar o telefone do dono: Eemovel > Pesquisa de proprietários e moradores (brokers.eemovel.com.br/consulta), '
         || 'com a rua e o número. Pesquisar é grátis; o "Ver mais" com contato gasta 1 crédito. Em prédio, pergunte antes o número do apartamento no chat.';
  insert into public.captacao_cartoes (quadro_id, coluna_id, posicao, titulo, descricao, etiquetas, criado_por)
  values (v_q.id, v_col,
          coalesce((select min(posicao) from public.captacao_cartoes where quadro_id = v_q.id and coluna_id = v_col), 65536) - 1024,
          left(concat_ws(' - ', 'POSSÍVEL CLIENTE', nullif(initcap(lower(regexp_replace(coalesce(v_p.tipo, ''), '^aluguel\s*-\s*', '', 'i'))), ''), coalesce(nullif(v_p.bairro, ''), nullif(v_p.rua, '')), nullif(v_brl, '')), 300),
          left(v_desc, 20000), v_etq, v_email)
  returning id into v_cartao;
  insert into public.captacao_historico (cartao_id, tipo, para_coluna, texto, autor)
  values (v_cartao, 'criado', v_colnome, 'Possível cliente (' || case v_p.fonte when 'olx' then 'OLX' else 'Eemovel' end || ')', v_email);
  update public.captacao_possiveis set situacao = 'pego', pego_quadro = v_q.id, pego_por = v_email, pego_em = now(), cartao_id = v_cartao
   where id = v_p.id;
  return v_cartao;
end;
$$;

-- A etiqueta já nasce em todos os quadros (e no modelo), para aparecer no filtro e poder ser posta à mão.
insert into public.captacao_etiquetas (quadro_id, nome, cor)
select id, 'PROSPECÇÃO DIGITAL IMOBILIÁRIA', 'pink' from public.captacao_quadros
on conflict (quadro_id, nome) do nothing;

revoke execute on function public.captacao_pegar_possivel(uuid) from public, anon;
grant execute on function public.captacao_pegar_possivel(uuid) to authenticated;

-- Descartar (já é nosso, já falamos com o dono, não aceita imobiliária...) ou desfazer o descarte.
create or replace function public.captacao_descartar_possivel(p_id uuid, p_motivo text, p_desfazer boolean default false)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.pode_captacao() then
    raise exception 'Sem permissão';
  end if;
  if p_desfazer then
    update public.captacao_possiveis set situacao = 'novo', descartado_por = null, descartado_em = null, motivo = null
     where id = p_id and situacao = 'descartado';
  else
    update public.captacao_possiveis set situacao = 'descartado', descartado_por = lower(auth.jwt() ->> 'email'),
           descartado_em = now(), motivo = left(nullif(trim(p_motivo), ''), 300)
     where id = p_id and situacao = 'novo';
  end if;
  if not found then
    raise exception 'Este anúncio mudou enquanto a tela estava aberta. Clique em Atualizar.';
  end if;
end;
$$;

revoke execute on function public.captacao_descartar_possivel(uuid, text, boolean) from public, anon;
grant execute on function public.captacao_descartar_possivel(uuid, text, boolean) to authenticated;
