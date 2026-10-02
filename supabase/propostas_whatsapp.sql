-- Propostas recebidas no WhatsApp (conversas da gerência com cada corretora), lidas toda sexta às 18h.
-- Servem para comparar com as propostas lançadas em resultados_semanais (aba "Relatório semanal" do gerencia.html).
-- Só ficam os dados do imóvel: moradores, profissões, pet e o nome de quem foi aprovado não são guardados.

create table if not exists public.propostas_whatsapp (
  id uuid primary key default gen_random_uuid(),
  data date not null,
  hora time,
  corretora text not null references public.corretoras (nome) on update cascade,
  referencia text check (char_length(referencia) <= 60),
  aluguel text check (char_length(aluguel) <= 40),
  garantia text check (char_length(garantia) <= 60),
  -- Evita contar a mesma mensagem duas vezes: corretora|data|hora|referência.
  chave text not null unique check (char_length(chave) <= 200),
  lido_em timestamptz not null default now()
);

create index if not exists propostas_whatsapp_data_idx on public.propostas_whatsapp (data);

-- Uma linha por leitura: de quando até quando o WhatsApp foi lido e quantas propostas foram achadas.
create table if not exists public.propostas_whatsapp_leituras (
  id uuid primary key default gen_random_uuid(),
  de timestamptz not null,
  ate timestamptz not null check (ate >= de),
  encontradas integer not null default 0,
  novas integer not null default 0,
  obs text check (char_length(obs) <= 1000),
  lido_em timestamptz not null default now()
);

alter table public.propostas_whatsapp enable row level security;
alter table public.propostas_whatsapp_leituras enable row level security;

drop policy if exists "propostas_whatsapp: só gerência" on public.propostas_whatsapp;
create policy "propostas_whatsapp: só gerência" on public.propostas_whatsapp
  for all to authenticated using (public.is_gestor()) with check (public.is_gestor());

drop policy if exists "propostas_whatsapp_leituras: só gerência" on public.propostas_whatsapp_leituras;
create policy "propostas_whatsapp_leituras: só gerência" on public.propostas_whatsapp_leituras
  for all to authenticated using (public.is_gestor()) with check (public.is_gestor());

revoke all on public.propostas_whatsapp, public.propostas_whatsapp_leituras from anon;
grant select, insert, update, delete on public.propostas_whatsapp, public.propostas_whatsapp_leituras to authenticated;
