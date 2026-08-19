-- ============================================================
-- GEM · Storage — reference photos and document files
-- Run AFTER 04_client_loop.sql.
--
-- Object keys are laid out as:   <org_id>/<event_id>/<filename>
-- The leading path segment is what the policies below check, so a planner
-- can never read another org's media even with a valid session.
-- ============================================================

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('gem-media','gem-media', false, 10485760,
        array['image/jpeg','image/png','image/webp','image/heic','application/pdf'])
on conflict (id) do update
  set file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- The bucket is private: files are served through short-lived signed URLs
-- (see gemApi.signedUrl), never a public link.

create policy "gem media read"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'gem-media'
    and (
      gem_is_org_member(((storage.foldername(name))[1])::uuid)
      or gem_is_event_client(((storage.foldername(name))[2])::uuid)
    )
  );

create policy "gem media write"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'gem-media'
    and gem_is_org_member(((storage.foldername(name))[1])::uuid)
  );

create policy "gem media update"
  on storage.objects for update to authenticated
  using (bucket_id = 'gem-media' and gem_is_org_member(((storage.foldername(name))[1])::uuid))
  with check (bucket_id = 'gem-media' and gem_is_org_member(((storage.foldername(name))[1])::uuid));

create policy "gem media delete"
  on storage.objects for delete to authenticated
  using (bucket_id = 'gem-media' and gem_is_org_member(((storage.foldername(name))[1])::uuid));
