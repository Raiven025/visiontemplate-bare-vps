-- Run with: createdb vision_template && psql -d vision_template -f db/setup.sql
CREATE TABLE IF NOT EXISTS notes (
  id SERIAL PRIMARY KEY,
  title TEXT NOT NULL,
  content TEXT NOT NULL DEFAULT '',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO notes (title, content)
SELECT 'Welcome', 'This note was seeded into your local Postgres database.'
WHERE NOT EXISTS (
  SELECT 1 FROM notes
  WHERE title = 'Welcome'
    AND content = 'This note was seeded into your local Postgres database.'
);

INSERT INTO notes (title, content)
SELECT 'It works', 'If you can see this on the DB page, Postgres is connected.'
WHERE NOT EXISTS (
  SELECT 1 FROM notes
  WHERE title = 'It works'
    AND content = 'If you can see this on the DB page, Postgres is connected.'
);
