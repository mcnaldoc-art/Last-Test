-- ============================================================
-- QUESTION 8: Transport Fleet Maintenance
-- PostgreSQL solution (pg_cron-safe, nested dollar-quote safe)
-- ============================================================

-- ---------- (a) Database and seed data ----------
DROP TABLE IF EXISTS service_alerts CASCADE;
DROP TABLE IF EXISTS trips CASCADE;
DROP TABLE IF EXISTS vehicles CASCADE;

CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(20) UNIQUE NOT NULL,
    current_odometer      NUMERIC(12,2) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(12,2) NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_last_le_current CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id         SERIAL PRIMARY KEY,
    vehicle_id      INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on         DATE NOT NULL,
    start_odometer  NUMERIC(12,2) NOT NULL CHECK (start_odometer >= 0),
    end_odometer    NUMERIC(12,2) NOT NULL CHECK (end_odometer >= 0),
    CONSTRAINT chk_end_gt_start CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id      INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(12,2) NOT NULL,
    flagged_on      DATE NOT NULL DEFAULT CURRENT_DATE
);

-- Seed: three vehicles at different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
 ('AA-001', 10000, 4000),   -- 6000 km since service -> due
 ('BB-002',  8000, 6000),   -- 2000 km since service -> not due
 ('CC-003', 20000,14000);   -- 6000 km since service -> due

-- Seed: six trips (INSERT via procedure AFTER trigger installed in (d))
-- Per exam: "Add trips through the procedure after the trigger is installed."


-- ---------- (b) Function ----------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN AS $$
DECLARE
    v_cur  NUMERIC(12,2);
    v_last NUMERIC(12,2);
BEGIN
    SELECT current_odometer, last_service_odometer
      INTO v_cur, v_last
      FROM vehicles
     WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id %', p_vehicle_id;
    END IF;

    RETURN (v_cur - v_last) >= 5000;
END;
$$ LANGUAGE plpgsql;


-- ---------- (c) Procedure ----------
-- Validates vehicle and end > start; inserts trip. Does NOT update odometer
-- (the trigger in (d) does that).
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      NUMERIC,
    p_end        NUMERIC
)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id %', p_vehicle_id;
    END IF;

    IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)',
            p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, COALESCE(p_trip_on, CURRENT_DATE), p_start, p_end);
END;
$$;


-- ---------- (d) Trigger ----------
-- BEFORE INSERT on trips:
--   * enforce start_odometer == vehicles.current_odometer
--   * enforce end > start
--   * update vehicles.current_odometer to NEW.end_odometer exactly once
CREATE OR REPLACE FUNCTION trg_trip_guard()
RETURNS TRIGGER AS $$
DECLARE
    v_cur NUMERIC(12,2);
BEGIN
    SELECT current_odometer INTO v_cur
      FROM vehicles
     WHERE vehicle_id = NEW.vehicle_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_cur THEN
        RAISE EXCEPTION 'start_odometer (%) must equal vehicle current_odometer (%)',
            NEW.start_odometer, v_cur;
    END IF;

    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)',
            NEW.end_odometer, NEW.start_odometer;
    END IF;

    UPDATE vehicles
       SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_trip_guard ON trips;
CREATE TRIGGER trg_trip_guard
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_trip_guard();

-- Seed six trips via procedure (trigger runs and updates odometer)
CALL pr_record_trip(1, CURRENT_DATE - 5, 10000, 10200);
CALL pr_record_trip(1, CURRENT_DATE - 4, 10200, 10500);
CALL pr_record_trip(2, CURRENT_DATE - 3,  8000,  8200);
CALL pr_record_trip(3, CURRENT_DATE - 2, 20000, 20300);
CALL pr_record_trip(3, CURRENT_DATE - 1, 20300, 20700);
CALL pr_record_trip(2, CURRENT_DATE,       8200,  8500);


-- ---------- (e) View ----------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE (current_odometer - last_service_odometer) >= 5000;

SELECT * FROM v_service_due;


-- ---------- (f) Index ----------
-- One vehicle's trips in a trip_on date range.
CREATE INDEX IF NOT EXISTS idx_trips_vehicle_date
    ON trips (vehicle_id, trip_on);

EXPLAIN
SELECT *
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;


-- ---------- (g) Scheduled job ----------
-- Insert/update alerts for due vehicles, remove alerts no longer due.
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
    -- Upsert alerts for currently-due vehicles
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id,
           (current_odometer - last_service_odometer),
           CURRENT_DATE
      FROM vehicles
     WHERE (current_odometer - last_service_odometer) >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
       SET km_since_service = EXCLUDED.km_since_service,
           flagged_on      = EXCLUDED.flagged_on;

    -- Remove alerts for vehicles no longer due
    DELETE FROM service_alerts sa
     USING vehicles v
     WHERE sa.vehicle_id = v.vehicle_id
       AND (v.current_odometer - v.last_service_odometer) < 5000;
END;
$$;

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule(
            'fleet_service_alerts',
            '0 6 * * 1',        -- every Monday at 06:00
            $cron$CALL pr_refresh_service_alerts()$cron$
        );
        RAISE NOTICE 'pg_cron job fleet_service_alerts registered (Mon 06:00).';
    ELSE
        RAISE NOTICE 'pg_cron not installed; schedule NOT registered.';
        RAISE NOTICE 'Equivalent OS cron: 0 6 * * 1  CALL pr_refresh_service_alerts();';
    END IF;
END
$$;

-- Prove idempotency / removal logic
CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;

-- Optional if pg_cron is installed:
-- SELECT jobid, schedule, command FROM cron.job WHERE jobname = 'fleet_service_alerts';