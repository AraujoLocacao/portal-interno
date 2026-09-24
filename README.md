# Portal Interno | Araujo Locação

Portal interno da Araujo Locação: avisos, processos e estrutura da equipe.

- **Produção:** https://portal-interno-rust.vercel.app
- **Hospedagem:** Vercel (projeto `portal-interno`)
- **Banco de dados:** Supabase (projeto `portal-interno`, sa-east-1)

## Estrutura

- `index.html` — página principal do portal (estática, autocontida)
- `.env.example` — variáveis de ambiente necessárias (o `.env` real não é versionado)
- `supabase/avisos.sql` — tabela `avisos` do mural (leitura pública; publicar/excluir só para e-mails da tabela `gestores`, que entram pelo botão "Entrar (gerência)")
