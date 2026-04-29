-- dart_vault v0.2.0 — Supabase / PostgreSQL init SQL
-- Run once per project. Safe to re-run (idempotent).

-- ── Helper function for SQL execution via SupabaseVaultStorage ────────────────
CREATE OR REPLACE FUNCTION vault_exec_sql(sql text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
  EXECUTE sql;
END;
$$;

-- ── Generic collection table template ─────────────────────────────────────────
-- dart_vault stores every collection as a table with this schema.
-- Replace {collection} with your actual collection names.

-- Example: 'settings' collection
CREATE TABLE IF NOT EXISTS "settings" (
  id        TEXT PRIMARY KEY,
  data      JSONB NOT NULL DEFAULT '{}'::jsonb,
  tenant_id TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_settings_data ON "settings" USING GIN(data);

-- Example: Blueprint versioned collections (meta + nodes)
CREATE TABLE IF NOT EXISTS "blueprints__meta" (
  id        TEXT PRIMARY KEY,
  data      JSONB NOT NULL DEFAULT '{}'::jsonb,
  tenant_id TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

CREATE TABLE IF NOT EXISTS "blueprints__nodes" (
  id        TEXT PRIMARY KEY,
  data      JSONB NOT NULL DEFAULT '{}'::jsonb,
  tenant_id TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_blueprints_nodes_entity
  ON "blueprints__nodes" ((data->>'entityId'));
CREATE INDEX IF NOT EXISTS idx_blueprints_nodes_status
  ON "blueprints__nodes" ((data->>'status'));
CREATE INDEX IF NOT EXISTS idx_blueprints_nodes_branch
  ON "blueprints__nodes" ((data->>'branch'));

-- Example: WorkflowRuns logged collection (data + log)
CREATE TABLE IF NOT EXISTS "runs" (
  id        TEXT PRIMARY KEY,
  data      JSONB NOT NULL DEFAULT '{}'::jsonb,
  tenant_id TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_runs_status
  ON "runs" ((data->>'status'));
CREATE INDEX IF NOT EXISTS idx_runs_blueprint
  ON "runs" ((data->>'blueprintId'));

CREATE TABLE IF NOT EXISTS "runs__log" (
  id        TEXT PRIMARY KEY,
  data      JSONB NOT NULL DEFAULT '{}'::jsonb,
  tenant_id TEXT,
  created_at TIMESTAMPTZ DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_runs_log_entity
  ON "runs__log" ((data->>'entityId'));
CREATE INDEX IF NOT EXISTS idx_runs_log_changed_at
  ON "runs__log" ((data->>'changedAt'));

-- ── Row Level Security (optional — recommended for multi-tenant) ───────────────
-- Enable RLS and add a policy that uses tenant_id = current_user or a JWT claim.
-- ALTER TABLE "settings" ENABLE ROW LEVEL SECURITY;
-- CREATE POLICY tenant_isolation ON "settings"
--   USING (tenant_id = current_setting('app.tenant_id', true));

-- ── updated_at trigger ─────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

-- Apply to each table that needs it:
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['settings','blueprints__meta','blueprints__nodes','runs']
  LOOP
    EXECUTE format('
      DROP TRIGGER IF EXISTS set_updated_at ON %I;
      CREATE TRIGGER set_updated_at BEFORE UPDATE ON %I
      FOR EACH ROW EXECUTE FUNCTION set_updated_at();
    ', t, t);
  END LOOP;
END;
$$;
