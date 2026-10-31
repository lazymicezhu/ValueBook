CREATE TABLE IF NOT EXISTS records (
  key     TEXT PRIMARY KEY,
  kind    TEXT NOT NULL,
  data    TEXT NOT NULL,
  deleted INTEGER NOT NULL DEFAULT 0,
  rev     INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS records_rev ON records (rev);
