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
- `supabase/pre_analise_senhas_pop.sql` — aba "Senhas" (senhas criptografadas no Vault, lidas só pelas funções `senha_*`) e aba "POP" (bucket privado `pre-analise` + tabela `pre_analise_documentos`)
