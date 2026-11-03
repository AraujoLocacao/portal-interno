-- Notificações da Pós-locação para a captadora (03/11/2026, pedido da gerência).
-- Depois que uma captadora pega o aviso de saída (captacao_avisos), cada data preenchida na descrição do cartão de saídas
-- vira notificação para ela: "Vistoria de Saída: ..." (vistoria agendada) e "Entrega das Chaves: ..." (chaves recebidas).
-- A notificação aparece no sino da página da Captação e como comentário no cartão dela. Só conta valor com número (data).
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de captacao_avisos.sql.

create or replace function public.saidas_data_campo(p_desc text, p_campo text)
returns text
language sql
immutable
as $$
  select nullif(trim(trailing ' .' from trim(v)), '')
    from (select case p_campo
                   when 'vistoria' then substring(coalesce(p_desc, '') from '(?i)vistoria\s+de\s+sa[ií]da\**\s*:\s*\**\s*([^\n*]*)')
                   when 'chaves' then substring(coalesce(p_desc, '') from '(?i)entrega\s+d[ae]s?\s+chaves\**\s*:\s*\**\s*([^\n*]*)')
                 end v) x
   where v ~ '\d';
$$;

create table if not exists public.captacao_notificacoes (
  id uuid primary key default gen_random_uuid(),
  quadro_id uuid not null references public.captacao_quadros (id) on delete cascade,
  cartao_id uuid references public.captacao_cartoes (id) on delete set null,
  saida_id uuid references public.saidas_cartoes (id) on delete set null,
  tipo text not null check (tipo in ('vistoria', 'chaves')),
  texto text not null,
  criado_em timestamptz not null default now(),
  lida_em timestamptz
);

create index if not exists captacao_notificacoes_quadro_idx on public.captacao_notificacoes (quadro_id, criado_em desc);

alter table public.captacao_notificacoes enable row level security;
-- Sem policies: leitura e "marcar como lida" só pelas funções abaixo.
revoke all on public.captacao_notificacoes from anon, authenticated;

-- Descrição do cartão de saídas mudou => compara as datas de vistoria e de entrega das chaves e avisa a captadora que pegou.
create or replace function public.saidas_notifica_captacao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_a public.captacao_avisos;
  v_campo text;
  v_novo text;
  v_texto text;
begin
  if coalesce(current_setting('app.importando', true), '') = 'on' then
    return new;
  end if;
  select * into v_a from public.captacao_avisos where saida_id = new.id and pego_quadro is not null;
  if v_a.id is null then
    return new;
  end if;
  foreach v_campo in array array['vistoria', 'chaves'] loop
    v_novo := public.saidas_data_campo(new.descricao, v_campo);
    if v_novo is not null and v_novo is distinct from public.saidas_data_campo(old.descricao, v_campo) then
      v_texto := case v_campo when 'vistoria' then 'Vistoria de saída agendada: ' else 'Chaves entregues: ' end || v_novo;
      insert into public.captacao_notificacoes (quadro_id, cartao_id, saida_id, tipo, texto)
      values (v_a.pego_quadro, v_a.cartao_id, new.id, v_campo, v_texto);
      if v_a.cartao_id is not null then
        insert into public.captacao_historico (cartao_id, tipo, texto, autor)
        values (v_a.cartao_id, 'comentario', v_texto || ' (aviso automático da Pós-locação)', 'Pós-locação');
      end if;
    end if;
  end loop;
  return new;
end;
$$;

drop trigger if exists saidas_cartoes_notifica_captacao on public.saidas_cartoes;
create trigger saidas_cartoes_notifica_captacao after update of descricao on public.saidas_cartoes
  for each row when (old.descricao is distinct from new.descricao)
  execute function public.saidas_notifica_captacao();

-- Notificações dos últimos 30 dias: a captadora vê as do quadro dela; a gerência e o acesso geral veem todas.
create or replace function public.captacao_notificacoes_listar()
returns table (id uuid, quadro text, cartao_id uuid, titulo text, tipo text, texto text, criado_em timestamptz, lida_em timestamptz, minha boolean)
language sql
stable
security definer
set search_path = public
as $$
  select n.id, q.nome, n.cartao_id, coalesce(k.titulo, s.titulo), n.tipo, n.texto, n.criado_em, n.lida_em,
         lower(coalesce(q.email, '')) = lower(coalesce(auth.jwt() ->> 'email', ''))
    from public.captacao_notificacoes n
    join public.captacao_quadros q on q.id = n.quadro_id
    left join public.captacao_cartoes k on k.id = n.cartao_id
    left join public.saidas_cartoes s on s.id = n.saida_id
   where n.criado_em > now() - interval '30 days'
     and (public.is_gestor() or public.tem_acesso_geral() or lower(coalesce(q.email, '')) = lower(coalesce(auth.jwt() ->> 'email', '')))
   order by n.criado_em desc;
$$;

revoke execute on function public.captacao_notificacoes_listar() from public, anon;
grant execute on function public.captacao_notificacoes_listar() to authenticated;

-- A captadora marca como lidas as notificações do próprio quadro (a gerência só olha, não marca).
create or replace function public.captacao_notificacoes_ler()
returns void
language sql
security definer
set search_path = public
as $$
  update public.captacao_notificacoes n set lida_em = now()
    from public.captacao_quadros q
   where q.id = n.quadro_id and n.lida_em is null
     and lower(coalesce(q.email, '')) = lower(coalesce(auth.jwt() ->> 'email', ''));
$$;

revoke execute on function public.captacao_notificacoes_ler() from public, anon;
grant execute on function public.captacao_notificacoes_ler() to authenticated;
