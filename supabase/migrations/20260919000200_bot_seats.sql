-- Practice mode: automated seats, and rooms that do not contend for the single
-- live multiplayer slot.
--
-- Apply this AFTER a build carrying SUPPORTED_SCHEMA_VERSIONS = [1, 2] is live.
-- That build accepts either schema, so the code can go out first and this can
-- follow without the API crash-looping in between.

-- A bot has no Supabase identity, so auth_user_id has to give way. The pairing
-- is then pinned from both sides: a person must have an identity, a bot must
-- not, so neither can be created as the other by omission.
ALTER TABLE app.players ADD COLUMN kind text NOT NULL DEFAULT 'HUMAN'
  CHECK (kind IN ('HUMAN','BOT'));
ALTER TABLE app.players ALTER COLUMN auth_user_id DROP NOT NULL;
ALTER TABLE app.players ADD CONSTRAINT players_identity_matches_kind CHECK (
  (kind = 'HUMAN' AND auth_user_id IS NOT NULL) OR (kind = 'BOT' AND auth_user_id IS NULL));

-- UNIQUE (room_id, auth_user_id) already tolerates several bots in one room:
-- Postgres treats each NULL as distinct. Seat, colour and nickname stay unique
-- per room through the existing partial indexes, which bots share.

ALTER TABLE app.rooms ADD COLUMN mode text NOT NULL DEFAULT 'MULTIPLAYER'
  CHECK (mode IN ('MULTIPLAYER','PRACTICE'));

-- The original constraint forces every live room into slot 1, which is what
-- keeps one multiplayer game at a time. Practice games must not compete for it,
-- so they hold no slot and any number may run. It is anonymous, so find it by
-- what it constrains rather than by a name this database may not share.
DO $$
DECLARE target text;
BEGIN
  SELECT conname INTO target FROM pg_constraint
   WHERE conrelid = 'app.rooms'::regclass AND contype = 'c'
     AND pg_get_constraintdef(oid) LIKE '%active_slot%';
  IF target IS NULL THEN RAISE EXCEPTION 'room slot constraint not found'; END IF;
  EXECUTE format('ALTER TABLE app.rooms DROP CONSTRAINT %I', target);
END $$;

-- active_slot IS NOT NULL is not redundant. A CHECK rejects only FALSE, and
-- `active_slot = 1` is NULL rather than FALSE when the column is null, so
-- without the guard a live multiplayer room holding no slot would be accepted.
ALTER TABLE app.rooms ADD CONSTRAINT rooms_slot_matches_mode CHECK (
  (status IN ('LOBBY','ACTIVE','PAUSED') AND mode = 'MULTIPLAYER' AND active_slot IS NOT NULL AND active_slot = 1)
  OR (status IN ('LOBBY','ACTIVE','PAUSED') AND mode = 'PRACTICE' AND active_slot IS NULL)
  OR (status IN ('FINISHED','ABANDONED','EXPIRED') AND active_slot IS NULL));

-- Live multiplayer rooms are found by slot; practice rooms have none, so give
-- the sweeps and lookups an index that finds them by mode instead.
CREATE INDEX rooms_practice_live ON app.rooms(mode, status)
  WHERE status IN ('LOBBY','ACTIVE','PAUSED');

INSERT INTO app.schema_migrations VALUES (2, 1, 'base-2020-v1', now());
