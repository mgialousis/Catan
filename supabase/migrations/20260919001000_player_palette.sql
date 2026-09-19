-- A wider seat palette, and a default that no longer starts with white.
--
-- Apply AFTER a build carrying SUPPORTED_SCHEMA_VERSIONS including 3 is live.
--
-- WHITE stays permitted rather than being renamed: saved games carry the colour
-- inside public_state as well as in this column, and rewriting one without the
-- other would leave finished and paused games disagreeing with themselves. It
-- is simply no longer handed out, and the client no longer offers it.
DO $$
DECLARE target text;
BEGIN
  SELECT conname INTO target FROM pg_constraint
   WHERE conrelid = 'app.players'::regclass AND contype = 'c'
     AND pg_get_constraintdef(oid) LIKE '%colour%';
  IF target IS NULL THEN RAISE EXCEPTION 'player colour constraint not found'; END IF;
  EXECUTE format('ALTER TABLE app.players DROP CONSTRAINT %I', target);
END $$;

ALTER TABLE app.players ADD CONSTRAINT players_colour_allowed
  CHECK (colour IN ('RED','BLUE','WHITE','ORANGE','PURPLE','BLACK'));

INSERT INTO app.schema_migrations VALUES (3, 1, 'base-2020-v1', now());
