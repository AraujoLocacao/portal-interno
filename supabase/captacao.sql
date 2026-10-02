-- Captação (página captacao.html): um quadro privado por captadora, com a estrutura do Trello "Captação Itajaí".
-- A gerência (tabela "gestores") vê e cria todos os quadros. Cada captadora só vê o próprio quadro (e-mail do quadro).
-- Há um quadro "modelo" (modelo = true): colunas e etiquetas dele são copiadas quando a gerência cria um quadro novo.
-- Os dados de proprietários ficam só aqui no banco, nunca no repositório (que é público).
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor. Depende de avisos.sql (is_gestor) e departamentos.sql (senhas).

create table if not exists public.captacao_quadros (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (char_length(nome) between 1 and 80),
  email text check (email is null or char_length(email) <= 200), -- login da captadora dona do quadro
  modelo boolean not null default false,
  ativo boolean not null default true,
  posicao integer not null default 0,
  criado_em timestamptz not null default now()
);

create unique index if not exists captacao_quadros_um_modelo on public.captacao_quadros (modelo) where modelo;

-- Quem pode abrir o quadro: gerência, ou a captadora dona (quadro ativo e que não seja o modelo).
create or replace function public.pode_captacao_quadro(p_quadro uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_gestor() or exists (
    select 1 from public.captacao_quadros
    where id = p_quadro and not modelo and ativo
      and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

-- Tem algum acesso à Captação (para a página decidir se mostra o login ou o "sem acesso").
create or replace function public.pode_captacao()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_gestor() or exists (
    select 1 from public.captacao_quadros
    where not modelo and ativo and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

grant execute on function public.pode_captacao_quadro(uuid) to anon, authenticated;
grant execute on function public.pode_captacao() to anon, authenticated;

-- Aba "Acessos" da Captação: usa as senhas dos departamentos (dep_senhas, slug 'captacao') e os links úteis (dep_links).
-- Toda captadora com quadro ativo entra nelas, sem precisar estar na tabela departamento_acesso.
create or replace function public.pode_departamento(p_departamento text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_gestor() or exists (
    select 1 from public.departamento_acesso
    where departamento = p_departamento
      and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  ) or (p_departamento = 'captacao' and public.pode_captacao());
$$;

-- Grupo do acesso na aba "Acessos": vazio = sistema; 'curso' = cursos (treinamentos). Muda só pela função abaixo.
alter table public.dep_senhas add column if not exists grupo text check (grupo in ('curso'));
grant select (grupo) on public.dep_senhas to authenticated;

create or replace function public.dep_senha_grupo(p_id uuid, p_grupo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dep text;
begin
  select departamento into v_dep from public.dep_senhas where id = p_id;
  if v_dep is null or not public.pode_departamento(v_dep) then
    raise exception 'Sem permissão';
  end if;
  update public.dep_senhas set grupo = nullif(p_grupo, '') where id = p_id;
end;
$$;

revoke execute on function public.dep_senha_grupo(uuid, text) from public, anon;
grant execute on function public.dep_senha_grupo(uuid, text) to authenticated;

-- Links úteis de cada departamento (vídeos, tour virtual, planilhas). Ficam no banco porque o repositório é público.
create table if not exists public.dep_links (
  id uuid primary key default gen_random_uuid(),
  departamento text not null references public.departamentos (slug) on update cascade on delete cascade,
  titulo text not null check (char_length(titulo) between 1 and 120),
  url text not null check (url ~* '^https?://' and char_length(url) <= 1000),
  posicao integer not null default 0,
  criado_em timestamptz not null default now(),
  criado_por text default (auth.jwt() ->> 'email')
);

alter table public.dep_links enable row level security;
drop policy if exists "dep_links: acesso" on public.dep_links;
create policy "dep_links: acesso" on public.dep_links
  for all to authenticated using (public.pode_departamento(departamento)) with check (public.pode_departamento(departamento));
revoke all on public.dep_links from anon;
grant select, insert, update, delete on public.dep_links to authenticated;

create table if not exists public.captacao_colunas (
  id uuid primary key default gen_random_uuid(),
  quadro_id uuid not null references public.captacao_quadros (id) on delete cascade,
  nome text not null check (char_length(nome) between 1 and 120),
  posicao integer not null default 0,
  trello_id text,
  unique (id, quadro_id)
);

create index if not exists captacao_colunas_quadro_idx on public.captacao_colunas (quadro_id, posicao);

create table if not exists public.captacao_etiquetas (
  id uuid primary key default gen_random_uuid(),
  quadro_id uuid not null references public.captacao_quadros (id) on delete cascade,
  nome text not null check (char_length(nome) between 1 and 60),
  cor text not null default 'blue',
  trello_id text,
  unique (quadro_id, nome)
);

create table if not exists public.captacao_cartoes (
  id uuid primary key default gen_random_uuid(),
  quadro_id uuid not null references public.captacao_quadros (id) on delete cascade,
  coluna_id uuid not null,
  posicao double precision not null default 0,
  titulo text not null check (char_length(titulo) between 1 and 300),
  referencia text,
  descricao text not null default '' check (char_length(descricao) <= 20000),
  etiquetas uuid[] not null default '{}',
  modelo boolean not null default false, -- cartão-modelo (como os "templates" do Trello)
  trello_id text,
  trello_url text,
  anexos_trello integer not null default 0,
  criado_em timestamptz not null default now(),
  criado_por text default (auth.jwt() ->> 'email'),
  movido_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  -- a coluna tem de ser do mesmo quadro do cartão
  foreign key (coluna_id, quadro_id) references public.captacao_colunas (id, quadro_id)
);

create index if not exists captacao_cartoes_quadro_idx on public.captacao_cartoes (quadro_id, coluna_id);
create index if not exists captacao_cartoes_referencia_idx on public.captacao_cartoes (referencia);

create table if not exists public.captacao_historico (
  id uuid primary key default gen_random_uuid(),
  cartao_id uuid not null references public.captacao_cartoes (id) on delete cascade,
  tipo text not null check (tipo in ('comentario', 'criado', 'movido', 'arquivado', 'restaurado', 'editado')),
  texto text check (char_length(texto) <= 20000),
  de_coluna text,
  para_coluna text,
  autor text default (auth.jwt() ->> 'email'),
  criado_em timestamptz not null default now()
);

create index if not exists captacao_historico_cartao_idx on public.captacao_historico (cartao_id, criado_em);

create or replace view public.captacao_comentarios with (security_invoker = true) as
  select cartao_id, count(*)::int as comentarios from public.captacao_historico where tipo = 'comentario' group by cartao_id;

alter table public.captacao_quadros enable row level security;
alter table public.captacao_colunas enable row level security;
alter table public.captacao_etiquetas enable row level security;
alter table public.captacao_cartoes enable row level security;
alter table public.captacao_historico enable row level security;

-- Quadros: a gerência faz tudo; a captadora só enxerga o próprio.
drop policy if exists "captacao_quadros: gerência" on public.captacao_quadros;
create policy "captacao_quadros: gerência" on public.captacao_quadros
  for all to authenticated using (public.is_gestor()) with check (public.is_gestor());
drop policy if exists "captacao_quadros: a própria captadora" on public.captacao_quadros;
create policy "captacao_quadros: a própria captadora" on public.captacao_quadros
  for select to authenticated using (public.pode_captacao_quadro(id));

-- Colunas: a estrutura é da gerência (igual em todos os quadros); a captadora só lê.
drop policy if exists "captacao_colunas: leitura" on public.captacao_colunas;
create policy "captacao_colunas: leitura" on public.captacao_colunas
  for select to authenticated using (public.pode_captacao_quadro(quadro_id));
drop policy if exists "captacao_colunas: gerência" on public.captacao_colunas;
create policy "captacao_colunas: gerência" on public.captacao_colunas
  for all to authenticated using (public.is_gestor()) with check (public.is_gestor());

-- Etiquetas e cartões: a dona do quadro e a gerência.
drop policy if exists "captacao_etiquetas: acesso" on public.captacao_etiquetas;
create policy "captacao_etiquetas: acesso" on public.captacao_etiquetas
  for all to authenticated using (public.pode_captacao_quadro(quadro_id)) with check (public.pode_captacao_quadro(quadro_id));
drop policy if exists "captacao_cartoes: acesso" on public.captacao_cartoes;
create policy "captacao_cartoes: acesso" on public.captacao_cartoes
  for all to authenticated using (public.pode_captacao_quadro(quadro_id)) with check (public.pode_captacao_quadro(quadro_id));

-- Histórico: lê quem vê o cartão; comenta com o próprio e-mail; apaga só o próprio comentário.
-- Arquivar/restaurar também entram (o cartão arquivado sai do quadro, mas continua contando no relatório).
drop policy if exists "captacao_historico: leitura" on public.captacao_historico;
create policy "captacao_historico: leitura" on public.captacao_historico
  for select to authenticated using (exists (select 1 from public.captacao_cartoes c where c.id = cartao_id and public.pode_captacao_quadro(c.quadro_id)));
drop policy if exists "captacao_historico: comentar" on public.captacao_historico;
create policy "captacao_historico: comentar" on public.captacao_historico
  for insert to authenticated with check (tipo in ('comentario', 'criado', 'editado', 'arquivado', 'restaurado') and autor = auth.jwt() ->> 'email'
    and exists (select 1 from public.captacao_cartoes c where c.id = cartao_id and public.pode_captacao_quadro(c.quadro_id)));
drop policy if exists "captacao_historico: apagar o próprio comentário" on public.captacao_historico;
create policy "captacao_historico: apagar o próprio comentário" on public.captacao_historico
  for delete to authenticated using (tipo = 'comentario' and autor = auth.jwt() ->> 'email'
    and exists (select 1 from public.captacao_cartoes c where c.id = cartao_id and public.pode_captacao_quadro(c.quadro_id)));

revoke all on public.captacao_quadros, public.captacao_colunas, public.captacao_etiquetas, public.captacao_cartoes, public.captacao_historico, public.captacao_comentarios from anon;
grant select, insert, update, delete on public.captacao_quadros, public.captacao_colunas, public.captacao_etiquetas, public.captacao_cartoes to authenticated;
grant select, insert, delete on public.captacao_historico to authenticated;
grant select on public.captacao_comentarios to authenticated;

-- Move o cartão (coluna e posição, dentro do mesmo quadro) e registra no histórico.
create or replace function public.captacao_mover(p_cartao uuid, p_coluna uuid, p_posicao double precision)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_de uuid;
  v_quadro uuid;
begin
  select coluna_id, quadro_id into v_de, v_quadro from public.captacao_cartoes where id = p_cartao for update;
  if not found or not public.pode_captacao_quadro(v_quadro) then
    raise exception 'Sem permissão';
  end if;
  if not exists (select 1 from public.captacao_colunas where id = p_coluna and quadro_id = v_quadro) then
    raise exception 'Coluna de outro quadro';
  end if;
  update public.captacao_cartoes
     set coluna_id = p_coluna, posicao = p_posicao, atualizado_em = now(),
         movido_em = case when v_de <> p_coluna then now() else movido_em end
   where id = p_cartao;
  if v_de <> p_coluna then
    insert into public.captacao_historico (cartao_id, tipo, de_coluna, para_coluna, autor)
    select p_cartao, 'movido', (select nome from public.captacao_colunas where id = v_de), (select nome from public.captacao_colunas where id = p_coluna), auth.jwt() ->> 'email';
  end if;
end;
$$;

revoke execute on function public.captacao_mover(uuid, uuid, double precision) from public, anon;
grant execute on function public.captacao_mover(uuid, uuid, double precision) to authenticated;

-- Novo quadro (só a gerência): copia as colunas, as etiquetas e os cartões-modelo do quadro modelo.
create or replace function public.captacao_criar_quadro(p_nome text, p_email text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_modelo uuid;
  v_novo uuid;
  v_col record;
  v_mapa_col jsonb := '{}';
  v_mapa_etq jsonb := '{}';
  v_etq record;
  v_id uuid;
begin
  if not public.is_gestor() then
    raise exception 'Só a gerência cria quadros';
  end if;
  insert into public.captacao_quadros (nome, email, posicao)
  values (trim(p_nome), nullif(lower(trim(p_email)), ''), coalesce((select max(posicao) + 1 from public.captacao_quadros), 0))
  returning id into v_novo;
  select id into v_modelo from public.captacao_quadros where modelo;
  if v_modelo is null then
    return v_novo;
  end if;
  for v_col in select * from public.captacao_colunas where quadro_id = v_modelo order by posicao loop
    insert into public.captacao_colunas (quadro_id, nome, posicao, captado) values (v_novo, v_col.nome, v_col.posicao, v_col.captado) returning id into v_id;
    v_mapa_col := v_mapa_col || jsonb_build_object(v_col.id::text, v_id);
  end loop;
  for v_etq in select * from public.captacao_etiquetas where quadro_id = v_modelo loop
    insert into public.captacao_etiquetas (quadro_id, nome, cor) values (v_novo, v_etq.nome, v_etq.cor) returning id into v_id;
    v_mapa_etq := v_mapa_etq || jsonb_build_object(v_etq.id::text, v_id);
  end loop;
  insert into public.captacao_cartoes (quadro_id, coluna_id, posicao, titulo, descricao, etiquetas, modelo)
  select v_novo, (v_mapa_col ->> c.coluna_id::text)::uuid, c.posicao, c.titulo, c.descricao,
         coalesce((select array_agg((v_mapa_etq ->> e::text)::uuid) from unnest(c.etiquetas) e where v_mapa_etq ? e::text), '{}'),
         true
    from public.captacao_cartoes c where c.quadro_id = v_modelo and c.modelo;
  return v_novo;
end;
$$;

revoke execute on function public.captacao_criar_quadro(text, text) from public, anon;
grant execute on function public.captacao_criar_quadro(text, text) to authenticated;

-- Ao criar uma coluna no modelo, ela não vai sozinha para os quadros já criados: a página oferece "aplicar em todos".
create or replace function public.captacao_aplicar_colunas_do_modelo()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_modelo uuid;
begin
  if not public.is_gestor() then
    raise exception 'Só a gerência muda a estrutura';
  end if;
  select id into v_modelo from public.captacao_quadros where modelo;
  if v_modelo is null then
    return;
  end if;
  -- Coluna do modelo que falta num quadro => criada; as que existem (mesmo nome) ficam na posição do modelo.
  insert into public.captacao_colunas (quadro_id, nome, posicao, captado)
  select q.id, m.nome, m.posicao, m.captado
    from public.captacao_quadros q cross join public.captacao_colunas m
   where m.quadro_id = v_modelo and not q.modelo
     and not exists (select 1 from public.captacao_colunas c where c.quadro_id = q.id and lower(c.nome) = lower(m.nome));
  update public.captacao_colunas c set posicao = m.posicao, captado = m.captado
    from public.captacao_colunas m, public.captacao_quadros q
   where m.quadro_id = v_modelo and q.id = c.quadro_id and not q.modelo and lower(c.nome) = lower(m.nome);
end;
$$;

revoke execute on function public.captacao_aplicar_colunas_do_modelo() from public, anon;
grant execute on function public.captacao_aplicar_colunas_do_modelo() to authenticated;

-- ---------- Relatório semanal (antiga planilha "RELATÓRIO DE CAPTAÇÃO") ----------
-- Uma linha por captadora (o quadro dela), semana e cidade. "Total captado" = pós + novas, calculado na página.
-- A semana começa na segunda-feira, cortada no mês (ex.: 01 a 04/09), igual à planilha; "inicio" é o 1º dia dela.
create table if not exists public.captacao_relatorio (
  id uuid primary key default gen_random_uuid(),
  quadro_id uuid not null references public.captacao_quadros (id) on delete cascade,
  inicio date not null,
  cidade text not null check (cidade in ('Itajaí', 'Navegantes')),
  prospeccao integer check (prospeccao between 0 and 9999),
  atendimentos integer check (atendimentos between 0 and 9999),
  em_andamento integer check (em_andamento between 0 and 9999),
  pos_captados integer check (pos_captados between 0 and 9999),
  novas_captacoes integer check (novas_captacoes between 0 and 9999),
  referencias text check (char_length(referencias) <= 2000),
  atualizado_em timestamptz not null default now(),
  atualizado_por text default (auth.jwt() ->> 'email'),
  unique (quadro_id, inicio, cidade)
);

create index if not exists captacao_relatorio_inicio_idx on public.captacao_relatorio (inicio);

alter table public.captacao_relatorio enable row level security;
-- Cada captadora lê e grava só as próprias linhas; a gerência vê e corrige todas.
drop policy if exists "captacao_relatorio: acesso" on public.captacao_relatorio;
create policy "captacao_relatorio: acesso" on public.captacao_relatorio
  for all to authenticated using (public.pode_captacao_quadro(quadro_id)) with check (public.pode_captacao_quadro(quadro_id));
revoke all on public.captacao_relatorio from anon;
grant select, insert, update, delete on public.captacao_relatorio to authenticated;

-- ---------- Captações guardadas (o relatório não perde nada quando o cartão sai do quadro) ----------
-- Decisão da gerência em 29/09/2026: os quadros podem ser esvaziados (cartões arquivados, excluídos ou levados adiante)
-- sem mudar o relatório. Por isso, quando um cartão chega na coluna de captado, a captação é gravada aqui e fica.
-- Só sai se o cartão VOLTAR para uma coluna antes da de captado (foi engano).
alter table public.captacao_colunas add column if not exists captado boolean not null default false;
update public.captacao_colunas set captado = true where upper(nome) = 'CAPTADO' and not captado;
alter table public.captacao_cartoes add column if not exists arquivado_em timestamptz;

create table if not exists public.captacao_captados (
  id uuid primary key default gen_random_uuid(),
  quadro_id uuid not null references public.captacao_quadros (id) on delete cascade,
  cartao_id uuid unique references public.captacao_cartoes (id) on delete set null,
  referencia text,
  titulo text not null,
  cidade text not null check (cidade in ('Itajaí', 'Navegantes')),
  pos boolean not null default false,
  sem_cidade boolean not null default false,
  sem_tipo boolean not null default false,
  captado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create index if not exists captacao_captados_quadro_idx on public.captacao_captados (quadro_id, captado_em);

alter table public.captacao_captados enable row level security;
drop policy if exists "captacao_captados: leitura" on public.captacao_captados;
create policy "captacao_captados: leitura" on public.captacao_captados
  for select to authenticated using (public.pode_captacao_quadro(quadro_id));
-- Só a gerência apaga (para corrigir); quem grava é o gatilho abaixo.
drop policy if exists "captacao_captados: gerência apaga" on public.captacao_captados;
create policy "captacao_captados: gerência apaga" on public.captacao_captados
  for delete to authenticated using (public.is_gestor());
revoke all on public.captacao_captados from anon;
grant select, delete on public.captacao_captados to authenticated;

create or replace function public.captacao_registra_captado()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cap record;
  v_pos integer;
  v_nomes text;
  v_cidade text;
  v_ref text;
begin
  if new.modelo then
    return new;
  end if;
  select id, posicao into v_cap from public.captacao_colunas where quadro_id = new.quadro_id and captado order by posicao limit 1;
  if v_cap.id is null then
    return new;
  end if;
  select posicao into v_pos from public.captacao_colunas where id = new.coluna_id;
  -- Voltou para antes da coluna de captado: era engano, a captação sai.
  if v_pos < v_cap.posicao then
    delete from public.captacao_captados where cartao_id = new.id;
    return new;
  end if;
  select coalesce(string_agg(upper(e.nome), ' | '), '') into v_nomes from public.captacao_etiquetas e where e.id = any (new.etiquetas);
  v_cidade := case when v_nomes like '%NAVEGANTES%' then 'Navegantes' else 'Itajaí' end;
  v_ref := coalesce(nullif(new.referencia, ''), upper(substring(new.titulo from '^\s*([A-Za-z]{2,4}[0-9]{3,5})')));
  if new.coluna_id = v_cap.id and (tg_op = 'INSERT' or old.coluna_id is distinct from new.coluna_id) then
    -- Chegou em captado: grava (se já existia, mantém a data da primeira chegada).
    insert into public.captacao_captados (quadro_id, cartao_id, referencia, titulo, cidade, pos, sem_cidade, sem_tipo)
    values (new.quadro_id, new.id, v_ref, new.titulo, v_cidade, v_nomes ~ '(^|[^A-Z])P[ÓO]S([^A-Z]|$)',
            not (v_nomes like '%NAVEGANTES%' or v_nomes like '%ITAJA%'), not (v_nomes ~ '(^|[^A-Z])P[ÓO]S([^A-Z]|$)' or v_nomes like '%NOVA%'))
    on conflict (cartao_id) do update set referencia = excluded.referencia, titulo = excluded.titulo, cidade = excluded.cidade, pos = excluded.pos,
      sem_cidade = excluded.sem_cidade, sem_tipo = excluded.sem_tipo, atualizado_em = now();
  else
    -- Já captado (na coluna de captado ou depois dela): acompanha as correções de etiqueta e título.
    update public.captacao_captados
       set referencia = v_ref, titulo = new.titulo, cidade = v_cidade, pos = v_nomes ~ '(^|[^A-Z])P[ÓO]S([^A-Z]|$)',
           sem_cidade = not (v_nomes like '%NAVEGANTES%' or v_nomes like '%ITAJA%'),
           sem_tipo = not (v_nomes ~ '(^|[^A-Z])P[ÓO]S([^A-Z]|$)' or v_nomes like '%NOVA%'), atualizado_em = now()
     where cartao_id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists captacao_cartoes_captado on public.captacao_cartoes;
create trigger captacao_cartoes_captado after insert or update of coluna_id, etiquetas, titulo, referencia on public.captacao_cartoes
  for each row execute function public.captacao_registra_captado();

-- ---------- Minhas senhas (pessoais) ----------
-- Pedido da gerência em 29/09/2026: cada captadora guarda as próprias senhas. Só a DONA vê (nem a gerência).
-- A senha fica criptografada no Vault; a tabela guarda sistema, link, usuário e a referência ao segredo.
create table if not exists public.senhas_pessoais (
  id uuid primary key default gen_random_uuid(),
  dono text not null default lower(auth.jwt() ->> 'email'),
  departamento text not null default 'captacao',
  sistema text not null check (char_length(sistema) between 1 and 80),
  link text check (char_length(link) <= 300),
  usuario text check (char_length(usuario) <= 150),
  observacao text check (char_length(observacao) <= 500),
  segredo_id uuid,
  atualizado_em timestamptz not null default now()
);

create index if not exists senhas_pessoais_dono_idx on public.senhas_pessoais (dono);
alter table public.senhas_pessoais enable row level security;
drop policy if exists "senhas_pessoais: só a dona" on public.senhas_pessoais;
create policy "senhas_pessoais: só a dona" on public.senhas_pessoais
  for select to authenticated using (dono = lower(auth.jwt() ->> 'email'));
revoke all on public.senhas_pessoais from anon, authenticated;
grant select (id, departamento, sistema, link, usuario, observacao, atualizado_em) on public.senhas_pessoais to authenticated;

create or replace function public.pessoal_senha_salvar(p_id uuid, p_sistema text, p_link text, p_usuario text, p_observacao text, p_senha text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dono text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_id uuid := p_id;
  v_segredo uuid;
begin
  if v_dono = '' then
    raise exception 'Sem permissão';
  end if;
  if v_id is null then
    insert into public.senhas_pessoais (dono, sistema, link, usuario, observacao)
    values (v_dono, p_sistema, nullif(p_link, ''), nullif(p_usuario, ''), nullif(p_observacao, ''))
    returning id into v_id;
  else
    update public.senhas_pessoais
       set sistema = p_sistema, link = nullif(p_link, ''), usuario = nullif(p_usuario, ''), observacao = nullif(p_observacao, ''), atualizado_em = now()
     where id = v_id and dono = v_dono
    returning segredo_id into v_segredo;
    if not found then
      raise exception 'Registro não encontrado';
    end if;
  end if;
  -- Senha vazia na edição = manter a atual.
  if coalesce(p_senha, '') <> '' then
    if v_segredo is null then
      v_segredo := vault.create_secret(p_senha, 'senha_pessoal_' || v_id, 'Senha pessoal');
      update public.senhas_pessoais set segredo_id = v_segredo where id = v_id;
    else
      perform vault.update_secret(v_segredo, p_senha);
    end if;
  end if;
  return v_id;
end;
$$;

create or replace function public.pessoal_senha_revelar(p_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_senha text;
begin
  select d.decrypted_secret into v_senha
    from public.senhas_pessoais s
    join vault.decrypted_secrets d on d.id = s.segredo_id
   where s.id = p_id and s.dono = lower(coalesce(auth.jwt() ->> 'email', ''));
  return v_senha;
end;
$$;

create or replace function public.pessoal_senha_excluir(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_segredo uuid;
begin
  delete from public.senhas_pessoais where id = p_id and dono = lower(coalesce(auth.jwt() ->> 'email', '')) returning segredo_id into v_segredo;
  if not found then
    raise exception 'Registro não encontrado';
  end if;
  if v_segredo is not null then
    delete from vault.secrets where id = v_segredo;
  end if;
end;
$$;

revoke execute on function public.pessoal_senha_salvar(uuid, text, text, text, text, text), public.pessoal_senha_revelar(uuid), public.pessoal_senha_excluir(uuid) from public, anon;
grant execute on function public.pessoal_senha_salvar(uuid, text, text, text, text, text), public.pessoal_senha_revelar(uuid), public.pessoal_senha_excluir(uuid) to authenticated;

-- Materiais da Captação: usam os documentos dos departamentos (dep_documentos + bucket "departamentos", pasta captacao/).
-- Aceita também PowerPoint (apresentações de captação) e vídeo MP4 (ex.: vídeo narrado do cadastro, 02/10/2026).
-- Limite por arquivo: 50 MB, o máximo do plano gratuito do Supabase.
update storage.buckets set file_size_limit = 52428800, allowed_mime_types = array[
  'video/mp4',
  'application/pdf',
  'application/msword',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-excel',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.ms-powerpoint',
  'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'image/png',
  'image/jpeg',
  'text/html'
] where id = 'departamentos';

-- O quadro modelo (a estrutura do Trello é importada nele).
insert into public.captacao_quadros (nome, modelo, posicao)
select 'Modelo (estrutura do Trello)', true, -1
where not exists (select 1 from public.captacao_quadros where modelo);
