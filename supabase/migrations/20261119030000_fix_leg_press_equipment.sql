-- Leg Press is a machine, not a bodyweight move.
-- Not applied to the live database by this change.
-- Run it after 20261119020000_exercise_photos.sql.
--
-- public.exercises keeps each exercise in data (jsonb). The app reads and
-- writes equipment as data.equipmentIds, a list of names. The other leg
-- press exercises use "Leg Press Machine". This replaces only that list on
-- ex-leg-press and leaves the rest of the row alone.

update public.exercises
set data = jsonb_set(
  coalesce(data, '{}'::jsonb),
  '{equipmentIds}',
  '["Leg Press Machine"]'::jsonb,
  true
)
where id = 'ex-leg-press';
