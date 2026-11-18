-- Equipment photos for the exercise library.
-- Not applied to the live database by this change.
-- Run it after 20261119010000_growth_rebook_renew_reports.sql.
--
-- A picture of the equipment, not a video. Anyone signed in can see it.
-- Only a coach or the owner can add or replace one.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'exercise-photos',
  'exercise-photos',
  true,
  5242880,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists exercise_photos_select on storage.objects;
create policy exercise_photos_select on storage.objects
  for select
  to anon, authenticated
  using (bucket_id = 'exercise-photos');

drop policy if exists exercise_photos_insert on storage.objects;
create policy exercise_photos_insert on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'exercise-photos'
    and public.current_user_role() in ('coach', 'owner')
  );

drop policy if exists exercise_photos_update on storage.objects;
create policy exercise_photos_update on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'exercise-photos'
    and public.current_user_role() in ('coach', 'owner')
  )
  with check (
    bucket_id = 'exercise-photos'
    and public.current_user_role() in ('coach', 'owner')
  );

drop policy if exists exercise_photos_delete on storage.objects;
create policy exercise_photos_delete on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'exercise-photos'
    and public.current_user_role() in ('coach', 'owner')
  );
