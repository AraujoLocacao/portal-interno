-- Mural de avisos compartilhado do Portal Interno.
-- Leitura pública (qualquer pessoa com o link do portal); publicar/excluir só para e-mails da tabela "gestores".
-- Rodar uma vez em: Supabase > portal-interno > SQL Editor.

create table if not exists public.gestores (
  email text primary key
);

insert into public.gestores (email) values ('gerencia@araujolocacao.com.br')
on conflict do nothing;

alter table public.gestores enable row level security;
-- Sem policies: a lista de gestores não é exposta pela API.

create or replace function public.is_gestor()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.gestores
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

grant execute on function public.is_gestor() to anon, authenticated;

create table if not exists public.avisos (
  id uuid primary key default gen_random_uuid(),
  titulo text not null check (char_length(titulo) between 1 and 70),
  texto text not null check (char_length(texto) between 1 and 320),
  tipo text not null default 'info' check (tipo in ('info', 'event', 'priority')),
  anexo text,
  criado_em timestamptz not null default now(),
  criado_por text default (auth.jwt() ->> 'email')
);

alter table public.avisos enable row level security;

drop policy if exists "avisos: leitura pública" on public.avisos;
create policy "avisos: leitura pública" on public.avisos
  for select to anon, authenticated using (true);

drop policy if exists "avisos: gestores publicam" on public.avisos;
create policy "avisos: gestores publicam" on public.avisos
  for insert to authenticated with check (public.is_gestor());

drop policy if exists "avisos: gestores excluem" on public.avisos;
create policy "avisos: gestores excluem" on public.avisos
  for delete to authenticated using (public.is_gestor());

grant select on public.avisos to anon, authenticated;
grant insert, delete on public.avisos to authenticated;

-- Avisos que antes eram fixos no código.
insert into public.avisos (titulo, texto, tipo, anexo, criado_em, criado_por)
select titulo, texto, tipo, anexo, now() - make_interval(secs => ordem), 'gerencia@araujolocacao.com.br' from (values
  (0, 'Bem-vindos ao Portal Interno', 'Este espaço reúne os avisos e materiais importantes da Araujo Locação. Consulte o mural com frequência para acompanhar as atualizações.', 'info', null),
  (1, 'Política de atendimento disponível', 'A política de atendimento já pode ser consultada na área de materiais internos. Utilize as orientações como referência no contato com nossos clientes.', 'priority', null),
  (2, 'Benefício Guia da Alma', 'Você conta com 4 sessões de terapia por mês, custeadas pela empresa. Consulte o guia para saber como acessar, fazer o cadastro e agendar.', 'event', 'guia')
) as v(ordem, titulo, texto, tipo, anexo)
where not exists (select 1 from public.avisos);
