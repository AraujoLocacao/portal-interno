-- Senhas e POP/documentos do departamento de pré-análise (abas "Senhas" e "POP" de pre-analise.html).
-- Mesmo acesso da pré-análise: função public.pode_pre_analise() (ver supabase/pre_analise.sql).
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor, depois de supabase/pre_analise.sql.

-- ---------- Senhas ----------
-- A senha em si fica criptografada no Vault do Supabase; a tabela guarda só sistema, link, usuário e a referência ao segredo.
create table if not exists public.pre_analise_senhas (
  id uuid primary key default gen_random_uuid(),
  sistema text not null check (char_length(sistema) between 1 and 80),
  link text check (char_length(link) <= 300),
  usuario text check (char_length(usuario) <= 150),
  observacao text check (char_length(observacao) <= 500),
  segredo_id uuid,
  atualizado_em timestamptz not null default now(),
  atualizado_por text default (auth.jwt() ->> 'email')
);

alter table public.pre_analise_senhas enable row level security;

drop policy if exists "pre_analise_senhas: leitura" on public.pre_analise_senhas;
create policy "pre_analise_senhas: leitura" on public.pre_analise_senhas
  for select to authenticated using (public.pode_pre_analise());

revoke all on public.pre_analise_senhas from anon, authenticated;
grant select (id, sistema, link, usuario, observacao, atualizado_em, atualizado_por) on public.pre_analise_senhas to authenticated;

-- Gravar/revelar/excluir só pelas funções abaixo, que conferem o acesso antes de tocar no Vault.
create or replace function public.senha_salvar(p_id uuid, p_sistema text, p_link text, p_usuario text, p_observacao text, p_senha text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := p_id;
  v_segredo uuid;
begin
  if not public.pode_pre_analise() then
    raise exception 'Sem permissão';
  end if;
  if v_id is null then
    insert into public.pre_analise_senhas (sistema, link, usuario, observacao)
    values (p_sistema, nullif(p_link, ''), nullif(p_usuario, ''), nullif(p_observacao, ''))
    returning id into v_id;
  else
    update public.pre_analise_senhas
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
      v_segredo := vault.create_secret(p_senha, 'pre_analise_senha_' || v_id, 'Senha da pré-análise');
      update public.pre_analise_senhas set segredo_id = v_segredo where id = v_id;
    else
      perform vault.update_secret(v_segredo, p_senha);
    end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.senha_revelar(p_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_senha text;
begin
  if not public.pode_pre_analise() then
    raise exception 'Sem permissão';
  end if;
  select d.decrypted_secret into v_senha
    from public.pre_analise_senhas s
    join vault.decrypted_secrets d on d.id = s.segredo_id
   where s.id = p_id;
  return v_senha;
end;
$$;

create or replace function public.senha_excluir(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_segredo uuid;
begin
  if not public.pode_pre_analise() then
    raise exception 'Sem permissão';
  end if;
  delete from public.pre_analise_senhas where id = p_id returning segredo_id into v_segredo;
  if v_segredo is not null then
    delete from vault.secrets where id = v_segredo;
  end if;
end;
$$;

revoke execute on function public.senha_salvar(uuid, text, text, text, text, text), public.senha_revelar(uuid), public.senha_excluir(uuid) from public, anon;
grant execute on function public.senha_salvar(uuid, text, text, text, text, text), public.senha_revelar(uuid), public.senha_excluir(uuid) to authenticated;

-- ---------- POP e documentos ----------
-- Arquivos num bucket privado; a tabela guarda título e categoria para listar na página.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('pre-analise', 'pre-analise', false, 26214400, array[
  'application/pdf',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'image/png',
  'image/jpeg'
])
on conflict (id) do nothing;

drop policy if exists "pre-analise: ler arquivos" on storage.objects;
create policy "pre-analise: ler arquivos" on storage.objects
  for select to authenticated using (bucket_id = 'pre-analise' and public.pode_pre_analise());

drop policy if exists "pre-analise: enviar arquivos" on storage.objects;
create policy "pre-analise: enviar arquivos" on storage.objects
  for insert to authenticated with check (bucket_id = 'pre-analise' and public.pode_pre_analise());

drop policy if exists "pre-analise: excluir arquivos" on storage.objects;
create policy "pre-analise: excluir arquivos" on storage.objects
  for delete to authenticated using (bucket_id = 'pre-analise' and public.pode_pre_analise());

create table if not exists public.pre_analise_documentos (
  id uuid primary key default gen_random_uuid(),
  titulo text not null check (char_length(titulo) between 1 and 120),
  categoria text not null default 'POP' check (categoria in ('POP', 'Outros')),
  caminho text not null unique,
  nome_arquivo text not null,
  tamanho bigint,
  enviado_em timestamptz not null default now(),
  enviado_por text default (auth.jwt() ->> 'email')
);

alter table public.pre_analise_documentos enable row level security;

drop policy if exists "pre_analise_documentos: acesso pré-análise" on public.pre_analise_documentos;
create policy "pre_analise_documentos: acesso pré-análise" on public.pre_analise_documentos
  for all to authenticated using (public.pode_pre_analise()) with check (public.pode_pre_analise());

revoke all on public.pre_analise_documentos from anon;
grant select, insert, update, delete on public.pre_analise_documentos to authenticated;
