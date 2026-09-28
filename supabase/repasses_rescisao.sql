-- Proprietário · Repasses: calculadora de rescisão (28/09/2026).
-- O código da calculadora fica no bucket privado "departamentos", em ferramentas/repasses/calculadora-rescisao.html
-- (fora do site público). A página departamento.html?d=repasses baixa o arquivo depois do login e abre num iframe isolado.
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de supabase/departamentos.sql.

-- Leitura da pasta ferramentas/<departamento>/ para quem tem acesso ao departamento.
-- Enviar e trocar o arquivo: só a gerência ("ferramentas" não é departamento, então ninguém mais passa nas outras regras).
drop policy if exists "departamentos: ler ferramentas" on storage.objects;
create policy "departamentos: ler ferramentas" on storage.objects
  for select to authenticated using (bucket_id = 'departamentos' and (storage.foldername(name))[1] = 'ferramentas' and public.pode_departamento((storage.foldername(name))[2]));

-- Quem usa a calculadora (além da gerência).
insert into public.departamento_acesso (email, departamento) values
  ('financeiro@araujolocacao.com.br', 'repasses'),
  ('supervisora@araujolocacao.com.br', 'repasses')
on conflict do nothing;
