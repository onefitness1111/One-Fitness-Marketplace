-- L3 + L4 + L5: one all-or-nothing intake save that always keeps the
-- previous filing.
--
-- Before this, the app read the whole client record, built the new intake
-- entry on the device, called patch_client_intake, and if that failed it
-- rewrote the entire record from the device's copy. A stale device could
-- wipe newer intakes, archives, or anything else on the record. The
-- intake_submissions mirror was a separate, best-effort set of writes.
--
-- submit_client_intake does all of it in one transaction:
--   * locks the client's record row,
--   * moves the completed filing already on record into `history`
--     (newest first, no cap), with its form version, so editing answers or
--     filing again never overwrites what was there,
--   * writes the new filing as current,
--   * mirrors both into intake_submissions (the old row archived, the new
--     row open).
-- Anything failing rolls the whole save back, and the app shows "try again"
-- instead of falling back to a full-record overwrite.
--
-- Who may call it is unchanged from patch_client_intake: the client for
-- their own record, any coach, the owner, and service_role.

-- The app stamps intakes with a display string ("Nov 25, 6:24 PM"), not an
-- ISO time. A bad cast must never abort the save, so this returns null
-- instead of raising.
create or replace function public.intake_try_timestamptz(p_value text)
returns timestamptz
language plpgsql
stable
set search_path to 'public'
as $$
begin
  if p_value is null or btrim(p_value) = '' then
    return null;
  end if;
  if p_value !~ '^\d{4}-\d{2}-\d{2}' then
    return null;
  end if;
  return p_value::timestamptz;
exception when others then
  return null;
end;
$$;

revoke all on function public.intake_try_timestamptz(text) from public, anon;
grant execute on function public.intake_try_timestamptz(text) to authenticated, service_role;

create or replace function public.submit_client_intake(
  p_client uuid,
  p_assessment text,
  p_entry jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_role text := public.current_user_role();
  v_is_service boolean := coalesce(auth.role(), '') = 'service_role';
  v_row_data jsonb;
  v_intake jsonb;
  v_prior jsonb;
  v_history jsonb := '[]'::jsonb;
  v_next jsonb;
  v_archived jsonb;
  v_archived_at text;
  v_closed integer := 0;
  v_known text[] := array['answers', 'completed', 'at', 'by', 'attachments', 'history', 'templateVersion'];
begin
  if not v_is_service
     and auth.uid() is distinct from p_client
     and coalesce(v_role, '') not in ('coach', 'owner') then
    raise exception 'Not allowed.';
  end if;
  if p_client is null then
    raise exception 'Which client?';
  end if;
  if btrim(coalesce(p_assessment, '')) = '' then
    raise exception 'Which form?';
  end if;
  if p_entry is null or jsonb_typeof(p_entry) <> 'object' then
    raise exception 'Nothing to save.';
  end if;

  select data into v_row_data
  from public.client_records
  where profile_id = p_client
  for update;

  if not found then
    insert into public.client_records (profile_id, data)
    values (p_client, '{}'::jsonb);
    v_row_data := '{}'::jsonb;
  end if;
  v_row_data := coalesce(v_row_data, '{}'::jsonb);
  if jsonb_typeof(v_row_data) <> 'object' then
    raise exception 'This client record is not in the expected shape.';
  end if;

  v_intake := v_row_data -> 'intake';
  if v_intake is null or jsonb_typeof(v_intake) <> 'object' then
    v_intake := '{}'::jsonb;
  end if;

  v_prior := v_intake -> p_assessment;
  if v_prior is not null and jsonb_typeof(v_prior) <> 'object' then
    v_prior := null;
  end if;
  if v_prior is not null and jsonb_typeof(v_prior -> 'history') = 'array' then
    v_history := v_prior -> 'history';
  end if;

  -- A completed filing already on record is archived, never overwritten.
  -- A draft that was never completed is simply replaced.
  v_archived_at := coalesce(nullif(p_entry ->> 'at', ''), to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  if v_prior is not null and coalesce(v_prior -> 'completed' = 'true'::jsonb, false) then
    v_archived := jsonb_strip_nulls(jsonb_build_object(
      'answers', coalesce(v_prior -> 'answers', '{}'::jsonb),
      'at', v_prior -> 'at',
      'by', v_prior -> 'by',
      'attachments', coalesce(v_prior -> 'attachments', '[]'::jsonb),
      'templateVersion', v_prior -> 'templateVersion',
      'archivedAt', to_jsonb(v_archived_at),
      'extra', v_prior - v_known
    ));
    v_history := jsonb_build_array(v_archived) || v_history;
  end if;

  v_next := p_entry - 'history';
  if jsonb_array_length(v_history) > 0 then
    v_next := v_next || jsonb_build_object('history', v_history);
  end if;

  update public.client_records
     set data = jsonb_set(v_row_data, '{intake}', v_intake || jsonb_build_object(p_assessment, v_next), true)
   where profile_id = p_client;

  -- Mirror into intake_submissions in the same transaction.
  update public.intake_submissions
     set archived_at = now(),
         archived_by = auth.uid()
   where client_id = p_client
     and assessment_key = p_assessment
     and archived_at is null;
  get diagnostics v_closed = row_count;

  if v_archived is not null and v_closed = 0 then
    insert into public.intake_submissions (
      client_id, assessment_key, answers, completed, completed_at, completed_by,
      archived_at, archived_by, attachments, template_version, extra
    ) values (
      p_client,
      p_assessment,
      coalesce(v_archived -> 'answers', '{}'::jsonb),
      true,
      public.intake_try_timestamptz(v_prior ->> 'at'),
      v_prior ->> 'by',
      now(),
      auth.uid(),
      coalesce(v_archived -> 'attachments', '[]'::jsonb),
      case when (v_prior ->> 'templateVersion') ~ '^\d+$' then (v_prior ->> 'templateVersion')::integer end,
      coalesce(v_archived -> 'extra', '{}'::jsonb)
    );
  end if;

  insert into public.intake_submissions (
    client_id, assessment_key, answers, completed, completed_at, completed_by,
    attachments, template_version, extra
  ) values (
    p_client,
    p_assessment,
    coalesce(p_entry -> 'answers', '{}'::jsonb),
    coalesce(p_entry -> 'completed' = 'true'::jsonb, false),
    coalesce(public.intake_try_timestamptz(p_entry ->> 'at'), now()),
    p_entry ->> 'by',
    coalesce(p_entry -> 'attachments', '[]'::jsonb),
    case when (p_entry ->> 'templateVersion') ~ '^\d+$' then (p_entry ->> 'templateVersion')::integer end,
    p_entry - v_known
  );

  return v_next;
end;
$$;

revoke all on function public.submit_client_intake(uuid, text, jsonb) from public, anon;
grant execute on function public.submit_client_intake(uuid, text, jsonb) to authenticated, service_role;
