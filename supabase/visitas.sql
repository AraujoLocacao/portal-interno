-- Confirmação de visita (30/10/2026), aba "Visitas" das Corretoras de locação (departamento.html?d=corretoras-locacao).
-- A corretora cadastra o cliente, os imóveis e os horários e manda o link visita.html?c=<token> para o cliente.
-- O cliente confirma (ou não) cada imóvel e informa telefone e e-mail (obrigatórios).
-- 30 minutos depois do último imóvel confirmado, a função visitas-avaliacao (supabase/functions) manda um e-mail
-- perguntando como foi a visita; a resposta volta pela mesma página (visita.html?c=<token>&avaliar=1).
-- A página pública não lê as tabelas: só chama visita_publica / visita_confirmar / visita_avaliar pelo token.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de departamentos.sql e acesso_geral.sql.

create table if not exists public.visitas (
  id uuid primary key default gen_random_uuid(),
  -- 24 letras aleatórias (base64 de 18 bytes, sem "+" e "/"): é a única chave do link do cliente.
  token text not null unique default translate(encode(extensions.gen_random_bytes(18), 'base64'), '+/', '-_'),
  corretora text references public.corretoras (nome) on update cascade,
  cliente_nome text not null check (char_length(cliente_nome) between 1 and 120),
  cliente_telefone text check (char_length(cliente_telefone) <= 30), -- digitado pela corretora, para o botão do WhatsApp
  observacao text check (char_length(observacao) <= 1000),           -- interna, o cliente não vê
  cancelada boolean not null default false,
  -- Preenchidos pelo cliente ao confirmar
  conf_nome text check (char_length(conf_nome) <= 120),
  conf_telefone text check (char_length(conf_telefone) <= 30),
  conf_email text check (char_length(conf_email) <= 160),
  confirmado_em timestamptz,
  -- Pesquisa depois da visita
  aval_envio_em timestamptz,          -- e-mail automático enviado
  aval_envio_erro text check (char_length(aval_envio_erro) <= 500),
  aval_tentativas smallint not null default 0,
  aval_whatsapp_em timestamptz,       -- a corretora clicou em "Pesquisa no WhatsApp"
  aval_nota_atendimento smallint check (aval_nota_atendimento between 1 and 5),
  aval_comentario text check (char_length(aval_comentario) <= 2000),
  avaliado_em timestamptz,
  criado_em timestamptz not null default now(),
  criado_por text default (auth.jwt() ->> 'email'),
  atualizado_em timestamptz not null default now()
);

create table if not exists public.visita_imoveis (
  id uuid primary key default gen_random_uuid(),
  visita_id uuid not null references public.visitas (id) on delete cascade,
  ordem smallint not null default 0,
  referencia text check (char_length(referencia) <= 40),
  endereco text not null check (char_length(endereco) between 1 and 300),
  data_hora timestamptz not null,
  -- Confirmação do cliente
  resposta text check (resposta in ('confirmo', 'nao_vou')),
  motivo text check (char_length(motivo) <= 500),
  respondido_em timestamptz,
  -- Avaliação do cliente
  visitou boolean,
  nota smallint check (nota between 1 and 5),
  interesse text check (interesse in ('sim', 'talvez', 'nao')),
  comentario text check (char_length(comentario) <= 1000)
);

create index if not exists visita_imoveis_visita_idx on public.visita_imoveis (visita_id, data_hora);
create index if not exists visitas_criado_idx on public.visitas (criado_em desc);

alter table public.visitas enable row level security;
alter table public.visita_imoveis enable row level security;
revoke all on public.visitas, public.visita_imoveis from anon;
revoke insert, truncate, references, trigger on public.visitas from authenticated;
revoke insert, update, delete, truncate, references, trigger on public.visita_imoveis from authenticated;
grant select, update, delete on public.visitas to authenticated;
grant select on public.visita_imoveis to authenticated;

-- Equipe: lê, cancela, marca o WhatsApp e exclui direto. Criar e editar passa por visita_salvar (imóveis juntos).
drop policy if exists "visitas: ler" on public.visitas;
create policy "visitas: ler" on public.visitas for select to authenticated using (public.pode_departamento('corretoras-locacao'));
drop policy if exists "visitas: alterar" on public.visitas;
create policy "visitas: alterar" on public.visitas for update to authenticated
  using (public.pode_departamento('corretoras-locacao')) with check (public.pode_departamento('corretoras-locacao'));
drop policy if exists "visitas: excluir" on public.visitas;
create policy "visitas: excluir" on public.visitas for delete to authenticated using (public.pode_departamento('corretoras-locacao'));
drop policy if exists "visita_imoveis: ler" on public.visita_imoveis;
create policy "visita_imoveis: ler" on public.visita_imoveis for select to authenticated using (public.pode_departamento('corretoras-locacao'));
-- Lista de corretoras para o campo "Corretora" da visita.
drop policy if exists "corretoras: leitura visitas" on public.corretoras;
create policy "corretoras: leitura visitas" on public.corretoras for select to authenticated using (public.pode_departamento('corretoras-locacao'));

-- ---------- Criar / editar (equipe) ----------
-- p_visita = {"corretora": "FRAN", "cliente_nome": "...", "cliente_telefone": "...", "observacao": "..."}
-- p_imoveis = [{"id": null | "<uuid>", "referencia": "SA0737", "endereco": "...", "data_hora": "2026-10-31T17:00:00.000Z"}, ...]
-- Imóvel com endereço ou horário trocado volta a "aguardando" (o cliente confirma de novo) e o e-mail da pesquisa pode sair outra vez.
create or replace function public.visita_salvar(p_id uuid, p_visita jsonb, p_imoveis jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid; v_token text; i jsonb; v_im uuid; v_ids uuid[] := '{}'; v_ordem int := 0; mudou boolean := false;
  v_end text; v_data timestamptz; antigo record;
begin
  if not public.pode_departamento('corretoras-locacao') then raise exception 'Sem acesso às visitas.'; end if;
  if jsonb_typeof(p_imoveis) is distinct from 'array' or jsonb_array_length(p_imoveis) = 0 then raise exception 'Informe pelo menos um imóvel.'; end if;
  if jsonb_array_length(p_imoveis) > 10 then raise exception 'No máximo 10 imóveis por link.'; end if;
  if coalesce(trim(p_visita ->> 'cliente_nome'), '') = '' then raise exception 'Informe o nome do cliente.'; end if;

  if p_id is null then
    insert into visitas (corretora, cliente_nome, cliente_telefone, observacao)
    values (nullif(p_visita ->> 'corretora', ''), trim(p_visita ->> 'cliente_nome'),
            nullif(trim(p_visita ->> 'cliente_telefone'), ''), nullif(trim(p_visita ->> 'observacao'), ''))
    returning id, token into v_id, v_token;
  else
    update visitas set corretora = nullif(p_visita ->> 'corretora', ''), cliente_nome = trim(p_visita ->> 'cliente_nome'),
      cliente_telefone = nullif(trim(p_visita ->> 'cliente_telefone'), ''), observacao = nullif(trim(p_visita ->> 'observacao'), ''),
      atualizado_em = now()
    where id = p_id returning id, token into v_id, v_token;
    if v_id is null then raise exception 'Visita não encontrada.'; end if;
  end if;

  for i in select * from jsonb_array_elements(p_imoveis) loop
    v_end := trim(coalesce(i ->> 'endereco', ''));
    if v_end = '' then raise exception 'Informe o endereço de todos os imóveis.'; end if;
    v_data := (i ->> 'data_hora')::timestamptz;
    if v_data is null then raise exception 'Informe a data e a hora de todos os imóveis.'; end if;
    v_im := nullif(i ->> 'id', '')::uuid;
    select endereco, data_hora into antigo from visita_imoveis where id = v_im and visita_id = v_id;
    if found then
      if antigo.endereco is distinct from v_end or antigo.data_hora is distinct from v_data then
        mudou := true;
        update visita_imoveis set resposta = null, motivo = null, respondido_em = null where id = v_im;
      end if;
      update visita_imoveis set referencia = nullif(trim(i ->> 'referencia'), ''), endereco = v_end, data_hora = v_data, ordem = v_ordem
      where id = v_im;
    else
      insert into visita_imoveis (visita_id, ordem, referencia, endereco, data_hora)
      values (v_id, v_ordem, nullif(trim(i ->> 'referencia'), ''), v_end, v_data)
      returning id into v_im;
      if p_id is not null then mudou := true; end if;
    end if;
    v_ids := v_ids || v_im;
    v_ordem := v_ordem + 1;
  end loop;
  delete from visita_imoveis where visita_id = v_id and not (id = any (v_ids));

  if mudou then
    update visitas set aval_envio_em = null, aval_envio_erro = null, aval_tentativas = 0 where id = v_id and avaliado_em is null;
  end if;
  return jsonb_build_object('id', v_id, 'token', v_token);
end;
$$;

revoke all on function public.visita_salvar(uuid, jsonb, jsonb) from public, anon;
grant execute on function public.visita_salvar(uuid, jsonb, jsonb) to authenticated;

-- ---------- Página do cliente (sem login, só com o token) ----------
create or replace function public.visita_publica(p_token text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'cliente', v.cliente_nome,
    'corretora', initcap(v.corretora),
    'cancelada', v.cancelada,
    'confirmado_em', v.confirmado_em,
    'conf_nome', v.conf_nome,
    'tem_contato', v.conf_email is not null,
    'avaliado_em', v.avaliado_em,
    'agora', now(),
    'imoveis', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'referencia', i.referencia, 'endereco', i.endereco,
        'data_hora', i.data_hora, 'resposta', i.resposta, 'motivo', i.motivo) order by i.data_hora, i.ordem)
      from visita_imoveis i where i.visita_id = v.id), '[]'::jsonb))
  from visitas v where v.token = p_token;
$$;

-- Telefone: 10 a 13 números (com DDD, com ou sem 55). E-mail: algo@algo.algo.
create or replace function public.visita_contato_ok(p_telefone text, p_email text)
returns text
language sql
immutable
as $$
  select case
    when length(regexp_replace(coalesce(p_telefone, ''), '\D', '', 'g')) not between 10 and 13 then 'Informe um telefone válido, com DDD.'
    when coalesce(p_email, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(p_email) > 160 then 'Informe um e-mail válido.'
  end;
$$;

-- p_respostas = [{"id": "<uuid do imóvel>", "resposta": "confirmo" | "nao_vou", "motivo": "..."}] — um para cada imóvel.
create or replace function public.visita_confirmar(p_token text, p_nome text, p_telefone text, p_email text, p_respostas jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v visitas%rowtype; r jsonb; erro text; n int;
begin
  select * into v from visitas where token = p_token;
  if not found then raise exception 'Link de visita não encontrado.'; end if;
  if v.cancelada then raise exception 'Esta visita foi cancelada. Fale com a sua corretora.'; end if;
  if v.avaliado_em is not null then raise exception 'Esta visita já foi avaliada.'; end if;
  if coalesce(trim(p_nome), '') = '' then raise exception 'Informe o seu nome.'; end if;
  erro := public.visita_contato_ok(p_telefone, trim(p_email));
  if erro is not null then raise exception '%', erro; end if;
  if jsonb_typeof(p_respostas) is distinct from 'array' then raise exception 'Responda todos os imóveis.'; end if;

  for r in select * from jsonb_array_elements(p_respostas) loop
    if r ->> 'resposta' not in ('confirmo', 'nao_vou') then raise exception 'Responda todos os imóveis.'; end if;
    update visita_imoveis set resposta = r ->> 'resposta',
      motivo = case when r ->> 'resposta' = 'nao_vou' then left(nullif(trim(r ->> 'motivo'), ''), 500) end,
      respondido_em = now()
    where id = nullif(r ->> 'id', '')::uuid and visita_id = v.id;
  end loop;
  select count(*) into n from visita_imoveis where visita_id = v.id and resposta is null;
  if n > 0 then raise exception 'Responda todos os imóveis.'; end if;

  update visitas set conf_nome = left(trim(p_nome), 120), conf_telefone = left(trim(p_telefone), 30),
    conf_email = lower(trim(p_email)), confirmado_em = now()
  where id = v.id;
  return public.visita_publica(p_token);
end;
$$;

-- p_avaliacoes = [{"id": "<uuid>", "visitou": true, "nota": 1-5, "interesse": "sim" | "talvez" | "nao", "comentario": "..."}]
-- Quem não confirmou antes (recebeu a pesquisa pelo WhatsApp) informa telefone e e-mail aqui.
create or replace function public.visita_avaliar(p_token text, p_avaliacoes jsonb, p_nota_atendimento int, p_comentario text,
  p_nome text default null, p_telefone text default null, p_email text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v visitas%rowtype; r jsonb; erro text; primeira timestamptz;
begin
  select * into v from visitas where token = p_token;
  if not found then raise exception 'Link de visita não encontrado.'; end if;
  if v.cancelada then raise exception 'Esta visita foi cancelada.'; end if;
  if v.avaliado_em is not null then raise exception 'Recebemos a sua avaliação. Obrigado!'; end if;
  select min(data_hora) into primeira from visita_imoveis where visita_id = v.id;
  if primeira > now() then raise exception 'A avaliação abre depois do horário da visita.'; end if;
  if p_nota_atendimento is not null and p_nota_atendimento not between 1 and 5 then raise exception 'Nota inválida.'; end if;
  if v.conf_email is null then
    if coalesce(trim(p_nome), '') = '' then raise exception 'Informe o seu nome.'; end if;
    erro := public.visita_contato_ok(p_telefone, trim(p_email));
    if erro is not null then raise exception '%', erro; end if;
    update visitas set conf_nome = left(trim(p_nome), 120), conf_telefone = left(trim(p_telefone), 30), conf_email = lower(trim(p_email))
    where id = v.id;
  end if;
  if jsonb_typeof(p_avaliacoes) is distinct from 'array' then raise exception 'Avaliação inválida.'; end if;

  for r in select * from jsonb_array_elements(p_avaliacoes) loop
    update visita_imoveis set
      visitou = (r ->> 'visitou')::boolean,
      nota = case when (r ->> 'visitou')::boolean and (r ->> 'nota')::int between 1 and 5 then (r ->> 'nota')::int end,
      interesse = case when (r ->> 'visitou')::boolean and r ->> 'interesse' in ('sim', 'talvez', 'nao') then r ->> 'interesse' end,
      comentario = left(nullif(trim(r ->> 'comentario'), ''), 1000)
    where id = nullif(r ->> 'id', '')::uuid and visita_id = v.id;
  end loop;

  update visitas set aval_nota_atendimento = p_nota_atendimento, aval_comentario = left(nullif(trim(p_comentario), ''), 2000), avaliado_em = now()
  where id = v.id;
  return public.visita_publica(p_token);
end;
$$;

revoke all on function public.visita_publica(text) from public;
revoke all on function public.visita_confirmar(text, text, text, text, jsonb) from public;
revoke all on function public.visita_avaliar(text, jsonb, int, text, text, text, text) from public;
grant execute on function public.visita_publica(text) to anon, authenticated;
grant execute on function public.visita_confirmar(text, text, text, text, jsonb) to anon, authenticated;
grant execute on function public.visita_avaliar(text, jsonb, int, text, text, text, text) to anon, authenticated;

-- ---------- E-mail automático (só a função visitas-avaliacao, com a chave de serviço) ----------
-- Visitas com pelo menos um imóvel confirmado, 30 minutos depois do último imóvel confirmado, ainda sem avaliação e sem e-mail.
-- Não pega visitas de mais de 2 dias (para não mandar e-mail atrasado) e para depois de 5 tentativas com erro.
create or replace function public.visitas_para_avaliar()
returns table (id uuid, token text, nome text, email text, corretora text, imoveis jsonb)
language sql
stable
security definer
set search_path = public
as $$
  select v.id, v.token, coalesce(v.conf_nome, v.cliente_nome), v.conf_email, initcap(v.corretora),
    jsonb_agg(jsonb_build_object('referencia', i.referencia, 'endereco', i.endereco, 'data_hora', i.data_hora) order by i.data_hora)
  from visitas v join visita_imoveis i on i.visita_id = v.id and i.resposta = 'confirmo'
  where not v.cancelada and v.avaliado_em is null and v.aval_envio_em is null and v.conf_email is not null and v.aval_tentativas < 5
  group by v.id
  having max(i.data_hora) + interval '30 minutes' <= now() and max(i.data_hora) > now() - interval '2 days';
$$;

create or replace function public.visita_marcar_envio(p_id uuid, p_erro text)
returns void
language sql
security definer
set search_path = public
as $$
  update visitas set aval_envio_em = case when p_erro is null then now() end, aval_envio_erro = left(p_erro, 500),
    aval_tentativas = aval_tentativas + 1
  where id = p_id;
$$;

revoke all on function public.visitas_para_avaliar() from public, anon, authenticated;
revoke all on function public.visita_marcar_envio(uuid, text) from public, anon, authenticated;
grant execute on function public.visitas_para_avaliar() to service_role;
grant execute on function public.visita_marcar_envio(uuid, text) to service_role;

-- ---------- Relógio: a cada 5 minutos chama a função visitas-avaliacao ----------
-- Sem senha: a função só manda o que já está na hora e marca como enviado, então ser chamada a mais não muda nada.
create extension if not exists pg_net;
select cron.unschedule('visitas-avaliacao') where exists (select 1 from cron.job where jobname = 'visitas-avaliacao');
select cron.schedule('visitas-avaliacao', '*/5 * * * *', $cron$
  select net.http_post(
    url := 'https://qlwqluemvkqkohtklrct.supabase.co/functions/v1/visitas-avaliacao',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := '{}'::jsonb,
    timeout_milliseconds := 30000);
$cron$);
