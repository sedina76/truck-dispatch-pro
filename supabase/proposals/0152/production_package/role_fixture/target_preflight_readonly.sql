-- F30 TARGET PREFLIGHT -- READ-ONLY, single SELECT, no writes of any kind.
--
-- Paste this into the SQL Editor of the project you have INDEPENDENTLY verified against the Supabase dashboard URL/Settings, and ONLY after
-- target_preflight.py confirm-target has printed a GO line for that SAME reference. Save the single output row (the "f30_target_preflight" column) as
-- JSON and pass it to target_preflight.py record-evidence's --result-file.
--
-- Selects exactly one row of enumerated, safe facts -- no table contents, no row data, no secrets, nothing sensitive. It never creates, alters, or drops
-- anything, and it takes no advisory lock (there is nothing here to race: it changes no state).
select jsonb_build_object(
  'postgres_version', current_setting('server_version'),
  'public_base_table_count', (select count(*) from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE'),
  'f30_marker_schema_exists', exists (select 1 from information_schema.schemata where schema_name = 'f30_test_control'),
  'f30_fixture_schema_exists', exists (select 1 from information_schema.schemata where schema_name = 'f30_probe'),
  'f30_freeze_schema_exists', exists (select 1 from information_schema.schemata where schema_name = 'ops_freeze_v2'),
  'current_database', current_database()
) as f30_target_preflight;
