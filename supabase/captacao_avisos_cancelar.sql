-- Aviso de saída cancelado (09/11/2026, pedido da gerência: "deveria ter sido removido da captação também").
-- O aviso é cancelado quando o cartão de saídas é ARQUIVADO ou VOLTA para uma coluna anterior à de aviso
-- (ex.: "SOLICITAÇÃO DE DESOCUPAÇÃO VOLUNTÁRIA - NÃO RENOVAÇÃO").
--   * Ainda não pego: some da aba "Avisos de saída" da Captação e ninguém mais consegue pegar.
--   * Já pego: o cartão da captadora fica onde está, mas ela recebe uma notificação no sino e um comentário no cartão.
-- Se o cartão voltar para a coluna de aviso (ou for restaurado nela), o aviso reaparece como novo.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de captacao_avisos.sql e captacao_notificacoes.sql.

alter table public.captacao_avisos add column if not exists cancelado_em timestamptz;
alter table public.captacao_avisos add column if not exists cancelado_motivo text;

alter table public.captacao_notificacoes drop constraint if exists captacao_notificacoes_tipo_check;
alter table public.captacao_notificacoes add constraint captacao_notificacoes_tipo_check check (tipo in ('vistoria', 'chaves', 'cancelado', 'reativado'));

create or replace function public.saidas_aviso_captacao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_a public.captacao_avisos;
  v_pos_aviso numeric;
  v_col public.saidas_colunas;
  v_motivo text;
  v_autor text := coalesce(auth.jwt() ->> 'email', 'portal');
begin
  if coalesce(current_setting('app.importando', true), '') = 'on' then
    return new;
  end if;
  select * into v_col from public.saidas_colunas where id = new.coluna_id;

  -- Saiu do caminho: arquivado agora, ou movido para uma coluna antes da de aviso.
  if tg_op = 'UPDATE' then
    select min(posicao) into v_pos_aviso from public.saidas_colunas where aviso_captacao and not arquivada;
    if new.arquivado and not old.arquivado then
      v_motivo := 'cartão arquivado na Pós-locação';
    elsif not new.arquivado and old.coluna_id is distinct from new.coluna_id and not coalesce(v_col.aviso_captacao, false)
          and v_col.posicao < v_pos_aviso then
      v_motivo := 'cartão voltou para "' || v_col.nome || '" na Pós-locação';
    end if;
    if v_motivo is not null then
      update public.captacao_avisos set cancelado_em = now(), cancelado_motivo = v_motivo
       where saida_id = new.id and cancelado_em is null
       returning * into v_a;
      if v_a.id is not null then
        insert into public.saidas_historico (cartao_id, tipo, texto, autor)
        values (new.id, 'editado', 'cancelou o aviso de saída na Captação (' || v_motivo || ')', v_autor);
        if v_a.pego_quadro is not null then
          insert into public.captacao_notificacoes (quadro_id, cartao_id, saida_id, tipo, texto)
          values (v_a.pego_quadro, v_a.cartao_id, new.id, 'cancelado', 'Aviso de saída cancelado: ' || v_motivo);
          if v_a.cartao_id is not null then
            insert into public.captacao_historico (cartao_id, tipo, texto, autor)
            values (v_a.cartao_id, 'comentario', 'Aviso de saída cancelado: ' || v_motivo || ' (aviso automático da Pós-locação)', 'Pós-locação');
          end if;
        end if;
      end if;
      return new;
    end if;
  end if;

  -- Entrou na coluna de aviso (criado, movido ou restaurado nela).
  if new.arquivado or not coalesce(v_col.aviso_captacao, false) then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.coluna_id = new.coluna_id and not (old.arquivado and not new.arquivado) then
    return new;
  end if;
  -- Se já tinha sido pego antes do cancelamento, continua com a mesma captadora (não vira aviso novo) e ela é avisada.
  insert into public.captacao_avisos (saida_id) values (new.id)
  on conflict (saida_id) do update
     set criado_em = case when captacao_avisos.pego_em is null then now() else captacao_avisos.criado_em end,
         cancelado_em = null, cancelado_motivo = null
   where captacao_avisos.cancelado_em is not null
  returning * into v_a;
  if v_a.id is not null then
    insert into public.saidas_historico (cartao_id, tipo, texto, autor)
    values (new.id, 'editado', case when v_a.pego_quadro is null then 'enviou o aviso de saída para a Captação'
                                    else 'reativou o aviso de saída na Captação' end, v_autor);
    if v_a.pego_quadro is not null then
      insert into public.captacao_notificacoes (quadro_id, cartao_id, saida_id, tipo, texto)
      values (v_a.pego_quadro, v_a.cartao_id, new.id, 'reativado', 'Aviso de saída reativado: o cartão voltou para "' || v_col.nome || '" na Pós-locação');
      if v_a.cartao_id is not null then
        insert into public.captacao_historico (cartao_id, tipo, texto, autor)
        values (v_a.cartao_id, 'comentario', 'Aviso de saída reativado pela Pós-locação (aviso automático)', 'Pós-locação');
      end if;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists saidas_cartoes_aviso_captacao on public.saidas_cartoes;
create trigger saidas_cartoes_aviso_captacao after insert or update of coluna_id, arquivado on public.saidas_cartoes
  for each row execute function public.saidas_aviso_captacao();

-- Lista: sem os cancelados.
create or replace function public.captacao_avisos_listar()
returns table (id uuid, referencia text, titulo text, descricao text, cidade text, aviso_em text, criado_em timestamptz,
               pego_por text, pego_em timestamptz, coluna text)
language sql
stable
security definer
set search_path = public
as $$
  select a.id, k.referencia, k.titulo, k.descricao, public.saidas_cidade(k.etiquetas),
         substring(k.descricao from '(?i)aviso de sa[ií]da:?\**\s*(\d{1,2}/\d{1,2}/\d{2,4})'),
         a.criado_em, coalesce(q.nome, a.pego_por), a.pego_em, c.nome
    from public.captacao_avisos a
    join public.saidas_cartoes k on k.id = a.saida_id
    join public.saidas_colunas c on c.id = k.coluna_id
    left join public.captacao_quadros q on q.id = a.pego_quadro
   where public.pode_captacao() and a.cancelado_em is null and not k.arquivado
     and (a.pego_em is null or a.pego_em > now() - interval '30 days')
   order by a.pego_em is not null, a.criado_em desc;
$$;

revoke execute on function public.captacao_avisos_listar() from public, anon;
grant execute on function public.captacao_avisos_listar() to authenticated;

-- Pegar: recusa aviso cancelado (quem estava com a tela aberta antes do cancelamento).
create or replace function public.captacao_pegar_aviso(p_aviso uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_q public.captacao_quadros;
  v_a public.captacao_avisos;
  v_s public.saidas_cartoes;
  v_col uuid;
  v_colnome text;
  v_cidade text;
  v_etq uuid[];
  v_cartao uuid;
begin
  select * into v_q from public.captacao_quadros where not modelo and ativo and lower(email) = v_email order by posicao limit 1;
  if v_q.id is null then
    raise exception 'Só as captadoras com quadro podem pegar o aviso';
  end if;
  select * into v_a from public.captacao_avisos where id = p_aviso for update;
  if v_a.id is null then
    raise exception 'Aviso não encontrado';
  end if;
  if v_a.cancelado_em is not null then
    raise exception 'Este aviso foi cancelado pela Pós-locação (%)', v_a.cancelado_motivo;
  end if;
  if v_a.pego_em is not null then
    raise exception 'Este aviso já foi pego por %', coalesce((select nome from public.captacao_quadros where id = v_a.pego_quadro), v_a.pego_por);
  end if;
  select * into v_s from public.saidas_cartoes where id = v_a.saida_id;
  if v_s.arquivado then
    raise exception 'Este aviso foi cancelado pela Pós-locação (cartão arquivado)';
  end if;
  select id, nome into v_col, v_colnome from public.captacao_colunas where quadro_id = v_q.id order by posicao limit 1;
  if v_col is null then
    raise exception 'O seu quadro não tem colunas';
  end if;
  v_cidade := public.saidas_cidade(v_s.etiquetas);
  select coalesce(array_agg(id), '{}') into v_etq from public.captacao_etiquetas
   where quadro_id = v_q.id and (upper(nome) in ('PÓS', 'POS') or upper(nome) = v_cidade);
  insert into public.captacao_cartoes (quadro_id, coluna_id, posicao, titulo, referencia, descricao, etiquetas, criado_por)
  values (v_q.id, v_col,
          coalesce((select min(posicao) from public.captacao_cartoes where quadro_id = v_q.id and coluna_id = v_col), 65536) - 1024,
          left(v_s.titulo, 300), v_s.referencia,
          left('Aviso de saída da Pós-locação, enviado em ' || to_char(v_a.criado_em at time zone 'America/Sao_Paulo', 'DD/MM/YYYY') || E'.\n\n' || v_s.descricao, 20000),
          v_etq, v_email)
  returning id into v_cartao;
  insert into public.captacao_historico (cartao_id, tipo, para_coluna, texto, autor)
  values (v_cartao, 'criado', v_colnome, 'Aviso de saída da Pós-locação', v_email);
  update public.captacao_avisos set pego_quadro = v_q.id, pego_por = v_email, pego_em = now(), cartao_id = v_cartao where id = v_a.id;
  insert into public.saidas_historico (cartao_id, tipo, texto, autor)
  values (v_s.id, 'editado', 'pegou o aviso na Captação (quadro ' || v_q.nome || ')', v_email);
  return v_cartao;
end;
$$;

revoke execute on function public.captacao_pegar_aviso(uuid) from public, anon;
grant execute on function public.captacao_pegar_aviso(uuid) to authenticated;
