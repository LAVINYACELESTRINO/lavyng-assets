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

-- volatile (não stable): precisa enxergar a filiação criada no mesmo comando
create or replace function public.is_member(g text) returns boolean
language sql volatile security definer set search_path = public as $$
  select exists (select 1 from public.members where group_id = g and user_id = auth.uid());
$$;

-- Quem cria um grupo vira membro dele automaticamente.
-- Roda ANTES do insert para que o app já consiga ler a casa que acabou de criar
-- (o insert devolve a linha, e a leitura exige ser membro). Só vale para grupo
-- que ainda não existe: tentar "criar" um id existente não dá acesso a ele.
create or replace function public.on_group_created() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.col = 'groups' and auth.uid() is not null
     and not exists (select 1 from public.docs where path = new.path) then
    insert into public.members (group_id, user_id) values (new.group_id, auth.uid())
    on conflict do nothing;
  end if;
  return new;
end $$;

drop trigger if exists docs_group_created on public.docs;
-- o nome "docs_group_created" vem depois de "docs_fill" em ordem alfabética,
-- então col/group_id já estão preenchidos quando este gatilho roda
create trigger docs_group_created before insert on public.docs
for each row execute function public.on_group_created();

-- Entrar num grupo pelo link de convite (?join=<gid>&k=<código>)
-- Se o grupo tem um código de convite (campo "invite"), o link precisa trazê-lo.
-- Grupos antigos, sem código, continuam aceitando o link só com o id até alguém gerar um link novo.
drop function if exists public.join_group(text);
create or replace function public.join_group(gid text, k text default null) returns boolean
language plpgsql security definer set search_path = public as $$
declare code text;
begin
  if auth.uid() is null then raise exception 'não autenticado'; end if;
  select data->>'invite' into code from public.docs where path = 'groups/' || gid;
  if not found then return false; end if;
  if code is not null and code is distinct from k
     and not exists (select 1 from public.members where group_id = gid and user_id = auth.uid()) then
    return false;
  end if;
  insert into public.members (group_id, user_id) values (gid, auth.uid()) on conflict do nothing;
  return true;
end $$;

-- Desliga a conta de uma pessoa do grupo: tira o acesso e solta o nome dela na lista
-- (os registros e saldos continuam). Se ninguém mais participa, o grupo é apagado.
create or replace function public.drop_member(gid text, uid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.docs set data = data || '{"userId":null}'::jsonb
   where group_id = gid and col = 'groups/' || gid || '/people' and data->>'userId' = uid::text;
  delete from public.members where group_id = gid and user_id = uid;
  if not exists (select 1 from public.members where group_id = gid) then
    delete from public.docs where group_id = gid;
  end if;
end $$;
revoke execute on function public.drop_member(text, uuid) from public, anon, authenticated;

-- Sair de um grupo
create or replace function public.leave_group(gid text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member(gid) then raise exception 'você não participa deste grupo'; end if;
  perform public.drop_member(gid, auth.uid());
end $$;

-- Tirar o acesso de outra pessoa. O link de convite muda na hora para ela não voltar pelo link antigo.
create or replace function public.remove_member(gid text, uid uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_member(gid) then raise exception 'você não participa deste grupo'; end if;
  if uid = auth.uid() then raise exception 'use sair do grupo'; end if;
  perform public.drop_member(gid, uid);
  update public.docs set data = data || jsonb_build_object('invite', replace(gen_random_uuid()::text, '-', ''))
   where path = 'groups/' || gid;
end $$;

-- Excluir a própria conta: sai de todos os grupos, apaga os dados privados e o login
create or replace function public.delete_account() returns void
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g text;
begin
  if me is null then raise exception 'não autenticado'; end if;
  for g in select group_id from public.members where user_id = me loop
    perform public.drop_member(g, me);
  end loop;
  delete from public.docs where owner = me;
  delete from auth.users where id = me;
end $$;

-- Mantém o projeto do plano gratuito acordado (chamado 1x por dia pelo cron da Vercel)
create or replace function public.ping() returns int
language sql stable set search_path = public as $$ select 1 $$;

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
revoke execute on function public.join_group(text, text), public.doc_merge(text, jsonb), public.is_member(text),
  public.leave_group(text), public.remove_member(text, uuid), public.delete_account() from public, anon;
grant execute on function public.join_group(text, text), public.doc_merge(text, jsonb), public.is_member(text),
  public.leave_group(text), public.remove_member(text, uuid), public.delete_account() to authenticated;
grant execute on function public.ping() to anon, authenticated;

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
