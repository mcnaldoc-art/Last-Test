-- ============================================================
-- QUESTION 2: University Fee Payments
-- PostgreSQL solution (pg_cron-safe, nested dollar-quote safe)
-- ============================================================

-- ---------- (a) Database and seed data ----------
DROP TABLE IF EXISTS payment_audit CASCADE;
DROP TABLE IF EXISTS payments CASCADE;
DROP TABLE IF EXISTS daily_collections CASCADE;
DROP TABLE IF EXISTS students CASCADE;

-- Students: unique student number, non-negative fee due
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name      VARCHAR(100) NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

-- Payments: FK to students, positive amount
CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL DEFAULT CURRENT_DATE
);

-- payment_audit: FKs to both payments and students
CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- daily_collections: one row per date
CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER NOT NULL DEFAULT 0,
    total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Seed: three students; the third has NO payments
INSERT INTO students (student_number, full_name, fee_due) VALUES
 ('S001','Alice Mwale', 5000.00),
 ('S002','Bob Phiri',   7500.00),
 ('S003','Carol Banda', 6000.00);

-- NOTE: the six seed payments are loaded through pr_receive_payment
--       AFTER step (d) (the trigger) is installed so every seed payment
--       also gets an audit row automatically.


-- ---------- (b) Function ----------
-- Returns fee_due minus total payments. Returns full fee when no payments.
-- Rejects unknown student.
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC AS $$
DECLARE
    v_due  NUMERIC(12,2);
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_due
      FROM students
     WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0)
      INTO v_paid
      FROM payments
     WHERE student_id = p_student_id;

    RETURN v_due - v_paid;
END;
$$ LANGUAGE plpgsql;


-- ---------- (c) Procedure ----------
-- Rejects NULL/zero/negative amount and overpayment.
-- Inserts the payment; does NOT touch fee_due; does NOT insert audit row.
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount     NUMERIC,
    p_paid_on    DATE
)
LANGUAGE plpgsql AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive (got %)', p_amount;
    END IF;

    -- Lock student row to prevent concurrent overpayment
    PERFORM 1
       FROM students
      WHERE student_id = p_student_id
        FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % for student %',
            p_amount, v_balance, p_student_id;
    END IF;

    -- Valid payment: audit row is created by the AFTER INSERT trigger in (d)
    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, COALESCE(p_paid_on, CURRENT_DATE));
END;
$$;


-- ---------- (d) Trigger ----------
-- AFTER INSERT: auto-writes payment_id, student_id, amount, timestamp.
CREATE OR REPLACE FUNCTION trg_payments_audit()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_payments_audit ON payments;
CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_payments_audit();

-- Now load six seed payments through the procedure (third student gets none)
CALL pr_receive_payment(1, 1000.00, CURRENT_DATE);
CALL pr_receive_payment(1,  500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(1,  250.00, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 2000.00, CURRENT_DATE);
CALL pr_receive_payment(2, 1500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2,  750.00, CURRENT_DATE - 2);

-- Every seed payment above produced an audit row automatically:
-- SELECT * FROM payment_audit ORDER BY audit_id;

-- Optional: prove an invalid payment leaves both tables unchanged
-- CALL pr_receive_payment(2, 999999, CURRENT_DATE);   -- exceeds balance


-- ---------- (e) View ----------
-- Students who still owe; fully settled students excluded (HAVING > 0).
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       (s.fee_due - COALESCE(SUM(p.amount), 0)) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING (s.fee_due - COALESCE(SUM(p.amount), 0)) > 0;

SELECT * FROM v_fee_balances;


-- ---------- (f) Index ----------
-- Composite index: equality on student_id, range scan on paid_on.
-- Justification: the matching query filters ONE student over a date range,
-- so (student_id, paid_on) is the optimal leading order.
CREATE INDEX IF NOT EXISTS idx_payments_student_date
    ON payments (student_id, paid_on);

EXPLAIN
SELECT *
FROM payments
WHERE student_id = 1
  AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;


-- ---------- (g) Scheduled job ----------
-- Idempotent refresh: replaces the day's summary on rerun.
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day,
           COUNT(*),
           COALESCE(SUM(amount), 0)
      FROM payments
     WHERE paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
       SET payment_count = EXCLUDED.payment_count,
           total_amount  = EXCLUDED.total_amount;
END;
$$;

-- Register schedule ONLY if pg_cron exists.
-- Inner command uses $cron$ ... $cron$ so it does not collide with outer $$.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule(
            'univ_daily_collections',
            '0 1 * * *',
            $cron$CALL pr_refresh_collections(CURRENT_DATE - 1)$cron$
        );
        RAISE NOTICE 'pg_cron job univ_daily_collections registered (01:00 daily).';
    ELSE
        RAISE NOTICE 'pg_cron not installed; schedule NOT registered.';
        RAISE NOTICE 'Equivalent OS cron: 0 1 * * *  CALL pr_refresh_collections(CURRENT_DATE - 1);';
    END IF;
END
$$;

-- Prove idempotency: rerun must replace, not duplicate/double-count
CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);
SELECT * FROM daily_collections ORDER BY collection_date;

-- Optional inspection if pg_cron is installed:
-- SELECT jobid, schedule, command FROM cron.job WHERE jobname = 'univ_daily_collections';
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;