-- ============================================================
-- QUESTION 7: Water Meter Readings and Billing
-- PostgreSQL solution (pg_cron-safe, nested dollar-quote safe)
-- ============================================================

-- ---------- (a) Database and seed data ----------
DROP TABLE IF EXISTS receivable_snapshot CASCADE;
DROP TABLE IF EXISTS bills CASCADE;
DROP TABLE IF EXISTS readings CASCADE;
DROP TABLE IF EXISTS customers CASCADE;

CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

-- Readings: month-start date; meter values non-negative; unique per customer/month
CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL,
    previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(12,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_read_cust_month UNIQUE (customer_id, reading_month),
    CONSTRAINT chk_reading_month_first CHECK (EXTRACT(DAY FROM reading_month) = 1)
);

-- Bills: one per reading; amount_paid between 0 and charge
CREATE TABLE bills (
    bill_id      SERIAL PRIMARY KEY,
    reading_id   INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge       NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid  NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (amount_paid >= 0),
    due_on       DATE NOT NULL,
    CONSTRAINT chk_paid_not_exceed_charge CHECK (amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL DEFAULT 0
);

-- Seed: three customers
INSERT INTO customers (full_name) VALUES ('Cust A'),('Cust B'),('Cust C');

-- Seed six readings: zero, exactly 10, and above 10 units covered
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
 (1, DATE_TRUNC('month', CURRENT_DATE - INTERVAL '5 month')::DATE,   0,   0),  -- zero units
 (1, DATE_TRUNC('month', CURRENT_DATE - INTERVAL '4 month')::DATE,   0,  10),  -- exactly 10
 (1, DATE_TRUNC('month', CURRENT_DATE - INTERVAL '3 month')::DATE,  10,  25),  -- above 10
 (2, DATE_TRUNC('month', CURRENT_DATE - INTERVAL '2 month')::DATE, 100, 110),  -- exactly 10
 (2, DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::DATE, 110, 130),  -- above 10
 (3, DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::DATE,   5,  12);  -- above 10


-- ---------- (b) Function ----------
-- Two-band tariff: first 10 units @ K5, above 10 @ K8. Exact 2 decimals.
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC AS $$
DECLARE
    v_first NUMERIC := 0;
    v_rest  NUMERIC := 0;
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption must be non-negative (got %)', p_units;
    END IF;

    v_first := LEAST(p_units, 10) * 5;
    v_rest  := GREATEST(p_units - 10, 0) * 8;

    RETURN ROUND(v_first + v_rest, 2);
END;
$$ LANGUAGE plpgsql;


-- ---------- (c) Procedure ----------
-- Derives consumption, calls fn_water_charge, inserts bill with amount_paid = 0.
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_prev   NUMERIC(12,2);
    v_curr   NUMERIC(12,2);
    v_units  NUMERIC(12,2);
    v_charge NUMERIC(12,2);
BEGIN
    SELECT previous_reading, current_reading
      INTO v_prev, v_curr
      FROM readings
     WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_units  := v_curr - v_prev;
    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, COALESCE(p_due_on, CURRENT_DATE + 30));
END;
$$;

-- Generate bills for all seeded readings
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT reading_id FROM readings ORDER BY reading_id LOOP
        CALL pr_generate_bill(r.reading_id, CURRENT_DATE + 30);
    END LOOP;
END
$$;

-- Mark a bill with NON-ZERO charge as partially paid (bill 3 = 10→25 units)
-- FIX: previous version tried to pay bill 1 which has charge = 0 (zero consumption),
-- violating chk_paid_not_exceed_charge.
UPDATE bills
   SET amount_paid = LEAST(10, charge)   -- defensive: cap at the bill's charge
 WHERE bill_id = 3;


-- ---------- (d) Trigger ----------
-- Reject current_reading < previous_reading on INSERT/UPDATE (direct SQL too).
CREATE OR REPLACE FUNCTION trg_readings_order()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be below previous_reading (%)',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_readings_order ON readings;
CREATE TRIGGER trg_readings_order
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_readings_order();


-- ---------- (e) View ----------
-- Overdue & not fully paid bills.
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name,
       b.due_on,
       (b.charge - b.amount_paid) AS outstanding
FROM bills b
JOIN readings r  ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills;


-- ---------- (f) Index ----------
-- Partial index on due_on for the unpaid-overdue query.
-- Justification: the matching query filters due_on < CURRENT_DATE AND
-- amount_paid < charge, so the partial predicate matches the same rows.
CREATE INDEX IF NOT EXISTS idx_bills_due_unpaid
    ON bills (due_on) WHERE amount_paid < charge;

EXPLAIN
SELECT *
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge;


-- ---------- (g) Scheduled job ----------
-- Idempotent upsert of today's total unpaid balance.
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
      FROM bills
     WHERE amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
       SET total_due = EXCLUDED.total_due;
END;
$$;

-- Register schedule ONLY if pg_cron exists.
-- Inner literal uses $cron$ ... $cron$ so it cannot close the outer DO $$.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule(
            'water_receivables',
            '30 0 * * *',
            $cron$CALL pr_refresh_receivables()$cron$
        );
        RAISE NOTICE 'pg_cron job water_receivables registered (00:30 daily).';
    ELSE
        RAISE NOTICE 'pg_cron not installed; schedule NOT registered.';
        RAISE NOTICE 'Equivalent OS cron: 30 0 * * *  CALL pr_refresh_receivables();';
    END IF;
END
$$;

-- Prove idempotency: rerun must replace, not double-count
CALL pr_refresh_receivables();
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot ORDER BY snapshot_date;

-- Optional if pg_cron is installed:
-- SELECT jobid, schedule, command FROM cron.job WHERE jobname = 'water_receivables';
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;