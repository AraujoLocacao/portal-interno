-- Anexos dos cartões da Captação (10/11/2026): fotos e PDFs, igual ao quadro Saídas e distratos.
-- Bucket privado "captacao", pasta = id do cartão. Só abre, envia e exclui quem pode ver o quadro do cartão
-- (a captadora dona, a gerência e o acesso geral), então os arquivos de um quadro não aparecem para as outras captadoras.
-- O cartão guarda a lista em captacao_cartoes.anexos: [{"nome", "caminho" (no bucket), "data", "por"}].
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de captacao.sql.

alter table public.captacao_cartoes add column if not exists anexos jsonb not null default '[]'::jsonb;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('captacao', 'captacao', false, 52428800, null)
on conflict (id) do update set public = false, file_size_limit = 52428800, allowed_mime_types = null;

-- O arquivo pertence ao cartão cujo id é a primeira pasta do caminho.
create or replace function public.pode_captacao_arquivo(p_nome text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.captacao_cartoes c
    where c.id::text = split_part(p_nome, '/', 1) and public.pode_captacao_quadro(c.quadro_id)
  );
$$;

revoke execute on function public.pode_captacao_arquivo(text) from public, anon;
grant execute on function public.pode_captacao_arquivo(text) to authenticated;

drop policy if exists "captacao: leitura" on storage.objects;
create policy "captacao: leitura" on storage.objects
  for select to authenticated using (bucket_id = 'captacao' and public.pode_captacao_arquivo(name));
drop policy if exists "captacao: envio" on storage.objects;
create policy "captacao: envio" on storage.objects
  for insert to authenticated with check (bucket_id = 'captacao' and public.pode_captacao_arquivo(name));
drop policy if exists "captacao: exclusão" on storage.objects;
create policy "captacao: exclusão" on storage.objects
  for delete to authenticated using (bucket_id = 'captacao' and public.pode_captacao_arquivo(name));
