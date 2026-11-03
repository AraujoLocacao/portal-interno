-- Datas de vistoria de saída e de entrega das chaves como campos do cartão (03/11/2026, pedido da gerência: padronizar e
-- obrigar o formato). Antes eram texto livre na descrição ("Vistoria de Saída: 04/11 as 14:30"). Agora são campos:
-- vistoria_data + vistoria_hora (a hora pode ficar vazia) e chaves_em. O cartão mostra na frente, a agenda usa, e as
-- notificações da Captação passam a sair dos campos.
-- A migração lê o texto dos cartões ativos. A linha sai da descrição só quando tinha apenas a data/hora; se tinha
-- observação ("sem acompanhante", "VNR"...), a linha continua na descrição.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de saidas.sql e captacao_notificacoes.sql.

alter table public.saidas_cartoes drop column if exists vistoria_em;
alter table public.saidas_cartoes add column if not exists vistoria_data date;
alter table public.saidas_cartoes add column if not exists vistoria_hora time;
alter table public.saidas_cartoes add column if not exists chaves_em date;
create index if not exists saidas_cartoes_vistoria_idx on public.saidas_cartoes (vistoria_data);

-- Lê "dd/mm", "dd-mm", "dd mm", com ano opcional ("aa" ou "aaaa") e hora opcional ("14:30", "14h", "9h30", "14HRS",
-- "11;00"). Sem ano: o ano que deixa a data mais perto de hoje (até 4 meses à frente).
create or replace function public.saidas_ler_data(p_txt text, out dia date, out hora time)
language plpgsql immutable as $$
declare
  m text[]; d int; mm int; a int; h int; mi int;
begin
  m := regexp_match(coalesce(p_txt, ''),
         '(?i)(?:^|\D)(\d{1,2})\s*(?:[/\-.]+|\s)\s*(\d{1,2})(?!\d)(?:\s*[/\-.]+\s*(\d{4}|\d{2})(?!\d))?(?:\D{0,6}?(\d{1,2})\s*(?:[:h;]\s*(\d{2})?|hrs?|\s+hrs?))?');
  if m is null then return; end if;
  d := m[1]::int; mm := m[2]::int;
  if mm < 1 or mm > 12 or d < 1 or d > 31 then return; end if;
  if m[3] is not null then a := m[3]::int; if a < 100 then a := a + 2000; end if;
  else
    a := extract(year from current_date)::int;
    if make_date(a, mm, least(d, 28)) > current_date + 120 then a := a - 1; end if;
  end if;
  begin dia := make_date(a, mm, d); exception when others then dia := null; return; end;
  if m[4] is not null then
    h := m[4]::int; mi := coalesce(m[5], '0')::int;
    if h between 0 and 23 and mi between 0 and 59 then hora := make_time(h, mi, 0); end if;
  end if;
end;
$$;

-- Texto que é só data/hora (pode sair da descrição sem perder nada).
create or replace function public.saidas_so_data(p_txt text)
returns boolean language sql immutable as $$
  select coalesce(p_txt, '') ~* '^\s*(reagendado\s+)?[\d/\-. ]+((\s*(as|às)\s*)?\s*\d{1,2}\s*([:h;]\s*\d{0,2}|hrs?)?\s*)?\s*$';
$$;

-- Migração (cartões ativos com o campo vazio).
with t as (
  select k.id, public.saidas_data_campo(k.descricao, 'vistoria') v_txt, public.saidas_data_campo(k.descricao, 'chaves') c_txt
    from public.saidas_cartoes k
   where not k.arquivado and (k.vistoria_data is null or k.chaves_em is null)
), l as (
  select t.*, (public.saidas_ler_data(v_txt)).dia v_dia, (public.saidas_ler_data(v_txt)).hora v_hora, (public.saidas_ler_data(c_txt)).dia c_dia
    from t
)
update public.saidas_cartoes k
   set vistoria_data = coalesce(k.vistoria_data, l.v_dia),
       vistoria_hora = case when k.vistoria_data is null then l.v_hora else k.vistoria_hora end,
       chaves_em = coalesce(k.chaves_em, l.c_dia),
       descricao = regexp_replace(regexp_replace(k.descricao,
                     case when l.v_txt is null or (l.v_dia is not null and public.saidas_so_data(l.v_txt)) then '(?in)^[ *_]*vistoria\s+de\s+sa[ií]da\**\s*:[^\n]{0,60}\n?' else '$^' end, ''),
                     case when l.c_txt is null or (l.c_dia is not null and public.saidas_so_data(l.c_txt)) then '(?in)^[ *_]*(data\s+de\s+)?entrega\s+d[ae]s?\s+chaves\**\s*:[^\n]{0,60}\n?' else '$^' end, '')
  from l where l.id = k.id;

-- Notificações da Captação passam a sair dos campos (o texto da descrição não dispara mais).
create or replace function public.saidas_notifica_captacao()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_a public.captacao_avisos;
  v_texto text;
begin
  if coalesce(current_setting('app.importando', true), '') = 'on' then
    return new;
  end if;
  select * into v_a from public.captacao_avisos where saida_id = new.id and pego_quadro is not null;
  if v_a.id is null then
    return new;
  end if;
  if new.vistoria_data is not null and (new.vistoria_data, new.vistoria_hora) is distinct from (old.vistoria_data, old.vistoria_hora) then
    v_texto := 'Vistoria de saída agendada: ' || to_char(new.vistoria_data, 'DD/MM/YYYY') || coalesce(' às ' || to_char(new.vistoria_hora, 'HH24:MI'), '');
    insert into public.captacao_notificacoes (quadro_id, cartao_id, saida_id, tipo, texto) values (v_a.pego_quadro, v_a.cartao_id, new.id, 'vistoria', v_texto);
    if v_a.cartao_id is not null then
      insert into public.captacao_historico (cartao_id, tipo, texto, autor) values (v_a.cartao_id, 'comentario', v_texto || ' (aviso automático da Pós-locação)', 'Pós-locação');
    end if;
  end if;
  if new.chaves_em is not null and new.chaves_em is distinct from old.chaves_em then
    v_texto := 'Chaves entregues: ' || to_char(new.chaves_em, 'DD/MM/YYYY');
    insert into public.captacao_notificacoes (quadro_id, cartao_id, saida_id, tipo, texto) values (v_a.pego_quadro, v_a.cartao_id, new.id, 'chaves', v_texto);
    if v_a.cartao_id is not null then
      insert into public.captacao_historico (cartao_id, tipo, texto, autor) values (v_a.cartao_id, 'comentario', v_texto || ' (aviso automático da Pós-locação)', 'Pós-locação');
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists saidas_cartoes_notifica_captacao on public.saidas_cartoes;
create trigger saidas_cartoes_notifica_captacao after update of vistoria_data, vistoria_hora, chaves_em on public.saidas_cartoes
  for each row execute function public.saidas_notifica_captacao();

-- Cartões arquivados: só preenche os campos (para o histórico do Meu painel), sem mexer na descrição.
with t as (select k.id, public.saidas_data_campo(k.descricao, 'vistoria') v, public.saidas_data_campo(k.descricao, 'chaves') c
             from public.saidas_cartoes k where k.arquivado and k.vistoria_data is null and k.chaves_em is null),
l as (select id, (public.saidas_ler_data(v)).dia vd, (public.saidas_ler_data(v)).hora vh, (public.saidas_ler_data(c)).dia cd from t)
update public.saidas_cartoes k set vistoria_data = l.vd, vistoria_hora = l.vh, chaves_em = l.cd
  from l where l.id = k.id and (l.vd is not null or l.cd is not null);

-- -- Correção do ano das datas sem ano: usa a criação do cartão como referência (a data fica a partir de 60 dias antes dela).
create or replace function public.saidas_ler_data(p_txt text, p_ref date, out dia date, out hora time)
language plpgsql immutable as $$
declare
  m text[]; d int; mm int; a int; h int; mi int; cand date;
begin
  m := regexp_match(coalesce(p_txt, ''),
         '(?i)(?:^|\D)(\d{1,2})\s*(?:[/\-.]+|\s)\s*(\d{1,2})(?!\d)(?:\s*[/\-.]+\s*(\d{4}|\d{2})(?!\d))?(?:\D{0,6}?(\d{1,2})\s*(?:[:h;]\s*(\d{2})?|hrs?|\s+hrs?))?');
  if m is null then return; end if;
  d := m[1]::int; mm := m[2]::int;
  if mm < 1 or mm > 12 or d < 1 or d > 31 then return; end if;
  if m[3] is not null then a := m[3]::int; if a < 100 then a := a + 2000; end if;
  elsif p_ref is not null then
    a := extract(year from p_ref)::int;
    if make_date(a, mm, least(d, 28)) < p_ref - 60 then a := a + 1; end if;
  else
    a := extract(year from current_date)::int;
    if make_date(a, mm, least(d, 28)) > current_date + 120 then a := a - 1; end if;
  end if;
  begin dia := make_date(a, mm, d); exception when others then dia := null; return; end;
  if m[4] is not null then
    h := m[4]::int; mi := coalesce(m[5], '0')::int;
    if h between 0 and 23 and mi between 0 and 59 then hora := make_time(h, mi, 0); end if;
  end if;
end;
$$;
