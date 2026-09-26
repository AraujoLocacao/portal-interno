# Portal Interno | Araujo Locação

Portal interno da Araujo Locação: avisos, processos e estrutura da equipe.

- **Produção:** https://portal-interno-rust.vercel.app
- **Hospedagem:** Vercel (projeto `portal-interno`)
- **Banco de dados:** Supabase (projeto `portal-interno`, sa-east-1)

## Estrutura

- `index.html` — página principal do portal (estática, autocontida)
- `.env.example` — variáveis de ambiente necessárias (o `.env` real não é versionado)
- `supabase/avisos.sql` — tabela `avisos` do mural (leitura pública; publicar/excluir só para e-mails da tabela `gestores`, que entram pelo botão "Entrar (gerência)")
- `pre-analise.html` — controle de pré-análise (aba "Funções" do portal). Exige login; não contém dados, que ficam no Supabase
- `supabase/pre_analise.sql` — tabelas `pre_analises`, `corretoras` e `garantias`. Só gestores e os e-mails da tabela `pre_analise_acesso` leem e gravam
- `atendimento.html` — atendimento (aba "Funções"): leads do dia por corretor e unidade, senhas e POP. Exige login
- `supabase/atendimento.sql` — tabelas `leads_diarios`, `unidades`, `atendimento_senhas` e `atendimento_documentos`. Só gestores e os e-mails da tabela `atendimento_acesso` leem e gravam. Usa a mesma tabela `corretoras` da pré-análise
- `locacao.html` — locação (aba "Funções", área Operação do organograma): contratos do mês no formato da planilha "RANKING 2026" (taxa de locação, base de cálculo e comissões calculadas pela página, total por semana e do mês, linhas com REF repetida ou sem garantia em vermelho), ranking por corretora com bonificação, garantias, captadoras, calculadoras de aluguel proporcional e ALPOP, senhas e POP. Exige login
- `supabase/locacao.sql` — tabelas `locacoes`, `locacao_bonificacoes`, `locacao_senhas` e `locacao_documentos` (bucket privado `locacao`). Só gestores e os e-mails da tabela `locacao_acesso` leem e gravam. Usa as mesmas `corretoras`, `unidades` e `garantias`. A pré-análise também lê e grava `locacoes` (aba "Locações" do `pre-analise.html`, que mostra só até a coluna "%", sem taxa de locação e comissões) e não acessa as bonificações
- `gerencia.html` — "Meu painel", exclusivo da gerência (botão "Meu painel" no mural, depois de "Entrar (gerência)"): gráficos cruzando leads do atendimento, análises da pré-análise e os resultados semanais por corretor, mais o relatório semanal no formato da planilha
- `quadro.html` — quadro de contratos (esteira do antigo Trello "Contratos de Locação"), compartilhado entre Locação e Pré-análise: colunas, cartões com etiquetas, descrição, comentários e histórico, arrastar entre colunas. Cada locação nova da planilha vira cartão na coluna de entrada (gatilho no banco). Não mostra comissões
- `supabase/quadro.sql` — tabelas `quadro_colunas`, `quadro_etiquetas`, `quadro_cartoes`, `quadro_historico`, visão `quadro_comentarios`, função `quadro_mover` e gatilho `locacoes_cria_cartao`. Acesso: `pode_quadro()` = Locação ou Pré-análise (e gestores). O conteúdo do Trello (17 colunas, 588 cartões e o histórico desde out/2024) foi importado em 25/09/2026; anexos ficaram no Trello
- Fontes do "Meu painel": leads = Atendimento (`leads_diarios`); análises = Pré-análise (`pre_analises`); fechamentos (quantidade de locações) e VGL = Locação (`locacoes`, cada linha conta 1 fechamento); leads do corretor, visitas e propostas = lançamento semanal da gerência (`resultados_semanais`)
- `supabase/gerencia.sql` — tabela `resultados_semanais` (leads do corretor, visitas, propostas por corretor e semana; as colunas fechamentos e VGL não são mais usadas pela página) e função `resultados_salvar_semana`. Só gestores leem e gravam
- Aba "Apresentação" do `gerencia.html` — monta os slides da reunião semanal (segunda, 16h) com os números da semana, destaques sugeridos e fotos da galeria da equipe; apresenta em tela cheia e salva em PDF pela impressão do navegador. Usa `logo-araujo.jpg`
- `supabase/apresentacao.sql` — tabela `equipe` (galeria: nome, função, foto, ligação com o nome nos lançamentos), bucket privado `equipe` e tabela `apresentacoes` (textos de cada semana). Só gestores
- `supabase/pre_analise_validacoes.sql` — aba "Validações": tabelas `pre_analise_links` (atalhos: SPC Serasa, certidões federais e de todos os estados, processos) e `pre_analise_link_grupos` (nota de cada grupo), editáveis pela página
- `supabase/pre_analise_senhas_pop.sql` — aba "Senhas" (senhas criptografadas no Vault, lidas só pelas funções `senha_*`) e aba "POP" (bucket privado `pre-analise` + tabela `pre_analise_documentos`)
