-- Aba "Apresentação" do Meu painel (gerencia.html): galeria da equipe e apresentação da reunião semanal.
-- Exclusivo da gerência (e-mails da tabela "gestores"). As fotos ficam num bucket privado, nunca no repositório.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de avisos.sql, pre_analise.sql e gerencia.sql.

-- ---------- Galeria da equipe ----------
create table if not exists public.equipe (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (char_length(nome) between 1 and 80),
  funcao text not null default 'Corretora de Imóveis' check (char_length(funcao) between 1 and 80),
  -- Ligação com o nome usado nos lançamentos (leads, pré-análise e resultados), para achar a foto de cada corretor.
  corretora text unique references public.corretoras (nome) on update cascade on delete set null,
  foto text check (char_length(foto) <= 300),
  ativo boolean not null default true,
  criado_em timestamptz not null default now(),
  criado_por text default (auth.jwt() ->> 'email')
);

alter table public.equipe enable row level security;

drop policy if exists "equipe: só gerência" on public.equipe;
create policy "equipe: só gerência" on public.equipe
  for all to authenticated using (public.is_gestor()) with check (public.is_gestor());

revoke all on public.equipe from anon;
grant select, insert, update, delete on public.equipe to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('equipe', 'equipe', false, 10485760, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

drop policy if exists "equipe: ler fotos" on storage.objects;
create policy "equipe: ler fotos" on storage.objects
  for select to authenticated using (bucket_id = 'equipe' and public.is_gestor());

drop policy if exists "equipe: enviar fotos" on storage.objects;
create policy "equipe: enviar fotos" on storage.objects
  for insert to authenticated with check (bucket_id = 'equipe' and public.is_gestor());

drop policy if exists "equipe: excluir fotos" on storage.objects;
create policy "equipe: excluir fotos" on storage.objects
  for delete to authenticated using (bucket_id = 'equipe' and public.is_gestor());

-- ---------- Apresentações ----------
-- Os textos de cada apresentação (destaques, mensagens, foco da próxima semana), um registro por semana.
-- Os números não ficam aqui: vêm sempre dos lançamentos, na hora de montar os slides.
create table if not exists public.apresentacoes (
  semana date primary key,
  conteudo jsonb not null default '{}',
  atualizado_em timestamptz not null default now(),
  atualizado_por text default (auth.jwt() ->> 'email')
);

alter table public.apresentacoes enable row level security;

drop policy if exists "apresentacoes: só gerência" on public.apresentacoes;
create policy "apresentacoes: só gerência" on public.apresentacoes
  for all to authenticated using (public.is_gestor()) with check (public.is_gestor());

revoke all on public.apresentacoes from anon;
grant select, insert, update, delete on public.apresentacoes to authenticated;
