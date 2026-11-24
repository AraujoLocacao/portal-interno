-- Trilha de treinamento da corretora de locação (treinamento.html, 20/11/2026).
-- O conteúdo da trilha (módulos, etapas e links do Drive "Corretora - Araujo Locação") fica na própria página.
-- Aqui fica o progresso (uma linha por etapa concluída, por e-mail de login) e, no fim do arquivo,
-- o conteúdo editável da trilha e o bucket dos arquivos enviados por ela.
-- Quem faz a trilha: quem tem acesso a Corretoras de locação (pode_departamento('corretoras-locacao')), mais a gerência.
-- A gerência (gestores) vê o progresso de todas na aba "Equipe" da página.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor, depois de departamentos.sql e visitas_por_corretora.sql.

create table if not exists public.treinamento_progresso (
  email text not null default lower(coalesce(auth.jwt() ->> 'email', '')) check (email = lower(email) and email <> ''),
  item text not null check (char_length(item) between 1 and 60),
  concluido_em timestamptz not null default now(),
  primary key (email, item)
);

alter table public.treinamento_progresso enable row level security;
revoke all on public.treinamento_progresso from anon, authenticated;
grant select, insert, delete on public.treinamento_progresso to authenticated;

-- Cada uma lê as próprias etapas; a gerência lê todas.
drop policy if exists "treinamento: ler" on public.treinamento_progresso;
create policy "treinamento: ler" on public.treinamento_progresso for select to authenticated
  using (email = lower(coalesce(auth.jwt() ->> 'email', '')) or public.is_gestor());

-- Etapas da "Prática acompanhada" (tipo 'pratica' no conteúdo da trilha, 24/11/2026): só a gestão confirma ou desfaz.
create or replace function public.treinamento_item_pratica(p_item text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.treinamento_conteudo c,
      jsonb_array_elements(c.modulos) m, jsonb_array_elements(m -> 'etapas') e
    where c.id = 'trilha' and e ->> 'id' = p_item and e ->> 'tipo' = 'pratica');
$$;
revoke all on function public.treinamento_item_pratica(text) from public, anon;
grant execute on function public.treinamento_item_pratica(text) to authenticated;

-- Marcar etapa: só para o próprio e-mail, com acesso à área, e nunca uma etapa da prática acompanhada.
drop policy if exists "treinamento: marcar" on public.treinamento_progresso;
create policy "treinamento: marcar" on public.treinamento_progresso for insert to authenticated
  with check (email = lower(coalesce(auth.jwt() ->> 'email', '')) and public.pode_departamento('corretoras-locacao')
              and not public.treinamento_item_pratica(item));

-- A gestão confirma etapas para qualquer pessoa (aba Equipe, botão "Prática").
drop policy if exists "treinamento: gestão confirma" on public.treinamento_progresso;
create policy "treinamento: gestão confirma" on public.treinamento_progresso for insert to authenticated
  with check (public.is_gestor());

-- Desmarcar: só as próprias (menos a prática acompanhada); a gestão desfaz qualquer uma.
drop policy if exists "treinamento: desmarcar" on public.treinamento_progresso;
create policy "treinamento: desmarcar" on public.treinamento_progresso for delete to authenticated
  using ((email = lower(coalesce(auth.jwt() ->> 'email', '')) and not public.treinamento_item_pratica(item))
         or public.is_gestor());

-- Ligação login → corretora (mesma tabela de visitas_por_corretora.sql; criada aqui também, se ainda não existir,
-- porque a aba Equipe e o nome no certificado usam). Uma linha por corretora: (e-mail, nome igual ao da tabela corretoras).
create table if not exists public.corretora_login (
  email text primary key check (email = lower(email)),
  corretora text not null references public.corretoras (nome) on update cascade
);
alter table public.corretora_login enable row level security;
revoke all on public.corretora_login from anon, authenticated;

-- Aba "Equipe": todas as pessoas liberadas em Corretoras de locação (mesmo quem ainda não começou),
-- com o nome da corretora (corretora_login) e as etapas concluídas. Só a gerência recebe linhas.
create or replace function public.treinamento_equipe()
returns table (email text, corretora text, itens text[], ultimo timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  with pessoas as (
    select lower(a.email) as email from public.departamento_acesso a where a.departamento = 'corretoras-locacao'
    union
    select t.email from public.treinamento_progresso t
  )
  select p.email, cl.corretora,
         coalesce(array_agg(t.item order by t.item) filter (where t.item is not null), '{}'::text[]),
         max(t.concluido_em)
  from pessoas p
  left join public.corretora_login cl on cl.email = p.email
  left join public.treinamento_progresso t on t.email = p.email
  where public.is_gestor()
  group by p.email, cl.corretora
  order by cl.corretora nulls last, p.email;
$$;

revoke all on function public.treinamento_equipe() from public, anon;
grant execute on function public.treinamento_equipe() to authenticated;

-- ---------- Conteúdo da trilha (editado na própria página, 22/11/2026) ----------
-- Uma linha só (id = 'trilha') com os módulos e as etapas em JSON. Quem faz a trilha lê; só a gerência grava,
-- pelo botão "Editar trilha". Enquanto não houver linha, a página usa o conteúdo inicial que vem no treinamento.html.
create table if not exists public.treinamento_conteudo (
  id text primary key default 'trilha' check (id = 'trilha'),
  modulos jsonb not null,
  atualizado_em timestamptz not null default now(),
  atualizado_por text default lower(coalesce(auth.jwt() ->> 'email', ''))
);
alter table public.treinamento_conteudo enable row level security;
revoke all on public.treinamento_conteudo from anon, authenticated;
grant select, insert, update on public.treinamento_conteudo to authenticated;

drop policy if exists "treinamento_conteudo: ler" on public.treinamento_conteudo;
create policy "treinamento_conteudo: ler" on public.treinamento_conteudo for select to authenticated
  using (public.pode_departamento('corretoras-locacao') or public.is_gestor());
drop policy if exists "treinamento_conteudo: criar" on public.treinamento_conteudo;
create policy "treinamento_conteudo: criar" on public.treinamento_conteudo for insert to authenticated
  with check (public.is_gestor());
drop policy if exists "treinamento_conteudo: alterar" on public.treinamento_conteudo;
create policy "treinamento_conteudo: alterar" on public.treinamento_conteudo for update to authenticated
  using (public.is_gestor()) with check (public.is_gestor());

-- ---------- Arquivos enviados pela trilha (bucket privado "treinamento") ----------
-- PDF, imagens e vídeos que a gerência envia ao editar uma etapa. Abrem dentro da trilha por link temporário.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('treinamento', 'treinamento', false, 52428800, array[
  'application/pdf', 'image/png', 'image/jpeg', 'image/webp', 'image/gif', 'video/mp4', 'video/webm', 'video/quicktime',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "treinamento: ler arquivos" on storage.objects;
create policy "treinamento: ler arquivos" on storage.objects for select to authenticated
  using (bucket_id = 'treinamento' and (public.pode_departamento('corretoras-locacao') or public.is_gestor()));
drop policy if exists "treinamento: enviar arquivos" on storage.objects;
create policy "treinamento: enviar arquivos" on storage.objects for insert to authenticated
  with check (bucket_id = 'treinamento' and public.is_gestor());
-- Trocar um arquivo com o mesmo nome (ex.: páginas do material, em treinamento/paginas/p13.jpg).
drop policy if exists "treinamento: trocar arquivos" on storage.objects;
create policy "treinamento: trocar arquivos" on storage.objects for update to authenticated
  using (bucket_id = 'treinamento' and public.is_gestor()) with check (bucket_id = 'treinamento' and public.is_gestor());
drop policy if exists "treinamento: excluir arquivos" on storage.objects;
create policy "treinamento: excluir arquivos" on storage.objects for delete to authenticated
  using (bucket_id = 'treinamento' and public.is_gestor());
