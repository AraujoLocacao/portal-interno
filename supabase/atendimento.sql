-- Atendimento (página atendimento.html): leads do dia por corretor e unidade, senhas e POP.
-- Tudo restrito: só gestores (tabela "gestores") e os e-mails da tabela "atendimento_acesso" leem e gravam.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de supabase/avisos.sql e supabase/pre_analise.sql
-- (usa a mesma tabela "corretoras", para cruzar depois leads com pré-análise, visitas e fechamentos).

create table if not exists public.atendimento_acesso (
  email text primary key
);

alter table public.atendimento_acesso enable row level security;
-- Sem policies: a lista de acessos não é exposta pela API.

create or replace function public.pode_atendimento()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_gestor() or exists (
    select 1 from public.atendimento_acesso
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

grant execute on function public.pode_atendimento() to anon, authenticated;

-- O atendimento também usa a lista de corretoras (e pode incluir/desativar corretores).
drop policy if exists "corretoras: acesso atendimento" on public.corretoras;
create policy "corretoras: acesso atendimento" on public.corretoras
  for all to authenticated using (public.pode_atendimento()) with check (public.pode_atendimento());

-- ---------- Leads ----------
create table if not exists public.unidades (
  nome text primary key check (char_length(nome) between 1 and 40),
  ativa boolean not null default true
);

-- Uma linha por dia + unidade + corretor, com a quantidade de leads.
create table if not exists public.leads_diarios (
  id uuid primary key default gen_random_uuid(),
  data date not null,
  unidade text not null references public.unidades (nome) on update cascade,
  corretora text not null references public.corretoras (nome) on update cascade,
  quantidade integer not null check (quantidade between 0 and 10000),
  criado_em timestamptz not null default now(),
  criado_por text default (auth.jwt() ->> 'email'),
  unique (data, unidade, corretora)
);

-- Ordem em que os corretores foram digitados no dia (o relatório repete essa ordem).
alter table public.leads_diarios add column if not exists ordem smallint not null default 0;

-- Lançamento de uma semana inteira (dados antigos, que só existem por semana): "data" = primeiro dia, "ate" = último dia.
-- Nos lançamentos diários normais "ate" fica vazio.
alter table public.leads_diarios add column if not exists ate date check (ate > data);

create index if not exists leads_diarios_data_idx on public.leads_diarios (data);
create index if not exists leads_diarios_corretora_idx on public.leads_diarios (corretora);

alter table public.unidades enable row level security;
alter table public.leads_diarios enable row level security;

drop policy if exists "unidades: acesso atendimento" on public.unidades;
create policy "unidades: acesso atendimento" on public.unidades
  for all to authenticated using (public.pode_atendimento()) with check (public.pode_atendimento());

drop policy if exists "leads_diarios: acesso atendimento" on public.leads_diarios;
create policy "leads_diarios: acesso atendimento" on public.leads_diarios
  for all to authenticated using (public.pode_atendimento()) with check (public.pode_atendimento());

revoke all on public.atendimento_acesso, public.unidades, public.leads_diarios from anon;
grant select, insert, update on public.unidades to authenticated;
grant select, insert, update, delete on public.leads_diarios to authenticated;

insert into public.unidades (nome) values ('ITAJAÍ'), ('NAVEGANTES')
on conflict do nothing;

-- Salva o dia inteiro de uma vez: apaga o que havia no dia e grava as linhas novas.
-- p_linhas = [{"unidade": "ITAJAÍ", "corretora": "MARIA", "quantidade": 5, "ordem": 0}, ...]
-- p_ate só é usado ao editar um lançamento semanal (mantém o fim da semana).
drop function if exists public.leads_salvar_dia(date, jsonb, date);
create or replace function public.leads_salvar_dia(p_data date, p_linhas jsonb, p_data_anterior date default null, p_ate date default null)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not public.pode_atendimento() then
    raise exception 'Sem permissão';
  end if;
  delete from public.leads_diarios where data = p_data or data = p_data_anterior;
  insert into public.leads_diarios (data, unidade, corretora, quantidade, ordem, ate)
  select p_data, l.unidade, l.corretora, l.quantidade, coalesce(l.ordem, 0), p_ate
    from jsonb_to_recordset(p_linhas) as l(unidade text, corretora text, quantidade integer, ordem smallint);
end;
$$;

revoke execute on function public.leads_salvar_dia(date, jsonb, date, date) from public, anon;
grant execute on function public.leads_salvar_dia(date, jsonb, date, date) to authenticated;

-- ---------- Senhas ----------
-- A senha em si fica criptografada no Vault do Supabase; a tabela guarda só sistema, link, usuário e a referência ao segredo.
create table if not exists public.atendimento_senhas (
  id uuid primary key default gen_random_uuid(),
  sistema text not null check (char_length(sistema) between 1 and 80),
  link text check (char_length(link) <= 300),
  usuario text check (char_length(usuario) <= 150),
  observacao text check (char_length(observacao) <= 500),
  segredo_id uuid,
  atualizado_em timestamptz not null default now(),
  atualizado_por text default (auth.jwt() ->> 'email')
);

alter table public.atendimento_senhas enable row level security;

drop policy if exists "atendimento_senhas: leitura" on public.atendimento_senhas;
create policy "atendimento_senhas: leitura" on public.atendimento_senhas
  for select to authenticated using (public.pode_atendimento());

revoke all on public.atendimento_senhas from anon, authenticated;
grant select (id, sistema, link, usuario, observacao, atualizado_em, atualizado_por) on public.atendimento_senhas to authenticated;

create or replace function public.atendimento_senha_salvar(p_id uuid, p_sistema text, p_link text, p_usuario text, p_observacao text, p_senha text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := p_id;
  v_segredo uuid;
begin
  if not public.pode_atendimento() then
    raise exception 'Sem permissão';
  end if;
  if v_id is null then
    insert into public.atendimento_senhas (sistema, link, usuario, observacao)
    values (p_sistema, nullif(p_link, ''), nullif(p_usuario, ''), nullif(p_observacao, ''))
    returning id into v_id;
  else
    update public.atendimento_senhas
       set sistema = p_sistema, link = nullif(p_link, ''), usuario = nullif(p_usuario, ''), observacao = nullif(p_observacao, ''),
           atualizado_em = now(), atualizado_por = auth.jwt() ->> 'email'
     where id = v_id
    returning segredo_id into v_segredo;
    if not found then
      raise exception 'Registro não encontrado';
    end if;
  end if;
  -- Senha vazia na edição = manter a atual.
  if coalesce(p_senha, '') <> '' then
    if v_segredo is null then
      v_segredo := vault.create_secret(p_senha, 'atendimento_senha_' || v_id, 'Senha do atendimento');
      update public.atendimento_senhas set segredo_id = v_segredo where id = v_id;
    else
      perform vault.update_secret(v_segredo, p_senha);
    end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.atendimento_senha_revelar(p_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_senha text;
begin
  if not public.pode_atendimento() then
    raise exception 'Sem permissão';
  end if;
  select d.decrypted_secret into v_senha
    from public.atendimento_senhas s
    join vault.decrypted_secrets d on d.id = s.segredo_id
   where s.id = p_id;
  return v_senha;
end;
$$;

create or replace function public.atendimento_senha_excluir(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_segredo uuid;
begin
  if not public.pode_atendimento() then
    raise exception 'Sem permissão';
  end if;
  delete from public.atendimento_senhas where id = p_id returning segredo_id into v_segredo;
  if v_segredo is not null then
    delete from vault.secrets where id = v_segredo;
  end if;
end;
$$;

revoke execute on function public.atendimento_senha_salvar(uuid, text, text, text, text, text), public.atendimento_senha_revelar(uuid), public.atendimento_senha_excluir(uuid) from public, anon;
grant execute on function public.atendimento_senha_salvar(uuid, text, text, text, text, text), public.atendimento_senha_revelar(uuid), public.atendimento_senha_excluir(uuid) to authenticated;

-- ---------- POP e documentos ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('atendimento', 'atendimento', false, 26214400, array[
  'application/pdf',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'image/png',
  'image/jpeg'
])
on conflict (id) do nothing;

drop policy if exists "atendimento: ler arquivos" on storage.objects;
create policy "atendimento: ler arquivos" on storage.objects
  for select to authenticated using (bucket_id = 'atendimento' and public.pode_atendimento());

drop policy if exists "atendimento: enviar arquivos" on storage.objects;
create policy "atendimento: enviar arquivos" on storage.objects
  for insert to authenticated with check (bucket_id = 'atendimento' and public.pode_atendimento());

drop policy if exists "atendimento: excluir arquivos" on storage.objects;
create policy "atendimento: excluir arquivos" on storage.objects
  for delete to authenticated using (bucket_id = 'atendimento' and public.pode_atendimento());

create table if not exists public.atendimento_documentos (
  id uuid primary key default gen_random_uuid(),
  titulo text not null check (char_length(titulo) between 1 and 120),
  categoria text not null default 'POP' check (categoria in ('POP', 'Outros')),
  caminho text not null unique,
  nome_arquivo text not null,
  tamanho bigint,
  enviado_em timestamptz not null default now(),
  enviado_por text default (auth.jwt() ->> 'email')
);

alter table public.atendimento_documentos enable row level security;

drop policy if exists "atendimento_documentos: acesso atendimento" on public.atendimento_documentos;
create policy "atendimento_documentos: acesso atendimento" on public.atendimento_documentos
  for all to authenticated using (public.pode_atendimento()) with check (public.pode_atendimento());

revoke all on public.atendimento_documentos from anon;
grant select, insert, update, delete on public.atendimento_documentos to authenticated;
