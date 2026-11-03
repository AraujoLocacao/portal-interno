-- Anexos do quadro Saídas e distratos (03/11/2026): bucket privado "saidas", pasta = id do cartão.
-- Os anexos dos cartões em uso foram copiados do Trello; os novos são enviados pela página (botão "Anexar arquivo").
-- O cartão guarda a lista em saidas_cartoes.anexos: [{"nome", "url" (Trello, se veio de lá), "caminho" (no bucket), "data", "por"}].
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de saidas.sql.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('saidas', 'saidas', false, 52428800, null)
on conflict (id) do update set public = false, file_size_limit = 52428800, allowed_mime_types = null;

drop policy if exists "saidas: leitura" on storage.objects;
create policy "saidas: leitura" on storage.objects
  for select to authenticated using (bucket_id = 'saidas' and public.pode_saidas());
drop policy if exists "saidas: envio" on storage.objects;
create policy "saidas: envio" on storage.objects
  for insert to authenticated with check (bucket_id = 'saidas' and public.pode_saidas());
drop policy if exists "saidas: exclusão" on storage.objects;
create policy "saidas: exclusão" on storage.objects
  for delete to authenticated using (bucket_id = 'saidas' and public.pode_saidas());
