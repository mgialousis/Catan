-- Constraint checks for 20260919000200_bot_seats.sql.
--
-- Against a throwaway Postgres, not local Supabase, so it needs no stack:
--
--   docker run -d --name mig -e POSTGRES_PASSWORD=test -p 55433:5432 postgres:16-alpine
--   psql -h 127.0.0.1 -p 55433 -U postgres -c \
--     "CREATE SCHEMA auth; CREATE TABLE auth.users(id uuid PRIMARY KEY);
--      CREATE ROLE anon NOLOGIN; CREATE ROLE authenticated NOLOGIN; CREATE ROLE service_role NOLOGIN;"
--   psql ... -f supabase/migrations/20260909000100_foundation.sql
--   psql ... -f supabase/migrations/20260919000200_bot_seats.sql
--   psql ... -f supabase/tests/bot_seats_constraints.sql
--
-- Every line must report ok. This caught a live multiplayer room being allowed
-- to hold no slot, because `active_slot = 1` is NULL rather than FALSE when the
-- column is null and a CHECK rejects only FALSE.

\set ON_ERROR_STOP on
INSERT INTO auth.users VALUES ('00000000-0000-4000-8000-000000000001')
  ON CONFLICT DO NOTHING;

CREATE OR REPLACE FUNCTION pg_temp.mkroom(mode text, slot smallint, status text, hash text)
RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE rid uuid; pid uuid;
BEGIN
  SET CONSTRAINTS ALL DEFERRED;
  INSERT INTO app.rooms(created_by_user_id, status, active_slot, mode, settings, invitation_hash)
  VALUES ('00000000-0000-4000-8000-000000000001', status, slot, mode,
          '{"maxPlayers":4,"boardMode":"STANDARD_RANDOM","rulesVersion":"base-2020-v1","turnLimitSeconds":null}', hash)
  RETURNING id INTO rid;
  INSERT INTO app.players(room_id, auth_user_id, nickname, nickname_key, seat_index, colour)
  VALUES (rid, '00000000-0000-4000-8000-000000000001', 'Host', 'host', 0, 'RED') RETURNING id INTO pid;
  UPDATE app.rooms SET host_player_id = pid WHERE id = rid;
  RETURN rid;
END $$;

CREATE OR REPLACE FUNCTION pg_temp.check(label text, sql text, should_fail boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    EXECUTE sql;
    IF should_fail THEN RAISE EXCEPTION 'EXPECTED REJECTION: %', label; END IF;
    RAISE NOTICE 'ok   %', label;
  EXCEPTION WHEN raise_exception THEN RAISE;
  WHEN others THEN
    IF should_fail THEN RAISE NOTICE 'ok   % (rejected: %)', label, left(SQLERRM, 46);
    ELSE RAISE EXCEPTION 'UNEXPECTED REJECTION: % -> %', label, SQLERRM; END IF;
  END;
END $$;

DO $$
DECLARE practice uuid; multi uuid;
BEGIN
  multi := pg_temp.mkroom('MULTIPLAYER', 1::smallint, 'ACTIVE', repeat('a',64));
  RAISE NOTICE 'ok   live multiplayer room holds slot 1';
  practice := pg_temp.mkroom('PRACTICE', NULL, 'ACTIVE', repeat('b',64));
  RAISE NOTICE 'ok   live practice room holds no slot';
  PERFORM pg_temp.mkroom('PRACTICE', NULL, 'ACTIVE', repeat('c',64));
  RAISE NOTICE 'ok   a second practice room runs alongside the first';

  PERFORM pg_temp.check('bot seat with no identity',
    format('INSERT INTO app.players(room_id,kind,auth_user_id,nickname,nickname_key,seat_index,colour) VALUES (%L,''BOT'',NULL,''Ada'',''ada'',1,''BLUE'')', practice), false);
  PERFORM pg_temp.check('a second bot in the same room',
    format('INSERT INTO app.players(room_id,kind,auth_user_id,nickname,nickname_key,seat_index,colour) VALUES (%L,''BOT'',NULL,''Bo'',''bo'',2,''WHITE'')', practice), false);
  PERFORM pg_temp.check('bot carrying a human identity',
    format('INSERT INTO app.players(room_id,kind,auth_user_id,nickname,nickname_key,seat_index,colour) VALUES (%L,''BOT'',''00000000-0000-4000-8000-000000000001'',''Cy'',''cy'',3,''ORANGE'')', practice), true);
  PERFORM pg_temp.check('person with no identity',
    format('INSERT INTO app.players(room_id,kind,auth_user_id,nickname,nickname_key,seat_index,colour) VALUES (%L,''HUMAN'',NULL,''Di'',''di'',3,''ORANGE'')', practice), true);
  PERFORM pg_temp.check('two bots on one seat',
    format('INSERT INTO app.players(room_id,kind,auth_user_id,nickname,nickname_key,seat_index,colour) VALUES (%L,''BOT'',NULL,''Ex'',''ex'',1,''ORANGE'')', practice), true);
  PERFORM pg_temp.check('practice room taking the live slot',
    'INSERT INTO app.rooms(created_by_user_id,status,active_slot,mode,settings,invitation_hash) VALUES (''00000000-0000-4000-8000-000000000001'',''ACTIVE'',2,''PRACTICE'',''{"maxPlayers":4,"boardMode":"STANDARD_RANDOM","rulesVersion":"base-2020-v1","turnLimitSeconds":null}'',' || quote_literal(repeat('d',64)) || ')', true);
  PERFORM pg_temp.check('multiplayer room without a slot',
    'INSERT INTO app.rooms(created_by_user_id,status,active_slot,mode,settings,invitation_hash) VALUES (''00000000-0000-4000-8000-000000000001'',''ACTIVE'',NULL,''MULTIPLAYER'',''{"maxPlayers":4,"boardMode":"STANDARD_RANDOM","rulesVersion":"base-2020-v1","turnLimitSeconds":null}'',' || quote_literal(repeat('e',64)) || ')', true);
  PERFORM pg_temp.check('a second live multiplayer room',
    'INSERT INTO app.rooms(created_by_user_id,status,active_slot,mode,settings,invitation_hash) VALUES (''00000000-0000-4000-8000-000000000001'',''ACTIVE'',1,''MULTIPLAYER'',''{"maxPlayers":4,"boardMode":"STANDARD_RANDOM","rulesVersion":"base-2020-v1","turnLimitSeconds":null}'',' || quote_literal(repeat('f',64)) || ')', true);
END $$;
SELECT version FROM app.schema_migrations ORDER BY version;
