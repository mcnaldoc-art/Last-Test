-- ============================================================
-- QUESTION 9: Farmer Cooperative Maize Deliveries
-- PostgreSQL solution (pg_cron-safe, nested dollar-quote safe)
-- ============================================================

-- ---------- (a) Database and seed data ----------
DROP TABLE IF EXISTS daily_purchases CASCADE;
DROP TABLE IF EXISTS deliveries CASCADE;
DROP TABLE IF EXISTS farmers CASCADE;

CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20) UNIQUE NOT NULL,
    full_name     VARCHAR(100) NOT NULL
);

-- unit_rate and total_value are supplied by the trigger in (d),
-- so allow NULL / DEFAULT 0 initially.
CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade        VARCHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
    weight_kg    NUMERIC(12,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (unit_rate >= 0),
    total_value  NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (total_value >= 0),
    delivered_on DATE NOT NULL DEFAULT CURRENT_DATE,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(14,2) NOT NULL DEFAULT 0,
    total_value   NUMERIC(14,2) NOT NULL DEFAULT 0
);

-- Seed: three farmers
INSERT INTO farmers (farmer_number, full_name) VALUES
 ('F001','Farmer A'),('F002','Farmer B'),('F003','Farmer C');

-- Six deliveries loaded via procedure AFTER trigger in (d) so the trigger
-- supplies unit_rate and total_value. See CALL block after (d).


-- ---------- (b) Function ----------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade VARCHAR)
RETURNS NUMERIC AS $$
BEGIN
    IF p_grade IS NULL OR p_grade NOT IN ('A','B','C') THEN
        RAISE EXCEPTION 'Unsupported grade % (allowed A/B/C)', p_grade;
    END IF;

    RETURN CASE p_grade
        WHEN 'A' THEN 5
        WHEN 'B' THEN 4
        WHEN 'C' THEN 3
    END;
END;
$$ LANGUAGE plpgsql;


-- ---------- (c) Procedure ----------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     VARCHAR,
    p_weight    NUMERIC,
    p_date      DATE
)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer_id %', p_farmer_id;
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive (got %)', p_weight;
    END IF;

    -- unit_rate and total_value supplied by the trigger in (d)
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight,
            COALESCE(p_date, CURRENT_DATE), FALSE);
END;
$$;


-- ---------- (d) Trigger ----------
-- BEFORE INSERT OR UPDATE: enforces pricing and positive weight for ALL paths
-- (including direct SQL imports).
CREATE OR REPLACE FUNCTION trg_maize_pricing()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'weight_kg must be positive (got %)', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_maize_pricing ON deliveries;
CREATE TRIGGER trg_maize_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_maize_pricing();

-- Seed six deliveries via procedure (trigger supplies rate & total).
CALL pr_receive_delivery(1, 'A', 100, CURRENT_DATE - 5);
CALL pr_receive_delivery(1, 'B',  80, CURRENT_DATE - 4);
CALL pr_receive_delivery(2, 'C',  60, CURRENT_DATE - 3);
CALL pr_receive_delivery(2, 'A', 120, CURRENT_DATE - 2);
CALL pr_receive_delivery(3, 'B',  50, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'C',  70, CURRENT_DATE);

-- Mark some deliveries as paid (to exercise unpaid view)
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (1, 2, 4);


-- ---------- (e) View ----------
-- All farmers, unpaid total (0 when none).
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE d.is_paid = FALSE), 0) AS amount_due
FROM farmers f
LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due;


-- ---------- (f) Index ----------
CREATE INDEX IF NOT EXISTS idx_deliv_farmer_date
    ON deliveries (farmer_id, delivered_on);

EXPLAIN
SELECT *
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;


-- ---------- (g) Scheduled job ----------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day,
           COALESCE(SUM(weight_kg), 0),
           COALESCE(SUM(total_value), 0)
      FROM deliveries
     WHERE delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
       SET total_weight = EXCLUDED.total_weight,
           total_value  = EXCLUDED.total_value;
END;
$$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule(
            'maize_daily_purchases',
            '30 1 * * *',
            $cron$CALL pr_refresh_purchases(CURRENT_DATE - 1)$cron$
        );
        RAISE NOTICE 'pg_cron job maize_daily_purchases registered (01:30 daily).';
    ELSE
        RAISE NOTICE 'pg_cron not installed; schedule NOT registered.';
        RAISE NOTICE 'Equivalent OS cron: 30 1 * * *  CALL pr_refresh_purchases(CURRENT_DATE - 1);';
    END IF;
END
$$;

-- Idempotency proof
CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);
SELECT * FROM daily_purchases ORDER BY purchase_date;