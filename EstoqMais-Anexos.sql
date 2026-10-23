-- Ative os anexos privados no mesmo projeto Supabase do EstoqMais.
-- Reexecutar não apaga compras, arquivos ou backups.
begin;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('estoqmais-anexos','estoqmais-anexos',false,5242880,array['application/pdf','image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=5242880,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists estoqmais_attachment_read on storage.objects;
create policy estoqmais_attachment_read on storage.objects for select to authenticated
using(bucket_id='estoqmais-anexos' and (storage.foldername(name))[1]=(select auth.uid())::text);
drop policy if exists estoqmais_attachment_insert on storage.objects;
create policy estoqmais_attachment_insert on storage.objects for insert to authenticated
with check(bucket_id='estoqmais-anexos' and (storage.foldername(name))[1]=(select auth.uid())::text);
commit;
