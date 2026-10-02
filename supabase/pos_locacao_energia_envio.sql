-- Pós-locação · energia enviada pela Locação (substitui a lista automática de supabase/pos_locacao_energia.sql, decisão da gerência em 02/10/2026).
-- Nada entra sozinho: a Locação, no cartão do quadro de contratos, clica em "Enviar à Pós-locação" quando a energia não foi transferida.
-- O envio vira uma demanda "A fazer" no quadro de Demandas da Pós-locação (atividade "Monitorar transferência de titularidade de consumos"),
-- ligada ao cartão. A Pós-locação também pode cadastrar a mesma atividade à mão, pela "+ Nova demanda" (sem cartão ligado).
-- O envio e a conclusão aparecem no histórico do cartão, para a Locação acompanhar.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor, depois de supabase/quadro.sql e supabase/departamentos.sql.

alter table public.dep_demandas add column if not exists cartao_id uuid references public.quadro_cartoes (id) on delete set null;
create index if not exists dep_demandas_cartao_idx on public.dep_demandas (cartao_id) where cartao_id is not null;

-- Só o envio da Locação (função abaixo) liga a demanda a um cartão: pela página, o cartão não é gravado nem trocado.
create or replace function public.dep_demandas_protege_cartao()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if current_user in ('authenticated', 'anon') then
    if tg_op = 'INSERT' then
      new.cartao_id := null;
    else
      new.cartao_id := old.cartao_id;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists dep_demandas_protege_cartao on public.dep_demandas;
create trigger dep_demandas_protege_cartao before insert or update on public.dep_demandas
  for each row execute function public.dep_demandas_protege_cartao();

-- Envio da Locação. Não deixa enviar de novo enquanto a anterior não estiver concluída.
create or replace function public.pos_energia_enviar(p_cartao uuid, p_obs text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_titulo text;
  v_ref text;
  v_obs text := nullif(left(trim(coalesce(p_obs, '')), 2000), '');
  v_email text := auth.jwt() ->> 'email';
  v_id uuid;
begin
  if not public.pode_quadro() then
    raise exception 'Sem permissão';
  end if;
  select titulo, referencia into v_titulo, v_ref from public.quadro_cartoes where id = p_cartao and not modelo;
  if not found then
    raise exception 'Cartão não encontrado';
  end if;
  if exists (select 1 from public.dep_demandas where cartao_id = p_cartao and departamento = 'pos-locacao' and status <> 'Concluída') then
    raise exception 'Este contrato já está com a Pós-locação para verificar';
  end if;
  insert into public.dep_demandas (departamento, atividade, titulo, referencia, status, observacao, criado_por, cartao_id)
  values ('pos-locacao', 'Monitorar transferência de titularidade de consumos', left(v_titulo, 160), left(v_ref, 120), 'A fazer', v_obs, v_email, p_cartao)
  returning id into v_id;
  insert into public.quadro_historico (cartao_id, tipo, texto, autor)
  values (p_cartao, 'comentario', '[Pós-locação · energia] Enviado à Pós-locação para verificar a transferência da energia.' || coalesce(E'\n' || v_obs, ''), v_email);
  return v_id;
end;
$$;

-- Envios de um cartão, para a Locação ver no cartão em que pé está (a Locação não acessa as demandas da Pós-locação).
create or replace function public.pos_energia_envios(p_cartao uuid)
returns table (id uuid, status text, responsavel text, criado_em timestamptz, criado_por text, concluido_em timestamptz)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.pode_quadro() then
    raise exception 'Sem permissão';
  end if;
  return query
  select d.id, d.status, d.responsavel, d.criado_em, d.criado_por, d.concluido_em
    from public.dep_demandas d
   where d.cartao_id = p_cartao and d.departamento = 'pos-locacao'
   order by d.criado_em desc;
end;
$$;

-- Quando a Pós-locação conclui uma demanda enviada pela Locação, avisa no histórico do cartão.
create or replace function public.pos_energia_concluida()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.cartao_id is not null and new.status = 'Concluída' and old.status is distinct from 'Concluída' then
    insert into public.quadro_historico (cartao_id, tipo, texto, autor)
    values (new.cartao_id, 'comentario', '[Pós-locação · energia] Verificação concluída pela Pós-locação.' || coalesce(E'\n' || new.observacao, ''), auth.jwt() ->> 'email');
  end if;
  return null;
end;
$$;

drop trigger if exists dep_demandas_pos_energia_concluida on public.dep_demandas;
create trigger dep_demandas_pos_energia_concluida after update of status on public.dep_demandas
  for each row execute function public.pos_energia_concluida();

revoke execute on function public.pos_energia_enviar(uuid, text), public.pos_energia_envios(uuid), public.pos_energia_concluida(), public.dep_demandas_protege_cartao() from public, anon;
grant execute on function public.pos_energia_enviar(uuid, text), public.pos_energia_envios(uuid) to authenticated;
