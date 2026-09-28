-- Demais departamentos (página departamento.html?d=<slug>): demandas, senhas e POP de cada departamento do organograma
-- que ainda não tem página própria (SAC, Cadastro, Captação, Corretoras de locação, Financeiro, Pós-locação, Liderança).
-- Uma estrutura só para todos: cada linha diz de qual departamento é, e o acesso é conferido por departamento.
-- Acesso: gestores (tabela "gestores") veem todos; os demais e-mails entram na tabela "departamento_acesso", um por departamento.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de supabase/avisos.sql (função is_gestor).

create table if not exists public.departamentos (
  slug text primary key check (slug ~ '^[a-z0-9-]{2,40}$'),
  nome text not null check (char_length(nome) between 1 and 80)
);

insert into public.departamentos (slug, nome) values
  ('sac', 'SAC'),
  ('cadastro', 'Cadastro'),
  ('captacao', 'Corretoras de captação'),
  ('corretoras-locacao', 'Corretoras de locação'),
  ('boletos', 'Locatário · Boletos'),
  ('renovacao', 'Locatário · Renovação'),
  ('cobranca', 'Cobrança'),
  ('repasses', 'Proprietário · Repasses'),
  ('pos-locacao', 'Pós-locação'),
  ('financeiro-rh', 'Gestão Financeira / RH'),
  ('supervisao', 'Supervisão')
on conflict (slug) do update set nome = excluded.nome;

create table if not exists public.departamento_acesso (
  email text not null,
  departamento text not null references public.departamentos (slug) on update cascade on delete cascade,
  primary key (email, departamento)
);

alter table public.departamentos enable row level security;
alter table public.departamento_acesso enable row level security;
-- Sem policies: as listas não são expostas pela API.

create or replace function public.pode_departamento(p_departamento text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_gestor() or exists (
    select 1 from public.departamento_acesso
    where departamento = p_departamento
      and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

grant execute on function public.pode_departamento(text) to anon, authenticated;

-- ---------- Demandas ----------
-- Cada tarefa do departamento, ligada a uma das atividades do organograma.
create table if not exists public.dep_demandas (
  id uuid primary key default gen_random_uuid(),
  departamento text not null references public.departamentos (slug) on update cascade,
  atividade text not null check (char_length(atividade) between 1 and 120),
  titulo text not null check (char_length(titulo) between 1 and 160),
  referencia text check (char_length(referencia) <= 120),
  responsavel text check (char_length(responsavel) <= 80),
  prazo date,
  status text not null default 'A fazer' check (status in ('A fazer', 'Em andamento', 'Aguardando', 'Concluída')),
  observacao text check (char_length(observacao) <= 2000),
  criado_em timestamptz not null default now(),
  criado_por text default (auth.jwt() ->> 'email'),
  atualizado_em timestamptz not null default now(),
  concluido_em timestamptz
);

create index if not exists dep_demandas_dep_idx on public.dep_demandas (departamento, status);

-- Marca quando mudou e quando foi concluída.
create or replace function public.dep_demandas_carimbo()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.atualizado_em := now();
  if new.status = 'Concluída' and (tg_op = 'INSERT' or old.status is distinct from 'Concluída') then
    new.concluido_em := now();
  elsif new.status <> 'Concluída' then
    new.concluido_em := null;
  end if;
  return new;
end;
$$;

drop trigger if exists dep_demandas_carimbo on public.dep_demandas;
create trigger dep_demandas_carimbo before insert or update on public.dep_demandas
  for each row execute function public.dep_demandas_carimbo();

alter table public.dep_demandas enable row level security;

drop policy if exists "dep_demandas: acesso do departamento" on public.dep_demandas;
create policy "dep_demandas: acesso do departamento" on public.dep_demandas
  for all to authenticated using (public.pode_departamento(departamento)) with check (public.pode_departamento(departamento));

revoke all on public.departamentos, public.departamento_acesso, public.dep_demandas from anon;
grant select, insert, update, delete on public.dep_demandas to authenticated;

-- ---------- Senhas ----------
-- A senha em si fica criptografada no Vault do Supabase; a tabela guarda só sistema, link, usuário e a referência ao segredo.
create table if not exists public.dep_senhas (
  id uuid primary key default gen_random_uuid(),
  departamento text not null references public.departamentos (slug) on update cascade,
  sistema text not null check (char_length(sistema) between 1 and 80),
  link text check (char_length(link) <= 300),
  usuario text check (char_length(usuario) <= 150),
  observacao text check (char_length(observacao) <= 500),
  segredo_id uuid,
  atualizado_em timestamptz not null default now(),
  atualizado_por text default (auth.jwt() ->> 'email')
);

alter table public.dep_senhas enable row level security;

drop policy if exists "dep_senhas: leitura" on public.dep_senhas;
create policy "dep_senhas: leitura" on public.dep_senhas
  for select to authenticated using (public.pode_departamento(departamento));

revoke all on public.dep_senhas from anon, authenticated;
grant select (id, departamento, sistema, link, usuario, observacao, atualizado_em, atualizado_por) on public.dep_senhas to authenticated;

-- Gravar/revelar/excluir só pelas funções abaixo, que conferem o acesso ao departamento antes de tocar no Vault.
create or replace function public.dep_senha_salvar(p_departamento text, p_id uuid, p_sistema text, p_link text, p_usuario text, p_observacao text, p_senha text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := p_id;
  v_segredo uuid;
begin
  if not public.pode_departamento(p_departamento) then
    raise exception 'Sem permissão';
  end if;
  if v_id is null then
    insert into public.dep_senhas (departamento, sistema, link, usuario, observacao)
    values (p_departamento, p_sistema, nullif(p_link, ''), nullif(p_usuario, ''), nullif(p_observacao, ''))
    returning id into v_id;
  else
    update public.dep_senhas
       set sistema = p_sistema, link = nullif(p_link, ''), usuario = nullif(p_usuario, ''), observacao = nullif(p_observacao, ''),
           atualizado_em = now(), atualizado_por = auth.jwt() ->> 'email'
     where id = v_id and departamento = p_departamento
    returning segredo_id into v_segredo;
    if not found then
      raise exception 'Registro não encontrado';
    end if;
  end if;
  -- Senha vazia na edição = manter a atual.
  if coalesce(p_senha, '') <> '' then
    if v_segredo is null then
      v_segredo := vault.create_secret(p_senha, 'dep_senha_' || v_id, 'Senha do departamento ' || p_departamento);
      update public.dep_senhas set segredo_id = v_segredo where id = v_id;
    else
      perform vault.update_secret(v_segredo, p_senha);
    end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.dep_senha_revelar(p_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dep text;
  v_senha text;
begin
  select departamento into v_dep from public.dep_senhas where id = p_id;
  if v_dep is null or not public.pode_departamento(v_dep) then
    raise exception 'Sem permissão';
  end if;
  select d.decrypted_secret into v_senha
    from public.dep_senhas s
    join vault.decrypted_secrets d on d.id = s.segredo_id
   where s.id = p_id;
  return v_senha;
end;
$$;

create or replace function public.dep_senha_excluir(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dep text;
  v_segredo uuid;
begin
  select departamento into v_dep from public.dep_senhas where id = p_id;
  if v_dep is null or not public.pode_departamento(v_dep) then
    raise exception 'Sem permissão';
  end if;
  delete from public.dep_senhas where id = p_id returning segredo_id into v_segredo;
  if v_segredo is not null then
    delete from vault.secrets where id = v_segredo;
  end if;
end;
$$;

revoke execute on function public.dep_senha_salvar(text, uuid, text, text, text, text, text), public.dep_senha_revelar(uuid), public.dep_senha_excluir(uuid) from public, anon;
grant execute on function public.dep_senha_salvar(text, uuid, text, text, text, text, text), public.dep_senha_revelar(uuid), public.dep_senha_excluir(uuid) to authenticated;

-- ---------- POP e documentos ----------
-- Um bucket privado para todos; cada arquivo fica numa pasta com o nome do departamento (ex.: sac/<id>/pop.pdf).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('departamentos', 'departamentos', false, 26214400, array[
  'application/pdf',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'image/png',
  'image/jpeg'
])
on conflict (id) do nothing;

-- POP também pode ser uma página HTML: a página abre dentro do portal (iframe isolado), nunca direto do bucket.
update storage.buckets set allowed_mime_types = array[
  'application/pdf',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'image/png',
  'image/jpeg',
  'text/html'
] where id = 'departamentos';

drop policy if exists "departamentos: ler arquivos" on storage.objects;
create policy "departamentos: ler arquivos" on storage.objects
  for select to authenticated using (bucket_id = 'departamentos' and public.pode_departamento((storage.foldername(name))[1]));

drop policy if exists "departamentos: enviar arquivos" on storage.objects;
create policy "departamentos: enviar arquivos" on storage.objects
  for insert to authenticated with check (bucket_id = 'departamentos' and public.pode_departamento((storage.foldername(name))[1]));

drop policy if exists "departamentos: excluir arquivos" on storage.objects;
create policy "departamentos: excluir arquivos" on storage.objects
  for delete to authenticated using (bucket_id = 'departamentos' and public.pode_departamento((storage.foldername(name))[1]));

create table if not exists public.dep_documentos (
  id uuid primary key default gen_random_uuid(),
  departamento text not null references public.departamentos (slug) on update cascade,
  titulo text not null check (char_length(titulo) between 1 and 120),
  categoria text not null default 'POP' check (categoria in ('POP', 'Outros')),
  caminho text not null unique,
  nome_arquivo text not null,
  tamanho bigint,
  enviado_em timestamptz not null default now(),
  enviado_por text default (auth.jwt() ->> 'email'),
  check (caminho like departamento || '/%')
);

alter table public.dep_documentos enable row level security;

drop policy if exists "dep_documentos: acesso do departamento" on public.dep_documentos;
create policy "dep_documentos: acesso do departamento" on public.dep_documentos
  for all to authenticated using (public.pode_departamento(departamento)) with check (public.pode_departamento(departamento));

revoke all on public.dep_documentos from anon;
grant select, insert, update, delete on public.dep_documentos to authenticated;
