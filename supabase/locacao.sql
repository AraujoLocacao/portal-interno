-- Locação (página locacao.html): contratos de locação do mês, com os cálculos da planilha "RANKING 2026",
-- ranking por corretor, garantias e captadoras, calculadoras, senhas e POP.
-- Tudo restrito: só gestores (tabela "gestores") e os e-mails da tabela "locacao_acesso" leem e gravam.
-- Os dados dos clientes ficam só aqui no banco, nunca no repositório (que é público).
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de avisos.sql, pre_analise.sql e atendimento.sql
-- (usa as mesmas tabelas "corretoras", "garantias" e "unidades", para cruzar depois com leads, análises e resultados).

create table if not exists public.locacao_acesso (
  email text primary key
);

alter table public.locacao_acesso enable row level security;
-- Sem policies: a lista de acessos não é exposta pela API.

create or replace function public.pode_locacao()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_gestor() or exists (
    select 1 from public.locacao_acesso
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

grant execute on function public.pode_locacao() to anon, authenticated;

-- A locação só lê as listas de corretores, unidades e garantias (quem cadastra é a gerência, o atendimento e a pré-análise).
drop policy if exists "corretoras: leitura locação" on public.corretoras;
create policy "corretoras: leitura locação" on public.corretoras
  for select to authenticated using (public.pode_locacao());

drop policy if exists "unidades: leitura locação" on public.unidades;
create policy "unidades: leitura locação" on public.unidades
  for select to authenticated using (public.pode_locacao());

drop policy if exists "garantias: leitura locação" on public.garantias;
create policy "garantias: leitura locação" on public.garantias
  for select to authenticated using (public.pode_locacao());

-- Garantias que aparecem na planilha de locações e ainda não estavam na lista.
insert into public.garantias (nome) values ('TOKIO'), ('TOO'), ('ALUGUEL ANTECIPADO')
on conflict do nothing;

-- ---------- Locações ----------
-- Uma linha por contrato, como na planilha. Os valores calculados (taxa de locação, base de cálculo,
-- corretora 25%, Stefani 10%, Du 1%, cap. imob. 5% e age. novo 8%) não são gravados: a página calcula.
create table if not exists public.locacoes (
  id uuid primary key default gen_random_uuid(),
  data date not null,
  referencia text not null check (char_length(referencia) between 1 and 20),
  unidade text not null references public.unidades (nome) on update cascade,
  corretora text not null references public.corretoras (nome) on update cascade,
  assinado boolean not null default false,
  proponente text not null check (char_length(proponente) between 1 and 200),
  garantia text references public.garantias (nome) on update cascade, -- vazio = não informada
  vgl numeric(12,2) not null check (vgl between 0 and 10000000),
  percentual numeric(5,2) not null check (percentual > 0 and percentual <= 200),
  captadora text check (char_length(captadora) <= 40),
  captacao_pos boolean not null default false,
  observacao text check (char_length(observacao) <= 500),
  ordem integer not null default 0,
  criado_em timestamptz not null default now(),
  criado_por text default (auth.jwt() ->> 'email')
);

create index if not exists locacoes_data_idx on public.locacoes (data);
create index if not exists locacoes_corretora_idx on public.locacoes (corretora);

-- Bonificação do mês por corretor (na planilha é digitada à mão no quadro do ranking).
create table if not exists public.locacao_bonificacoes (
  mes date not null check (extract(day from mes) = 1),
  corretora text not null references public.corretoras (nome) on update cascade,
  valor numeric(12,2) not null check (valor between 0 and 1000000),
  atualizado_em timestamptz not null default now(),
  atualizado_por text default (auth.jwt() ->> 'email'),
  primary key (mes, corretora)
);

alter table public.locacoes enable row level security;
alter table public.locacao_bonificacoes enable row level security;

drop policy if exists "locacoes: acesso locação" on public.locacoes;
create policy "locacoes: acesso locação" on public.locacoes
  for all to authenticated using (public.pode_locacao()) with check (public.pode_locacao());

drop policy if exists "locacao_bonificacoes: acesso locação" on public.locacao_bonificacoes;
create policy "locacao_bonificacoes: acesso locação" on public.locacao_bonificacoes
  for all to authenticated using (public.pode_locacao()) with check (public.pode_locacao());

-- A pré-análise preenche parte da planilha (aba "Locações" do pre-analise.html): lê e grava os contratos,
-- mas a página dela só mostra até a coluna "%" (sem taxa de locação e sem comissões) e não acessa as bonificações.
drop policy if exists "locacoes: acesso pré-análise" on public.locacoes;
create policy "locacoes: acesso pré-análise" on public.locacoes
  for all to authenticated using (public.pode_pre_analise()) with check (public.pode_pre_analise());

drop policy if exists "unidades: leitura pré-análise" on public.unidades;
create policy "unidades: leitura pré-análise" on public.unidades
  for select to authenticated using (public.pode_pre_analise());

revoke all on public.locacao_acesso, public.locacoes, public.locacao_bonificacoes from anon;
grant select, insert, update, delete on public.locacoes, public.locacao_bonificacoes to authenticated;

-- ---------- Senhas ----------
-- A senha em si fica criptografada no Vault do Supabase; a tabela guarda só sistema, link, usuário e a referência ao segredo.
create table if not exists public.locacao_senhas (
  id uuid primary key default gen_random_uuid(),
  sistema text not null check (char_length(sistema) between 1 and 80),
  link text check (char_length(link) <= 300),
  usuario text check (char_length(usuario) <= 150),
  observacao text check (char_length(observacao) <= 500),
  segredo_id uuid,
  atualizado_em timestamptz not null default now(),
  atualizado_por text default (auth.jwt() ->> 'email')
);

alter table public.locacao_senhas enable row level security;

drop policy if exists "locacao_senhas: leitura" on public.locacao_senhas;
create policy "locacao_senhas: leitura" on public.locacao_senhas
  for select to authenticated using (public.pode_locacao());

revoke all on public.locacao_senhas from anon, authenticated;
grant select (id, sistema, link, usuario, observacao, atualizado_em, atualizado_por) on public.locacao_senhas to authenticated;

create or replace function public.locacao_senha_salvar(p_id uuid, p_sistema text, p_link text, p_usuario text, p_observacao text, p_senha text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid := p_id;
  v_segredo uuid;
begin
  if not public.pode_locacao() then
    raise exception 'Sem permissão';
  end if;
  if v_id is null then
    insert into public.locacao_senhas (sistema, link, usuario, observacao)
    values (p_sistema, nullif(p_link, ''), nullif(p_usuario, ''), nullif(p_observacao, ''))
    returning id into v_id;
  else
    update public.locacao_senhas
       set sistema = p_sistema, link = nullif(p_link, ''), usuario = nullif(p_usuario, ''), observacao = nullif(p_observacao, ''),
           atualizado_em = now(), atualizado_por = auth.jwt() ->> 'email'
     where id = v_id
    returning segredo_id into v_segredo;
    if not found then
      raise exception 'Registro não encontrado';
    end if;
  end if;
  -- Senha vazia na edição = manter a atual.
  if coalesce(p_senha, '') <> '' then
    if v_segredo is null then
      v_segredo := vault.create_secret(p_senha, 'locacao_senha_' || v_id, 'Senha da locação');
      update public.locacao_senhas set segredo_id = v_segredo where id = v_id;
    else
      perform vault.update_secret(v_segredo, p_senha);
    end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.locacao_senha_revelar(p_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_senha text;
begin
  if not public.pode_locacao() then
    raise exception 'Sem permissão';
  end if;
  select d.decrypted_secret into v_senha
    from public.locacao_senhas s
    join vault.decrypted_secrets d on d.id = s.segredo_id
   where s.id = p_id;
  return v_senha;
end;
$$;

create or replace function public.locacao_senha_excluir(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_segredo uuid;
begin
  if not public.pode_locacao() then
    raise exception 'Sem permissão';
  end if;
  delete from public.locacao_senhas where id = p_id returning segredo_id into v_segredo;
  if v_segredo is not null then
    delete from vault.secrets where id = v_segredo;
  end if;
end;
$$;

revoke execute on function public.locacao_senha_salvar(uuid, text, text, text, text, text), public.locacao_senha_revelar(uuid), public.locacao_senha_excluir(uuid) from public, anon;
grant execute on function public.locacao_senha_salvar(uuid, text, text, text, text, text), public.locacao_senha_revelar(uuid), public.locacao_senha_excluir(uuid) to authenticated;

-- ---------- POP e documentos ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('locacao', 'locacao', false, 26214400, array[
  'application/pdf',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'image/png',
  'image/jpeg'
])
on conflict (id) do nothing;

drop policy if exists "locacao: ler arquivos" on storage.objects;
create policy "locacao: ler arquivos" on storage.objects
  for select to authenticated using (bucket_id = 'locacao' and public.pode_locacao());

drop policy if exists "locacao: enviar arquivos" on storage.objects;
create policy "locacao: enviar arquivos" on storage.objects
  for insert to authenticated with check (bucket_id = 'locacao' and public.pode_locacao());

drop policy if exists "locacao: excluir arquivos" on storage.objects;
create policy "locacao: excluir arquivos" on storage.objects
  for delete to authenticated using (bucket_id = 'locacao' and public.pode_locacao());

create table if not exists public.locacao_documentos (
  id uuid primary key default gen_random_uuid(),
  titulo text not null check (char_length(titulo) between 1 and 120),
  categoria text not null default 'POP' check (categoria in ('POP', 'Outros')),
  caminho text not null unique,
  nome_arquivo text not null,
  tamanho bigint,
  enviado_em timestamptz not null default now(),
  enviado_por text default (auth.jwt() ->> 'email')
);

alter table public.locacao_documentos enable row level security;

drop policy if exists "locacao_documentos: acesso locação" on public.locacao_documentos;
create policy "locacao_documentos: acesso locação" on public.locacao_documentos
  for all to authenticated using (public.pode_locacao()) with check (public.pode_locacao());

revoke all on public.locacao_documentos from anon;
grant select, insert, update, delete on public.locacao_documentos to authenticated;
