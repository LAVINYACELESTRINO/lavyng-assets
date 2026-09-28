-- Meio a Meio: schema do Supabase
-- Rode este arquivo inteiro uma vez no SQL Editor do projeto (Supabase > SQL Editor > New query).
-- Pode rodar de novo sem problema: tudo é criado com "if not exists" / "or replace".

-- Todos os registros do app ficam numa tabela de documentos JSON, endereçados por caminho:
--   groups/<gid>                       a casa/grupo
--   groups/<gid>/(people|tx|rec|setl)/<id>  pessoas, despesas, recorrentes e acertos do grupo
--   data/users/<uid>/<id>              dados privados de cada pessoa (receitas, cartões, contas só suas)
create table if not exists public.docs (
  path       text primary key,
  col        text not null,
  group_id   text,
  owner      uuid,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create index if not exists docs_col_idx on public.docs (col);
create index if not exists docs_group_idx on public.docs (group_id);

-- Quem participa de cada grupo
create table if not exists public.members (
  group_id   text not null,
  user_id    uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (group_id, user_id)
);

-- Deriva col / group_id / owner do caminho (o cliente não escolhe esses campos)
create or replace function public.docs_fill() returns trigger
language plpgsql set search_path = public as $$
declare parts text[]; n int;
begin
  if new.path !~ '^[A-Za-z0-9_.~:@+-]+(/[A-Za-z0-9_.~:@+-]+)*$' then
    raise exception 'caminho inválido: %', new.path;
  end if;
  parts := string_to_array(new.path, '/');
  n := array_length(parts, 1);
  if parts[1] = 'groups' and (n = 2 or (n = 4 and parts[3] in ('people','tx','rec','setl'))) then
    new.group_id := parts[2];
    new.owner := null;
  elsif parts[1] = 'data' and parts[2] = 'users' and n = 4 then
    new.owner := parts[3]::uuid;
    new.group_id := null;
  else
    raise exception 'caminho não permitido: %', new.path;
  end if;
  new.col := array_to_string(parts[1:n-1], '/');
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists docs_fill on public.docs;
create trigger docs_fill before insert or update on public.docs
for each row execute function public.docs_fill();

create or replace function public.is_member(g text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.members where group_id = g and user_id = auth.uid());
$$;

-- Quem cria um grupo vira membro dele automaticamente
create or replace function public.on_group_created() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.col = 'groups' and auth.uid() is not null then
    insert into public.members (group_id, user_id) values (new.group_id, auth.uid())
    on conflict do nothing;
  end if;
  return new;
end $$;

drop trigger if exists docs_group_created on public.docs;
create trigger docs_group_created after insert on public.docs
for each row execute function public.on_group_created();

-- Entrar num grupo pelo link de convite (?join=<gid>)
create or replace function public.join_group(gid text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'não autenticado'; end if;
  if not exists (select 1 from public.docs where path = 'groups/' || gid) then return false; end if;
  insert into public.members (group_id, user_id) values (gid, auth.uid()) on conflict do nothing;
  return true;
end $$;

-- Atualização parcial (mescla campos de primeiro nível), respeitando RLS
create or replace function public.doc_merge(p_path text, p_patch jsonb) returns setof public.docs
language sql security invoker set search_path = public as $$
  update public.docs set data = data || p_patch where path = p_path returning *;
$$;

-- Segurança (RLS)
alter table public.docs enable row level security;
alter table public.members enable row level security;

drop policy if exists docs_select on public.docs;
create policy docs_select on public.docs for select to authenticated
  using (owner = auth.uid() or (group_id is not null and public.is_member(group_id)));

drop policy if exists docs_insert on public.docs;
create policy docs_insert on public.docs for insert to authenticated
  with check (
    owner = auth.uid()
    or (group_id is not null and public.is_member(group_id))
    or col = 'groups'  -- criar um grupo novo (o id já existente cai em conflito e exige ser membro)
  );

drop policy if exists docs_update on public.docs;
create policy docs_update on public.docs for update to authenticated
  using (owner = auth.uid() or (group_id is not null and public.is_member(group_id)))
  with check (owner = auth.uid() or (group_id is not null and public.is_member(group_id)));

drop policy if exists members_select on public.members;
create policy members_select on public.members for select to authenticated
  using (user_id = auth.uid());

revoke all on public.docs, public.members from anon;
grant select, insert, update on public.docs to authenticated;
grant select on public.members to authenticated;
revoke execute on function public.join_group(text), public.doc_merge(text, jsonb), public.is_member(text) from public, anon;
grant execute on function public.join_group(text), public.doc_merge(text, jsonb), public.is_member(text) to authenticated;

-- Tempo real (a outra pessoa vê as mudanças na hora)
do $$ begin
  alter publication supabase_realtime add table public.docs;
exception when duplicate_object then null; end $$;

-- Anexos (notas fiscais, comprovantes): bucket privado, pasta = id do grupo
insert into storage.buckets (id, name, public, file_size_limit)
values ('anexos', 'anexos', false, 20971520)
on conflict (id) do nothing;

drop policy if exists anexos_select on storage.objects;
create policy anexos_select on storage.objects for select to authenticated
  using (bucket_id = 'anexos' and public.is_member((storage.foldername(name))[1]));

drop policy if exists anexos_insert on storage.objects;
create policy anexos_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'anexos' and public.is_member((storage.foldername(name))[1]));
