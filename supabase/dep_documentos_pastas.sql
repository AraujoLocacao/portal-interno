-- Pastas nos documentos dos departamentos (departamento.html, aba "POP e documentos" / "Materiais").
-- Cada documento fora do POP pode ficar numa pasta (ex.: "Contratos", "Ebooks"); sem pasta, aparece em "Outros documentos".
-- Criado em 02/10/2026 para os materiais da Pós-locação, copiados da pasta "Pós locação Araujo" do Drive.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor, depois de supabase/departamentos.sql.

alter table public.dep_documentos add column if not exists pasta text check (char_length(pasta) between 1 and 80);
