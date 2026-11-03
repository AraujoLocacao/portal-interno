-- Padronização dos títulos do quadro Saídas e distratos (03/11/2026, pedido da gerência): "REFERÊNCIA - LOCADOR X LOCATÁRIO".
-- Rodado uma vez, só nos cartões ativos cujo título antigo separa locatário e locador ("REF - LOCATÁRIO - PROPRI: LOCADOR").
-- Preenche referencia (com o /n do contrato), locador e locatario. Cada nome vai até o primeiro " - "; o resto do título antigo
-- (ex.: "NOTIFICAÇÃO SOBRE NÃO RENOVAÇÃO", "APTO 504") vai para o topo da descrição, e o título antigo fica no histórico.
-- Os demais (sem "PROP" no título) ficam para a equipe ajustar pelo filtro "Título fora do padrão" na página.

with t as (
  select id, titulo,
         upper(substring(titulo from '^\s*([A-Za-z]{0,3}\d{3,5}(?:/\d+)?)')) ref,
         regexp_match(regexp_replace(titulo, '^\s*[A-Za-z]{0,3}\d{3,5}(/\d+)?\s*[-–:.]*\s*', ''),
                      '^(.*?)\s*[-–.]*\s*\m(?:PROPRIET[AÁ]RI[OA]|PROPRI|PROP)\M\.?\s*:?\s*(.*)$', 'i') m
    from public.saidas_cartoes
   where not arquivado
), p as (
  select id, titulo, ref,
         regexp_replace(trim(regexp_replace(m[1], '\s+', ' ', 'g')), '^[\s\-–.]+|[\s\-–.]+$', '', 'g') a,
         regexp_replace(trim(regexp_replace(m[2], '\s+', ' ', 'g')), '^[\s\-–.]+|[\s\-–.]+$', '', 'g') b
    from t where m is not null and ref is not null
), n as (
  select id, titulo, ref,
         trim(split_part(b, ' - ', 1)) locador, trim(split_part(a, ' - ', 1)) locatario,
         trim(both ' -' from concat_ws(' - ', nullif(substr(a, length(split_part(a, ' - ', 1)) + 4), ''), nullif(substr(b, length(split_part(b, ' - ', 1)) + 4), ''))) extra
    from p
), ok as (
  select * from n where locador <> '' and locatario <> ''
), upd as (
  update public.saidas_cartoes k
     set referencia = ok.ref, locador = coalesce(k.locador, ok.locador), locatario = coalesce(k.locatario, ok.locatario),
         titulo = ok.ref || ' - ' || coalesce(k.locador, ok.locador) || ' X ' || coalesce(k.locatario, ok.locatario),
         descricao = case when ok.extra <> '' then 'Do título antigo: ' || ok.extra || E'\n\n' || k.descricao else k.descricao end,
         atualizado_em = now()
    from ok where ok.id = k.id
  returning k.id, ok.titulo antigo
)
insert into public.saidas_historico (cartao_id, tipo, texto, autor)
select id, 'editado', 'padronizou o título (antes: ' || antigo || ')', 'portal' from upd;
