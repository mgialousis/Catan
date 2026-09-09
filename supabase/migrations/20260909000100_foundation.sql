-- Apply through the local Supabase migration runner as postgres.
-- No login password is kept in migrations. configure-local creates a local runtime credential.
DO $$ BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'island_owner') THEN
    CREATE ROLE island_owner NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'island_runtime') THEN
    CREATE ROLE island_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
  END IF;
END $$;
GRANT island_owner TO postgres;
CREATE SCHEMA app AUTHORIZATION island_owner;
REVOKE ALL ON SCHEMA app FROM PUBLIC, anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE island_owner IN SCHEMA app REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

CREATE TABLE app.schema_migrations (
  version integer PRIMARY KEY CHECK (version > 0),
  protocol_version integer NOT NULL, rules_version text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO app.schema_migrations VALUES (1, 1, 'base-2020-v1', now());

CREATE TABLE app.rooms (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  host_player_id uuid,
  created_by_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'LOBBY' CHECK (status IN ('LOBBY','ACTIVE','PAUSED','FINISHED','ABANDONED','EXPIRED')),
  revision integer NOT NULL DEFAULT 0 CHECK (revision >= 0),
  active_slot smallint UNIQUE,
  settings jsonb NOT NULL CHECK (
    jsonb_typeof(settings) = 'object' AND settings @> '{"maxPlayers":4,"boardMode":"STANDARD_RANDOM","rulesVersion":"base-2020-v1"}'
    AND settings ? 'turnLimitSeconds' AND settings->'turnLimitSeconds' IN ('null','60','120','180')
  ),
  invitation_hash text NOT NULL UNIQUE CHECK (invitation_hash ~ '^[0-9a-f]{64}$'),
  invitation_expires_at timestamptz,
  runtime_epoch uuid, runtime_heartbeat_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
  started_at timestamptz, ended_at timestamptz,
  CHECK ((status IN ('LOBBY','ACTIVE','PAUSED') AND active_slot IS NOT NULL AND active_slot = 1)
    OR (status IN ('FINISHED','ABANDONED','EXPIRED') AND active_slot IS NULL))
);
CREATE INDEX rooms_status_updated ON app.rooms(status, updated_at);

CREATE TABLE app.players (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES app.rooms(id) ON DELETE RESTRICT,
  auth_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  nickname text NOT NULL CHECK (char_length(nickname) BETWEEN 2 AND 160 AND nickname !~ '[[:cntrl:]]'),
  nickname_key text NOT NULL CHECK (char_length(nickname_key) BETWEEN 1 AND 320),
  seat_index smallint CHECK (seat_index BETWEEN 0 AND 3),
  colour text CHECK (colour IN ('RED','BLUE','WHITE','ORANGE')),
  ready boolean NOT NULL DEFAULT false,
  joined_at timestamptz NOT NULL DEFAULT now(), left_at timestamptz, last_seen_at timestamptz,
  UNIQUE (room_id, auth_user_id), UNIQUE (room_id, id),
  CHECK (left_at IS NOT NULL OR seat_index IS NOT NULL)
);
CREATE UNIQUE INDEX players_seat ON app.players(room_id, seat_index) WHERE left_at IS NULL;
CREATE UNIQUE INDEX players_colour ON app.players(room_id, colour) WHERE left_at IS NULL;
CREATE UNIQUE INDEX players_nickname ON app.players(room_id, nickname_key) WHERE left_at IS NULL;
ALTER TABLE app.rooms ADD CONSTRAINT rooms_host_same_room FOREIGN KEY (id, host_player_id)
  REFERENCES app.players(room_id, id) DEFERRABLE INITIALLY DEFERRED;

CREATE FUNCTION app.require_room_host() RETURNS trigger LANGUAGE plpgsql SET search_path = pg_catalog, app AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM app.rooms WHERE id = NEW.id AND host_player_id IS NULL) THEN
    RAISE EXCEPTION 'room requires host at commit' USING ERRCODE = '23514';
  END IF;
  RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER room_host_required AFTER INSERT OR UPDATE ON app.rooms
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION app.require_room_host();

CREATE TABLE app.game_states (
  room_id uuid PRIMARY KEY REFERENCES app.rooms(id) ON DELETE RESTRICT,
  version integer NOT NULL DEFAULT 0 CHECK (version >= 0),
  rules_version text NOT NULL CHECK (rules_version = 'base-2020-v1'),
  schema_version integer NOT NULL CHECK (schema_version = 1),
  phase text NOT NULL CHECK (phase IN ('SETUP_SETTLEMENT','SETUP_ROAD','AWAIT_ROLL','DISCARD_REQUIRED','ROBBER_MOVE','ROBBER_VICTIM','ACTION','ROAD_BUILDING','COMPLETE')),
  phase_id uuid NOT NULL, turn_number integer NOT NULL CHECK (turn_number >= 0), active_player_id uuid NOT NULL,
  public_state jsonb NOT NULL CHECK (jsonb_typeof(public_state) = 'object'),
  private_state jsonb NOT NULL CHECK (jsonb_typeof(private_state) = 'object'),
  server_state jsonb NOT NULL CHECK (jsonb_typeof(server_state) = 'object'),
  clock_state jsonb NOT NULL CHECK (jsonb_typeof(clock_state) = 'object'),
  next_deadline_at timestamptz, updated_at timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (room_id, active_player_id) REFERENCES app.players(room_id, id)
);
CREATE INDEX game_deadlines ON app.game_states(next_deadline_at) WHERE next_deadline_at IS NOT NULL;

CREATE TABLE app.move_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id uuid NOT NULL REFERENCES app.game_states(room_id) ON DELETE RESTRICT,
  sequence integer NOT NULL CHECK (sequence >= 0), command_id uuid NOT NULL,
  actor_player_id uuid, actor_kind text NOT NULL CHECK (actor_kind IN ('PLAYER','SYSTEM')),
  command_type text NOT NULL,
  validated_payload jsonb NOT NULL CHECK (jsonb_typeof(validated_payload) = 'object'),
  effects jsonb NOT NULL CHECK (jsonb_typeof(effects) = 'array'),
  public_activity jsonb NOT NULL CHECK (jsonb_typeof(public_activity) = 'array'),
  rules_version text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(room_id, sequence),
  FOREIGN KEY (room_id, actor_player_id) REFERENCES app.players(room_id, id),
  CHECK ((actor_kind = 'PLAYER' AND actor_player_id IS NOT NULL) OR (actor_kind = 'SYSTEM' AND actor_player_id IS NULL))
);
CREATE TABLE app.command_receipts (
  actor_key text NOT NULL CHECK (actor_key ~ '^(user|system):[a-zA-Z0-9_-]+$'),
  command_id uuid NOT NULL, room_id uuid REFERENCES app.rooms(id) ON DELETE SET NULL,
  request_hash text NOT NULL CHECK (request_hash ~ '^[0-9a-f]{64}$'),
  status text NOT NULL CHECK (status IN ('ACCEPTED','REJECTED')),
  response jsonb CHECK (jsonb_typeof(response) = 'object'), created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (actor_key, command_id)
);
CREATE INDEX receipts_room ON app.command_receipts(room_id);
CREATE TABLE app.outbox_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(), room_id uuid NOT NULL REFERENCES app.rooms(id) ON DELETE RESTRICT,
  scope text NOT NULL CHECK (scope IN ('ROOM','GAME')),
  from_version integer CHECK (from_version >= 0), to_version integer NOT NULL CHECK (to_version >= 0),
  public_payload jsonb NOT NULL CHECK (jsonb_typeof(public_payload) = 'object'),
  private_payloads jsonb NOT NULL CHECK (jsonb_typeof(private_payloads) = 'object'),
  attempts integer NOT NULL DEFAULT 0 CHECK (attempts >= 0), published_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(), UNIQUE(room_id, scope, to_version),
  CHECK ((from_version IS NULL AND to_version = 0) OR (from_version IS NOT NULL AND to_version = from_version + 1))
);
CREATE INDEX outbox_pending ON app.outbox_events(room_id, scope, to_version) WHERE published_at IS NULL;
CREATE TABLE app.runtime_control (
  id smallint PRIMARY KEY CHECK (id = 1), active_epoch uuid, claimed_at timestamptz
);
INSERT INTO app.runtime_control (id) VALUES (1);

-- Defense in depth: clients have neither schema privileges nor RLS policies.
DO $$ DECLARE table_name text; BEGIN
  FOREACH table_name IN ARRAY ARRAY['schema_migrations','rooms','players','game_states','move_logs','command_receipts','outbox_events','runtime_control'] LOOP
    EXECUTE format('ALTER TABLE app.%I OWNER TO island_owner', table_name);
    EXECUTE format('ALTER TABLE app.%I ENABLE ROW LEVEL SECURITY', table_name);
    EXECUTE format('CREATE POLICY runtime_access ON app.%I TO island_runtime USING (true) WITH CHECK (true)', table_name);
  END LOOP;
END $$;
GRANT USAGE ON SCHEMA app TO island_runtime;
GRANT SELECT ON ALL TABLES IN SCHEMA app TO island_runtime;
GRANT INSERT, UPDATE ON app.rooms, app.players, app.game_states TO island_runtime;
GRANT INSERT ON app.move_logs, app.command_receipts, app.outbox_events TO island_runtime;
GRANT UPDATE (attempts, published_at) ON app.outbox_events TO island_runtime;
GRANT UPDATE (active_epoch, claimed_at) ON app.runtime_control TO island_runtime;
GRANT EXECUTE ON FUNCTION app.require_room_host() TO island_runtime;
ALTER FUNCTION app.require_room_host() OWNER TO island_owner;
REVOKE ALL ON FUNCTION app.require_room_host() FROM PUBLIC;
