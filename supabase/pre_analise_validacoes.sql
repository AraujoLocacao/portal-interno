-- Aba "Validações" de pre-analise.html: atalhos para os sites de consulta (SPC Serasa, certidões, processos).
-- Mesmo acesso da pré-análise: função public.pode_pre_analise() (ver supabase/pre_analise.sql).
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor, depois de supabase/pre_analise.sql.

create table if not exists public.pre_analise_links (
  id uuid primary key default gen_random_uuid(),
  grupo text not null check (char_length(grupo) between 1 and 40),
  nome text not null check (char_length(nome) between 1 and 80),
  url text not null check (url ~* '^https?://' and char_length(url) <= 300),
  descricao text check (char_length(descricao) <= 200),
  ordem int not null default 0
);

alter table public.pre_analise_links enable row level security;

drop policy if exists "pre_analise_links: acesso pré-análise" on public.pre_analise_links;
create policy "pre_analise_links: acesso pré-análise" on public.pre_analise_links
  for all to authenticated using (public.pode_pre_analise()) with check (public.pode_pre_analise());

revoke all on public.pre_analise_links from anon;
grant select, insert, update, delete on public.pre_analise_links to authenticated;

insert into public.pre_analise_links (grupo, nome, url, descricao, ordem)
select * from (values
  ('Consultas', 'SPC Serasa', 'https://sistema.spcbrasil.com.br/spc/', 'Consulta de crédito (CPF/CNPJ)', 10),
  ('Certidões', 'Federal SC', 'https://www2.trf4.jus.br/trf4/processos/certidao/index.php', 'Certidão judicial da Justiça Federal da 4ª Região (TRF4)', 20),
  ('Certidões', 'Estadual SC', 'https://certeproc2g.tjsc.jus.br/', 'Certidão do Tribunal de Justiça de Santa Catarina (TJSC)', 30),
  ('Certidões', 'Criminal Estadual – SC (TJSC)', 'https://www.tjsc.jus.br/web/judicial/certidoes', 'Certidão criminal do Tribunal de Justiça de Santa Catarina', 31),
  ('Certidões', 'Criminal Estadual – RJ (TJRJ)', 'https://www3.tjrj.jus.br/CJE/', 'Certidão criminal do Tribunal de Justiça do Rio de Janeiro', 32),
  ('Certidões', 'Criminal Federal – RJ (TRF2)', 'https://certidoes.trf2.jus.br/certidoes/#/principal/solicitar', 'Certidão criminal da Justiça Federal da 2ª Região (TRF2)', 33),
  ('Processos', 'Escavador', 'https://www.escavador.com/', 'Consulta de processos', 40)
) as v(grupo, nome, url, descricao, ordem)
where not exists (select 1 from public.pre_analise_links);
