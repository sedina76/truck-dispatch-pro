-- NOT APPROVED FOR PRODUCTION. Disposable synthetic model only.
\set ON_ERROR_STOP on
BEGIN;
SET LOCAL lock_timeout='3s';
SET LOCAL statement_timeout='15s';
SELECT _td0148.lock_model();
SELECT _td0148.check_state('after');
-- @REVERSE_STAGE@
SELECT _td0148.check_state('before');
COMMIT;
