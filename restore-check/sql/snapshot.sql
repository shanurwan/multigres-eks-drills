-- The same queries run on the live cluster (through the gateway) and on the restored copy.
-- :target is a timestamp. A restore to that time must hold every row written up to it.
-- A row's "at" is its transaction start, a few ms before its commit, so the strict checks use
-- target - 1 s (must all be present) and target + 1 s (must all be absent).
\pset format unaligned
\pset fieldsep ' '
\pset tuples_only on
SELECT 'ackcheck', run, count(*), sum(hashtext(run || ':' || worker || ':' || seq))::text,
       count(*) FILTER (WHERE at <= :'target'::timestamptz - interval '1 second'),
       coalesce(sum(hashtext(run || ':' || worker || ':' || seq)) FILTER (WHERE at <= :'target'::timestamptz - interval '1 second'), 0)::text
  FROM ackcheck GROUP BY run ORDER BY run;
SELECT 'newest_ackcheck_row', max(at) FROM ackcheck;
SELECT 'rows_after_target_plus_1s', count(*) FROM ackcheck WHERE at > :'target'::timestamptz + interval '1 second';
SELECT 'supafirehose_users', count(*), max(id) FROM users;
SELECT 'auth_users', count(*) FROM auth.users;
SELECT 'auth_sessions', count(*) FILTER (WHERE created_at <= :'target'::timestamptz), count(*) FROM auth.sessions;
SELECT 'auth_refresh_tokens', count(*) FILTER (WHERE created_at <= :'target'::timestamptz), count(*) FROM auth.refresh_tokens;
SELECT 'database_size_bytes', pg_database_size(current_database());
