-- ============================================================
-- QUESTION 3: Library Returns and Overdue Fines
-- PostgreSQL solution (pg_cron-safe, nested dollar-quote safe)
-- ============================================================

-- ---------- (a) Database and seed data ----------
DROP TABLE IF EXISTS loan_audit CASCADE;
DROP TABLE IF EXISTS overdue_summary CASCADE;
DROP TABLE IF EXISTS loans CASCADE;
DROP TABLE IF EXISTS books CASCADE;

-- Books
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(200) NOT NULL
);

-- Loans: due_on must be on or after borrowed_on
CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL,
    returned_on   DATE NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT chk_due_after_borrow CHECK (due_on >= borrowed_on)
);

-- loan_audit: tracks OLD/NEW returned_on
CREATE TABLE loan_audit (
    audit_id        SERIAL PRIMARY KEY,
    loan_id         INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- overdue_summary: one row per snapshot date
CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL DEFAULT 0,
    total_fine    NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Seed: three books
INSERT INTO books (title) VALUES
 ('Database Systems'),
 ('Algorithms'),
 ('Operating Systems');

-- Seed: six loans
--   * open overdue loan
--   * on-time returned loan (no fine)
--   * returned-late loan (fine charged)
--   * open non-overdue loan
--   * returned-late loan (fine charged)
--   * open non-overdue loan
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
 (1,'John',  CURRENT_DATE - 20, CURRENT_DATE - 6,  NULL,             0),
 (2,'Mary',  CURRENT_DATE - 10, CURRENT_DATE - 3,  CURRENT_DATE - 3, 0),
 (3,'Peter', CURRENT_DATE - 15, CURRENT_DATE - 5,  CURRENT_DATE - 2, 6),
 (1,'Grace', CURRENT_DATE - 5,  CURRENT_DATE + 2,  NULL,             0),
 (2,'Paul',  CURRENT_DATE - 30, CURRENT_DATE - 20, CURRENT_DATE - 18,4),
 (3,'Ruth',  CURRENT_DATE - 1,  CURRENT_DATE + 1,  NULL,             0);


-- ---------- (b) Function ----------
-- K2 per overdue day, minimum 0.
-- Effective end date = earlier of p_as_of and returned_on (when returned).
-- Rejects unknown loan.
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC AS $$
DECLARE
    v_due    DATE;
    v_return DATE;
    v_eff    DATE;
    v_days   INTEGER;
BEGIN
    SELECT due_on, returned_on
      INTO v_due, v_return
      FROM loans
     WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id %', p_loan_id;
    END IF;

    -- Stop accumulating at return date (if returned), else use as_of
    v_eff  := LEAST(p_as_of, COALESCE(v_return, p_as_of));
    v_days := GREATEST(v_eff - v_due, 0);

    RETURN 2 * v_days;
END;
$$ LANGUAGE plpgsql;


-- ---------- (c) Procedure ----------
-- Rejects unknown / already-returned / early return.
-- Stores returned_on and final fine together.
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_borrowed DATE;
    v_return   DATE;
    v_fine     NUMERIC;
BEGIN
    SELECT borrowed_on, returned_on
      INTO v_borrowed, v_return
      FROM loans
     WHERE loan_id = p_loan_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id %', p_loan_id;
    END IF;

    IF v_return IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % is already returned (on %)', p_loan_id, v_return;
    END IF;

    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrowed date %',
            p_returned_on, v_borrowed;
    END IF;

    -- Final fine as of the return date
    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
       SET returned_on = p_returned_on,
           fine_amount = v_fine
     WHERE loan_id = p_loan_id;
END;
$$;


-- ---------- (d) Trigger ----------
-- Log returned_on changes only (no row when unchanged).
CREATE OR REPLACE FUNCTION trg_loan_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.returned_on IS DISTINCT FROM OLD.returned_on THEN
        INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
        VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_loan_audit ON loans;
CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
EXECUTE FUNCTION trg_loan_audit();


-- ---------- (e) View ----------
-- Unreturned loans whose due date is before today, fine as of today.
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans;


-- ---------- (f) Index ----------
-- Partial index for "given book's UNRETURNED loans".
-- Justification: filters on book_id plus returned_on IS NULL,
-- so a partial index on book_id is smaller and faster than a full index.
CREATE INDEX IF NOT EXISTS idx_loans_book_unreturned
    ON loans (book_id) WHERE returned_on IS NULL;

EXPLAIN
SELECT *
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;


-- ---------- (g) Scheduled job ----------
-- Idempotent refresh: replaces snapshot for the given date on rerun.
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
      FROM loans
     WHERE returned_on IS NULL
       AND due_on < p_as_of
    ON CONFLICT (snapshot_date) DO UPDATE
       SET overdue_count = EXCLUDED.overdue_count,
           total_fine    = EXCLUDED.total_fine;
END;
$$;

-- Register schedule ONLY if pg_cron exists.
-- Inner string uses $cron$ ... $cron$ to avoid clashing with outer $$.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule(
            'library_overdue',
            '10 0 * * *',
            $cron$CALL pr_refresh_overdue(CURRENT_DATE)$cron$
        );
        RAISE NOTICE 'pg_cron job library_overdue registered (00:10 daily).';
    ELSE
        RAISE NOTICE 'pg_cron not installed; schedule NOT registered.';
        RAISE NOTICE 'Equivalent OS cron: 10 0 * * *  CALL pr_refresh_overdue(CURRENT_DATE);';
    END IF;
END
$$;

-- Prove idempotency: rerun must replace, not duplicate/double-count
CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary ORDER BY snapshot_date;

-- Optional inspection if pg_cron is installed:
-- SELECT jobid, schedule, command FROM cron.job WHERE jobname = 'library_overdue';
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;