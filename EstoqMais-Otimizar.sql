-- EstoqMais: registros incrementais e leitura por mês. Não apaga o histórico anterior.
begin;
create table if not exists public.estoqmais_head(user_id uuid primary key references auth.users(id) on delete cascade,version bigint not null default 0,saved_at timestamptz not null default now(),meta jsonb not null default '{}',operation uuid);
create table if not exists public.estoqmais_records(user_id uuid not null references auth.users(id) on delete cascade,collection text not null check(collection in ('products','suppliers','purchases','moves','quotes','attachments')),id text not null,data jsonb not null,month text generated always as (case when collection='purchases' then left(data->>'date',7) else null end) stored,primary key(user_id,collection,id));
create index if not exists estoqmais_records_month on public.estoqmais_records(user_id,month) where collection='purchases';
create index if not exists estoqmais_records_product on public.estoqmais_records(user_id,(data->>'product')) where collection='purchases';
create table if not exists public.estoqmais_journal(user_id uuid not null references auth.users(id) on delete cascade,version bigint not null,saved_at timestamptz not null,before_meta jsonb not null,undo jsonb not null,primary key(user_id,version));
alter table public.estoqmais_head enable row level security;
alter table public.estoqmais_records enable row level security;
alter table public.estoqmais_journal enable row level security;
revoke all on public.estoqmais_head,public.estoqmais_records,public.estoqmais_journal from public,anon,authenticated;
grant select on public.estoqmais_head,public.estoqmais_records,public.estoqmais_journal to authenticated;
drop policy if exists own_head on public.estoqmais_head;create policy own_head on public.estoqmais_head for select to authenticated using((select auth.uid())=user_id);
drop policy if exists own_records on public.estoqmais_records;create policy own_records on public.estoqmais_records for select to authenticated using((select auth.uid())=user_id);
drop policy if exists own_journal on public.estoqmais_journal;create policy own_journal on public.estoqmais_journal for select to authenticated using((select auth.uid())=user_id);
create or replace function public.estoqmais_init() returns void language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); old public.estoqmais_state%rowtype; c text; x jsonb;
begin
 if u is null then raise exception 'authentication_required' using errcode='42501'; end if;
 perform pg_advisory_xact_lock(hashtextextended(u::text,0));
 if exists(select 1 from public.estoqmais_head where user_id=u) then return; end if;
 select * into old from public.estoqmais_state where user_id=u;
 if not found then return; end if;
 insert into public.estoqmais_head(user_id,version,saved_at,meta,operation) values(u,old.version,old.saved_at,old.data-array['products','suppliers','purchases','moves','quotes','attachments','_cloudOperation','_loadedMonths','_months','_allPurchases'],nullif(old.data->>'_cloudOperation','')::uuid);
 foreach c in array array['products','suppliers','purchases','moves','quotes','attachments'] loop
  for x in select value from jsonb_array_elements(coalesce(old.data->c,'[]'::jsonb)) loop
   if coalesce(x->>'id','')='' then raise exception 'missing_record_id'; end if;
   insert into public.estoqmais_records values(u,c,x->>'id',x);
  end loop;
 end loop;
end $$;
create or replace function public.estoqmais_read(p_month text default null,p_all boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); h public.estoqmais_head%rowtype; d jsonb; c text; a jsonb; months jsonb;
begin
 perform public.estoqmais_init();select * into h from public.estoqmais_head where user_id=u;
 if not found then return jsonb_build_object('exists',false); end if;
 if not p_all and (p_month is null or p_month !~ '^\d{4}(-(0[1-9]|1[0-2]))?$') then raise exception 'invalid_month'; end if;
 d:=h.meta;
 foreach c in array array['products','suppliers','purchases','moves','quotes','attachments'] loop
  select coalesce(jsonb_agg(data order by id),'[]'::jsonb) into a from public.estoqmais_records where user_id=u and collection=c and (c<>'purchases' or p_all or month=p_month or left(month,4)=p_month);
  d:=d||jsonb_build_object(c,a);
 end loop;
 select coalesce(jsonb_agg(m order by m),'[]'::jsonb) into months from(select distinct month m from public.estoqmais_records where user_id=u and collection='purchases' and month is not null) q;
 d:=d||jsonb_build_object('_months',months,'_loadedMonths',case when p_all then months else case when length(p_month)=4 then (select coalesce(jsonb_agg(value),'[]') from jsonb_array_elements(months) where left(value#>>'{}',4)=p_month) else jsonb_build_array(p_month) end end,'_allPurchases',p_all);
 return jsonb_build_object('exists',true,'version',h.version,'saved_at',h.saved_at,'operation',h.operation,'data',d);
end $$;
create or replace function public.estoqmais_patch(p_changes jsonb,p_meta jsonb,p_expected bigint,p_operation uuid) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); h public.estoqmais_head%rowtype; x jsonb; prior jsonb; changes jsonb:='[]'; t timestamptz:=clock_timestamp(); c text; k text; v jsonb;
begin
 if u is null then raise exception 'authentication_required' using errcode='42501'; end if;
 if p_operation is null or p_expected is null or p_expected<0 or jsonb_typeof(p_changes) is distinct from 'array' or jsonb_typeof(p_meta) is distinct from 'object' or octet_length(p_changes::text)>20971520 or octet_length(p_meta::text)>1048576 then raise exception 'invalid_patch'; end if;
 perform pg_advisory_xact_lock(hashtextextended(u::text,0));perform public.estoqmais_init();
 insert into public.estoqmais_head(user_id) values(u) on conflict do nothing;
 select * into h from public.estoqmais_head where user_id=u for update;
 if h.version=p_expected+1 and h.operation=p_operation then return jsonb_build_object('ok',true,'version',h.version,'saved_at',h.saved_at); end if;
 if h.version<>p_expected then return jsonb_build_object('ok',false,'conflict',true,'version',h.version); end if;
 if exists(select 1 from jsonb_array_elements(p_changes) e group by e->>'collection',e->>'id' having count(*)>1) then raise exception 'duplicate_patch_id'; end if;
 for x in select value from jsonb_array_elements(p_changes) loop
  c:=x->>'collection'; k:=x->>'id'; v:=x->'value';
  if c not in ('products','suppliers','purchases','moves','quotes','attachments') or c is null or coalesce(k,'')='' or length(k)>250 or (v is distinct from 'null'::jsonb and (jsonb_typeof(v) is distinct from 'object' or v->>'id' is distinct from k or octet_length(v::text)>131072)) then raise exception 'invalid_record'; end if;
  if c='purchases' and v is distinct from 'null'::jsonb and (coalesce(v->>'date','') !~ '^\d{4}-(0[1-9]|1[0-2])-\d{2}$' or coalesce(v->>'qty','') !~ '^[0-9]+(\.[0-9]+)?$' or coalesce(v->>'price','') !~ '^[0-9]+(\.[0-9]+)?$') then raise exception 'invalid_purchase'; end if;
  select data into prior from public.estoqmais_records where user_id=u and collection=c and id=k;
  if prior is not distinct from nullif(v,'null'::jsonb) then continue; end if;
  changes:=changes||jsonb_build_array(jsonb_build_object('collection',c,'id',k,'value',prior));
  if v='null'::jsonb then delete from public.estoqmais_records where user_id=u and collection=c and id=k;
  else insert into public.estoqmais_records(user_id,collection,id,data) values(u,c,k,v) on conflict(user_id,collection,id) do update set data=excluded.data; end if;
 end loop;
 p_meta:=p_meta-array['products','suppliers','purchases','moves','quotes','attachments','_cloudOperation','_loadedMonths','_months','_allPurchases'];
 insert into public.estoqmais_journal values(u,h.version+1,t,h.meta,changes);
 update public.estoqmais_head set meta=p_meta,version=h.version+1,saved_at=t,operation=p_operation where user_id=u;
 delete from public.estoqmais_journal where user_id=u and version<h.version+1-9;
 return jsonb_build_object('ok',true,'version',h.version+1,'saved_at',t);
end $$;
create or replace function public.estoqmais_snapshot(p_version bigint) returns jsonb language plpgsql security definer set search_path='' as $$
declare u uuid:=auth.uid(); h public.estoqmais_head%rowtype; d jsonb; map jsonb:='{}'; r record; j record; x jsonb; c text; a jsonb; saved timestamptz;
begin
 perform public.estoqmais_init(); select * into h from public.estoqmais_head where user_id=u;
 if p_version=h.version or exists(select 1 from public.estoqmais_journal where user_id=u and version=p_version) then
  d:=h.meta;saved:=h.saved_at;
  for r in select collection,id,data from public.estoqmais_records where user_id=u loop
   map:=jsonb_set(map,array[r.collection],coalesce(map->r.collection,'{}')||jsonb_build_object(r.id,r.data));
  end loop;
  for j in select * from public.estoqmais_journal where user_id=u and version>p_version order by version desc loop
   d:=j.before_meta;
   for x in select value from jsonb_array_elements(j.undo) loop
    c:=x->>'collection';if x->'value'='null'::jsonb then map:=map #- array[c,x->>'id'];else map:=jsonb_set(map,array[c],coalesce(map->c,'{}')||jsonb_build_object(x->>'id',x->'value'));end if;
   end loop;
  end loop;
  select saved_at into saved from public.estoqmais_journal where user_id=u and version=p_version;
  saved:=coalesce(saved,h.saved_at);
  foreach c in array array['products','suppliers','purchases','moves','quotes','attachments'] loop
   select coalesce(jsonb_agg(value order by key),'[]') into a from jsonb_each(coalesce(map->c,'{}'));d:=d||jsonb_build_object(c,a);
  end loop;
 else
  select data,saved_at into d,saved from public.estoqmais_backups where user_id=u and version=p_version;
 end if;
 if d is null then raise exception 'snapshot_not_found';end if;
 return jsonb_build_object('version',p_version,'saved_at',saved,'data',d||jsonb_build_object('_allPurchases',true));
end $$;
create or replace function public.estoqmais_history() returns jsonb language sql security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(q) order by version desc),'[]') from (select version,max(saved_at) saved_at from(select version,saved_at from public.estoqmais_journal where user_id=auth.uid() union all select version,saved_at from public.estoqmais_backups where user_id=auth.uid()) a group by version order by version desc limit 10) q
$$;
create or replace function public.estoqmais_summary(p_from text,p_to text) returns jsonb language sql security definer set search_path='' as $$
 select coalesce(jsonb_agg(to_jsonb(q) order by month,category),'[]') from (
 select month,coalesce(nullif(data->>'category',''),(select p.data->>'category' from public.estoqmais_records p where p.user_id=auth.uid() and p.collection='products' and p.id=r.data->>'product'),'Sem categoria') category,
 sum((data->>'qty')::numeric*(data->>'price')::numeric+coalesce((data->>'tax')::numeric,0)) total,
 count(*) items,count(distinct coalesce(nullif(data->>'sourceOrder',''),id)) orders
 from public.estoqmais_records r where user_id=auth.uid() and collection='purchases' and month>=p_from and month<=p_to and coalesce(data->>'deleted','false')<>'true' group by month,category) q
$$;
create or replace function public.estoqmais_usage() returns jsonb language sql security definer set search_path='' as $$
 select jsonb_build_object('records_bytes',(select coalesce(sum(pg_column_size(data)),0) from public.estoqmais_records where user_id=auth.uid()),'history_bytes',(select coalesce(sum(pg_column_size(undo)+pg_column_size(before_meta)),0) from public.estoqmais_journal where user_id=auth.uid()),'legacy_bytes',(select coalesce(sum(n),0) from(select pg_column_size(data) n from public.estoqmais_state where user_id=auth.uid() union all select pg_column_size(data) from public.estoqmais_backups where user_id=auth.uid()) q),'files_bytes',(select coalesce(sum(coalesce((metadata->>'size')::bigint,0)),0) from storage.objects where bucket_id='estoqmais-anexos' and (storage.foldername(name))[1]=auth.uid()::text),'files_count',(select count(*) from storage.objects where bucket_id='estoqmais-anexos' and (storage.foldername(name))[1]=auth.uid()::text),'records_count',(select count(*) from public.estoqmais_records where user_id=auth.uid()))
$$;
-- Mantenha leitores antigos funcionando, mas impeça sobrescrever a versão otimizada.
do $$begin if to_regprocedure('public.estoqmais_save_legacy(jsonb,bigint,uuid)') is null then alter function public.estoqmais_save(jsonb,bigint,uuid) rename to estoqmais_save_legacy;end if;end$$;
revoke all on function public.estoqmais_save_legacy(jsonb,bigint,uuid) from public,anon,authenticated;
create or replace function public.estoqmais_save(p_data jsonb,p_expected bigint,p_operation uuid) returns jsonb language plpgsql security definer set search_path='' as $$begin
 if exists(select 1 from public.estoqmais_head where user_id=auth.uid()) then raise exception 'client_upgrade_required';end if;return public.estoqmais_save_legacy(p_data,p_expected,p_operation);end$$;
revoke all on function public.estoqmais_init(),public.estoqmais_read(text,boolean),public.estoqmais_patch(jsonb,jsonb,bigint,uuid),public.estoqmais_snapshot(bigint),public.estoqmais_history(),public.estoqmais_summary(text,text),public.estoqmais_usage() from public,anon;
grant execute on function public.estoqmais_read(text,boolean),public.estoqmais_patch(jsonb,jsonb,bigint,uuid),public.estoqmais_snapshot(bigint),public.estoqmais_history(),public.estoqmais_summary(text,text),public.estoqmais_usage() to authenticated;
revoke all on function public.estoqmais_save(jsonb,bigint,uuid) from public,anon;
grant execute on function public.estoqmais_save(jsonb,bigint,uuid) to authenticated;
notify pgrst,'reload schema';
commit;
