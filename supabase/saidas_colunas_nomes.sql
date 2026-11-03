-- Nomes das colunas do quadro Saídas e distratos revisados (03/11/2026, pedido da gerência): erros de digitação,
-- espaços em volta das barras, "PÓS-LOCAÇÃO" com hífen e sem o "- atualizado". As regras automáticas usam marcações
-- nas colunas (aviso_captacao, seguro_cancelar, painel), não o nome, então continuam valendo.

update public.saidas_colunas c set nome = n.novo
  from (values
    ('SOLICITAÇÃO DE DESOCUPAÇÃO VONLUNTARIA- NÃO RENOVAÇÃO', 'SOLICITAÇÃO DE DESOCUPAÇÃO VOLUNTÁRIA - NÃO RENOVAÇÃO'),
    ('AVISOS DE SAÍDA - PÓS LOCAÇÃO', 'AVISOS DE SAÍDA - PÓS-LOCAÇÃO'),
    ('PÓS LOCAÇÃO - EM ANÁLISE PÓS VISTORIA - REPAROS', 'PÓS-LOCAÇÃO - EM ANÁLISE PÓS-VISTORIA - REPAROS'),
    ('P/ CORREÇÃO - CHAU', 'PARA CORREÇÃO - CHAU'),
    ('GERAR BOLETOS NORMAL E ALPOP', 'GERAR BOLETOS (NORMAL E ALPOP)'),
    ('DISTRATOS PARA ENVIAR - PÓS LOCAÇÃO', 'DISTRATOS PARA ENVIAR - PÓS-LOCAÇÃO'),
    ('DISTRATOS COM DEVOLUÇÃO DE CAUÇÃO E/ OU PAGAMENTO - atualizado', 'DISTRATOS COM DEVOLUÇÃO DE CAUÇÃO E/OU PAGAMENTO'),
    ('AGUARDANDO PAGAMENTO DO INQUILINO PARA ACIONAMENTO/NEGATIVAÇÃO', 'AGUARDANDO PAGAMENTO DO INQUILINO PARA ACIONAMENTO / NEGATIVAÇÃO'),
    ('ASSINADOS E PAGOS ENCERRAR GARANTIA -', 'ASSINADOS E PAGOS - ENCERRAR GARANTIA'),
    ('ACIONADO PORTO SEGURO /CREDPAGO/ VELO/ ALPOP/KENLO/ONDA', 'ACIONADO PORTO SEGURO / CREDPAGO / VELO / ALPOP / KENLO / ONDA'),
    ('ACORDOS DE PARCELAMENTO/ MECOB', 'ACORDOS DE PARCELAMENTO / MECOB'),
    ('DISTRATOS EM COBRANÇA/ NEGATIVAR VALOR FALTANTE', 'DISTRATOS EM COBRANÇA / NEGATIVAR VALOR FALTANTE'),
    ('COBRANÇA JUDICIAL/AÇAO', 'COBRANÇA JUDICIAL / AÇÃO')
  ) as n (antigo, novo)
 where c.nome = n.antigo and not c.arquivada;
