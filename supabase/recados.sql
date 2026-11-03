-- Recados de aniversário no portal (página inicial, bloco de aniversários): a equipe deixa recados para quem faz
-- aniversário de vida ou de empresa. Decisões da gerência (02/11/2026): qualquer pessoa no portal escreve (sem login,
-- informando o nome), todos leem, e só gestores apagam. Cada comemoração (pessoa + tipo + dia) tem o seu mural,
-- aberto de 30 dias antes até 7 dias depois da data.
-- A tabela não é acessada direto: o portal só chama as funções abaixo.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de supabase/rh.sql e de is_gestor (avisos.sql).

create table if not exists public.rh_recados (
  id uuid primary key default gen_random_uuid(),
  colaborador_id uuid not null references public.rh_colaboradores(id) on delete cascade,
  tipo text not null check (tipo in ('vida', 'empresa')),
  dia date not null,
  autor text not null check (char_length(btrim(autor)) between 1 and 60),
  mensagem text not null check (char_length(btrim(mensagem)) between 1 and 500),
  criado_em timestamptz not null default now()
);

create index if not exists rh_recados_mural on public.rh_recados (colaborador_id, tipo, dia, criado_em);

alter table public.rh_recados enable row level security;
revoke all on public.rh_recados from anon, authenticated;

-- Aniversários com mural aberto (de 7 dias atrás até p_dias à frente), com o id da pessoa e quantos recados já tem.
create or replace function public.aniversarios_mural(p_dias int default 30)
returns table (colaborador_id uuid, nome text, tipo text, dia date, anos int, recados int)
language sql stable security definer set search_path = public as $$
  with hoje as (select (now() at time zone 'America/Sao_Paulo')::date as h),
  ev as (
    select c.id, c.nome, 'vida'::text as tipo, public.rh_proxima(c.nascimento_dia, c.nascimento_mes, hoje.h - 7) as dia, null::int as anos
    from public.rh_colaboradores c, hoje
    where c.ativo and c.nascimento_dia is not null
    union all
    select c.id, c.nome, 'empresa', p.dia, (extract(year from p.dia) - extract(year from c.admissao))::int
    from public.rh_colaboradores c, hoje,
      lateral (select public.rh_proxima(extract(day from c.admissao)::int, extract(month from c.admissao)::int, hoje.h - 7) as dia) p
    where c.ativo and c.admissao is not null
  )
  select ev.id, ev.nome, ev.tipo, ev.dia, ev.anos,
    (select count(*)::int from public.rh_recados r where r.colaborador_id = ev.id and r.tipo = ev.tipo and r.dia = ev.dia)
  from ev, hoje
  where ev.dia between hoje.h - 7 and hoje.h + least(greatest(coalesce(p_dias, 30), 0), 366)
    and (ev.anos is null or ev.anos >= 1)
  order by ev.dia, ev.tipo desc, ev.nome;
$$;

create or replace function public.recados_listar(p_colaborador uuid, p_tipo text, p_dia date)
returns table (id uuid, autor text, mensagem text, criado_em timestamptz)
language sql stable security definer set search_path = public as $$
  select r.id, r.autor, r.mensagem, r.criado_em from public.rh_recados r
  where r.colaborador_id = p_colaborador and r.tipo = p_tipo and r.dia = p_dia
  order by r.criado_em;
$$;

-- Só aceita recado para uma comemoração com mural aberto; até 300 recados por mural.
create or replace function public.recado_enviar(p_colaborador uuid, p_tipo text, p_dia date, p_autor text, p_mensagem text)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare
  novo uuid;
begin
  if not exists (select 1 from public.aniversarios_mural(30) m
                 where m.colaborador_id = p_colaborador and m.tipo = p_tipo and m.dia = p_dia) then
    raise exception 'O mural deste aniversário não está aberto.';
  end if;
  if (select count(*) from public.rh_recados r
      where r.colaborador_id = p_colaborador and r.tipo = p_tipo and r.dia = p_dia) >= 300 then
    raise exception 'Este mural já está cheio.';
  end if;
  insert into public.rh_recados (colaborador_id, tipo, dia, autor, mensagem)
  values (p_colaborador, p_tipo, p_dia, btrim(p_autor), btrim(p_mensagem))
  returning id into novo;
  return novo;
end $$;

create or replace function public.recado_apagar(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not public.is_gestor() then
    raise exception 'Só a gerência pode apagar recados.';
  end if;
  delete from public.rh_recados where id = p_id;
end $$;

revoke all on function public.aniversarios_mural(int) from public;
revoke all on function public.recados_listar(uuid, text, date) from public;
revoke all on function public.recado_enviar(uuid, text, date, text, text) from public;
revoke all on function public.recado_apagar(uuid) from public;
grant execute on function public.aniversarios_mural(int) to anon, authenticated;
grant execute on function public.recados_listar(uuid, text, date) to anon, authenticated;
grant execute on function public.recado_enviar(uuid, text, date, text, text) to anon, authenticated;
grant execute on function public.recado_apagar(uuid) to authenticated;
