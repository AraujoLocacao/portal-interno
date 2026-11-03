-- Limpeza e organização das etiquetas do quadro Saídas e distratos (03/11/2026, pedido da gerência).
-- Grupos (Prioridade, Cidade, Garantia, Situação) ordenam o seletor, o filtro e as etiquetas no cartão.
-- Repetidas viram uma só (os cartões antigos também); as sem uso há meses ficam "arquivadas": somem do seletor e do filtro,
-- mas continuam aparecendo nos cartões antigos. A que nunca foi usada é apagada.

alter table public.saidas_etiquetas add column if not exists grupo text not null default 'Situação'
  check (grupo in ('Prioridade', 'Cidade', 'Garantia', 'Situação'));
alter table public.saidas_etiquetas add column if not exists arquivada boolean not null default false;

-- Junta as repetidas: troca o id antigo pelo novo em todos os cartões e apaga a etiqueta antiga.
create or replace function pg_temp.juntar_etiqueta(p_de uuid, p_para uuid)
returns void language sql as $$
  update public.saidas_cartoes
     set etiquetas = array(select distinct case when x = p_de then p_para else x end from unnest(etiquetas) x)
   where p_de = any(etiquetas);
  delete from public.saidas_etiquetas where id = p_de;
$$;

select pg_temp.juntar_etiqueta(
  (select id from public.saidas_etiquetas where nome = 'Caução'),
  (select id from public.saidas_etiquetas where nome = 'CAUÇÃO'));
select pg_temp.juntar_etiqueta(
  (select id from public.saidas_etiquetas where nome = 'PROPRIETARIO CIENTE DO AVISO DE SAÍDA'),
  (select id from public.saidas_etiquetas where nome = 'PROPRIETÁRIO CIENTE'));

delete from public.saidas_etiquetas e
 where nome = 'Vistoria de Conferência Agendada'
   and not exists (select 1 from public.saidas_cartoes k where e.id = any(k.etiquetas));

update public.saidas_etiquetas set nome = 'URGENTE' where nome = '***URGENTE***';
update public.saidas_etiquetas set nome = 'EM REPAROS' where nome = 'Em reparos';
update public.saidas_etiquetas set nome = 'INQUILINO CIENTE' where nome = 'INQUILINO CIENTE.';
update public.saidas_etiquetas set nome = 'COM PENDÊNCIAS PÓS-LOCAÇÃO' where nome = 'COM PENDÊNCIAS PÓS LOCAÇÃO';

update public.saidas_etiquetas set grupo = 'Prioridade' where nome = 'URGENTE';
update public.saidas_etiquetas set grupo = 'Cidade' where nome in ('ITAJAÍ', 'NAVEGANTES');
update public.saidas_etiquetas set grupo = 'Garantia'
 where nome in ('ALPOP', 'AVALYST', 'CAUÇÃO', 'CONFIAX', 'CREDALUGA', 'CREDPAGO', 'FIADOR', 'LADO BOM', 'PORTO SEGURO',
                'POTTENCIAL', 'SEM GARANTIA', 'SEU FIADOR', 'TOKIO', 'TOO SEGUROS');

update public.saidas_etiquetas set arquivada = true
 where nome in ('AVALYST', 'IMÓVEL A VENDA', 'INQUILINO CIENTE', 'RESOLVENDO', 'RETOMADA DO IMÓVEL', 'VISTORIA DE SAÍDA AGENDADA');
