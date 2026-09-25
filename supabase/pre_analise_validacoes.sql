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
  ('Certidões', 'Federal Unificada (CJF)', 'https://certidao-unificada.cjf.jus.br/#/solicitacao-certidao', 'Certidão da Justiça Federal de todas as regiões (TRF1 a TRF6) de uma vez', 15),
  ('Certidões', 'Federal SC', 'https://www2.trf4.jus.br/trf4/processos/certidao/index.php', 'Certidão judicial da Justiça Federal da 4ª Região (TRF4)', 20),
  ('Certidões', 'Estadual SC', 'https://certeproc2g.tjsc.jus.br/', 'Certidão do Tribunal de Justiça de Santa Catarina (TJSC)', 30),
  ('Certidões', 'Criminal Estadual – SC (TJSC)', 'https://www.tjsc.jus.br/web/judicial/certidoes', 'Certidão criminal do Tribunal de Justiça de Santa Catarina', 31),
  ('Certidões', 'Criminal Federal – RJ (TRF2)', 'https://certidoes.trf2.jus.br/certidoes/#/principal/solicitar', 'Certidão criminal da Justiça Federal da 2ª Região (TRF2)', 33),
  ('Certidões', 'Federal – TRF1', 'https://portal.trf1.jus.br/Servicos/Certidao/', 'Justiça Federal da 1ª Região: DF, GO, TO, MT, BA, PI, MA e Norte', 34),
  ('Certidões', 'Federal – TRF3 (SP/MS)', 'https://certidao.trf3.jus.br/', 'Justiça Federal da 3ª Região: São Paulo e Mato Grosso do Sul', 35),
  ('Certidões', 'Federal – TRF6 (MG)', 'https://certidao.trf6.jus.br/', 'Justiça Federal da 6ª Região: Minas Gerais', 36),
  ('Processos', 'Escavador', 'https://www.escavador.com/', 'Consulta de processos', 90)
) as v(grupo, nome, url, descricao, ordem)
where not exists (select 1 from public.pre_analise_links);

-- Certidões estaduais dos demais estados (SC fica no grupo "Certidões").
insert into public.pre_analise_links (grupo, nome, url, descricao, ordem)
select * from (values
  ('Certidões de outros estados', 'AC – Acre (TJAC)', 'https://certidoes.tjac.jus.br/', 'Certidão estadual (TJAC)', 41),
  ('Certidões de outros estados', 'AL – Alagoas (TJAL)', 'https://www2.tjal.jus.br/esaj/portal.do?servico=810100', 'Certidão estadual (TJAL)', 42),
  ('Certidões de outros estados', 'AP – Amapá (TJAP)', 'https://tucujuris.tjap.jus.br/tucujuris/pages/certidao-publica/certidao-publica.html', 'Certidão estadual (TJAP) · Site pode demorar a abrir', 43),
  ('Certidões de outros estados', 'AM – Amazonas (TJAM)', 'https://consultasaj.tjam.jus.br/sco/abrirCadastro.do', 'Certidão estadual (TJAM)', 44),
  ('Certidões de outros estados', 'BA – Bahia (TJBA)', 'https://www.tjba.jus.br/portal/certidoes/', 'Certidão estadual (TJBA)', 45),
  ('Certidões de outros estados', 'CE – Ceará (TJCE)', 'https://sirece.tjce.jus.br/sirece-web/nova/solicitacao.jsf', 'Certidão estadual (TJCE)', 46),
  ('Certidões de outros estados', 'DF – Distrito Federal (TJDFT)', 'https://www.tjdft.jus.br/servicos/certidoes/certidao-nada-consta', 'Certidão estadual (TJDFT)', 47),
  ('Certidões de outros estados', 'ES – Espírito Santo (TJES)', 'https://www.tjes.jus.br/certidao-negativa-2/', 'Certidão estadual (TJES)', 48),
  ('Certidões de outros estados', 'GO – Goiás (TJGO)', 'https://pjd.tjgo.jus.br/CertidaoNegativaPositivaPublica?PaginaAtual=1&TipoArea=1', 'Certidão estadual (TJGO)', 49),
  ('Certidões de outros estados', 'MA – Maranhão (TJMA)', 'http://jurisconsult.tjma.jus.br/#/certidao-generate-state-certificate-form', 'Certidão estadual (TJMA)', 50),
  ('Certidões de outros estados', 'MT – Mato Grosso (TJMT)', 'https://cidadao.tjmt.jus.br/Servicos/CertidaoNegativa/', 'Certidão estadual (TJMT) · Site do TJMT com instabilidade (set/2026)', 51),
  ('Certidões de outros estados', 'MS – Mato Grosso do Sul (TJMS)', 'https://esaj.tjms.jus.br/esaj/portal.do?servico=810000', 'Certidão estadual (TJMS)', 52),
  ('Certidões de outros estados', 'MG – Minas Gerais (TJMG)', 'https://rupe.tjmg.jus.br/rupe/justica/publico/certidoes/criarSolicitacaoCertidao.rupe?solicitacaoPublica=true', 'Certidão estadual (TJMG)', 53),
  ('Certidões de outros estados', 'PA – Pará (TJPA)', 'https://consultas.tjpa.jus.br/certidao/pages/pesquisaGeralCentralCertidao.action', 'Certidão estadual (TJPA) · Site pode demorar a abrir', 54),
  ('Certidões de outros estados', 'PB – Paraíba (TJPB)', 'https://www.tjpb.jus.br/servicos/solicitar-certidao', 'Certidão estadual (TJPB)', 55),
  ('Certidões de outros estados', 'PR – Paraná (TJPR)', 'https://www.tjpr.jus.br/certidoes', 'Certidão estadual (TJPR)', 56),
  ('Certidões de outros estados', 'PE – Pernambuco (TJPE)', 'https://certidoesunificadas.app.tjpe.jus.br/certidao-criminal-pf', 'Certidão estadual (TJPE)', 57),
  ('Certidões de outros estados', 'PI – Piauí (TJPI)', 'https://europa.tjpi.jus.br/certidao', 'Certidão estadual (TJPI)', 58),
  ('Certidões de outros estados', 'RJ – Rio de Janeiro (TJRJ)', 'https://www3.tjrj.jus.br/CJE/', 'Certidão estadual (TJRJ)', 59),
  ('Certidões de outros estados', 'RN – Rio Grande do Norte (TJRN)', 'https://www.tjrn.jus.br/certidoes/', 'Certidão estadual (TJRN)', 60),
  ('Certidões de outros estados', 'RS – Rio Grande do Sul (TJRS)', 'https://www.tjrs.jus.br/novo/processos-e-servicos/servicos-processuais/certidoes/', 'Certidão estadual (TJRS)', 61),
  ('Certidões de outros estados', 'RO – Rondônia (TJRO)', 'https://webapp.tjro.jus.br/certidaoonline/pages/cnpg.xhtml', 'Certidão estadual (TJRO)', 62),
  ('Certidões de outros estados', 'RR – Roraima (TJRR)', 'https://certidao.tjrr.jus.br/', 'Certidão estadual (TJRR)', 63),
  ('Certidões de outros estados', 'SP – São Paulo (TJSP)', 'https://esaj.tjsp.jus.br/sco/abrirCadastro.do', 'Certidão estadual (TJSP)', 64),
  ('Certidões de outros estados', 'SE – Sergipe (TJSE)', 'https://www.tjse.jus.br/portal/servicos/judiciais/certidao-judicial', 'Certidão estadual (TJSE)', 65),
  ('Certidões de outros estados', 'TO – Tocantins (TJTO)', 'https://eproc1.tjto.jus.br/eprocV2_prod_1grau/externo_controlador.php?acao=cj_online', 'Certidão estadual (TJTO)', 66)
) as v(grupo, nome, url, descricao, ordem)
where not exists (select 1 from public.pre_analise_links l where l.grupo = v.grupo);

-- Notas por grupo da aba Validações (ex.: orientação embaixo de "Certidões").
create table if not exists public.pre_analise_link_grupos (
  grupo text primary key check (char_length(grupo) between 1 and 40),
  nota text check (char_length(nota) <= 600)
);

alter table public.pre_analise_link_grupos enable row level security;

drop policy if exists "pre_analise_link_grupos: acesso pré-análise" on public.pre_analise_link_grupos;
create policy "pre_analise_link_grupos: acesso pré-análise" on public.pre_analise_link_grupos
  for all to authenticated using (public.pode_pre_analise()) with check (public.pode_pre_analise());

revoke all on public.pre_analise_link_grupos from anon;
grant select, insert, update, delete on public.pre_analise_link_grupos to authenticated;

insert into public.pre_analise_link_grupos (grupo, nota) values
  ('Certidões', 'Emitir certidões criminal e cível: estadual SC, federal e do estado de onde é o documento do cliente ou de onde possa ter aparecido algum processo.')
on conflict (grupo) do nothing;
