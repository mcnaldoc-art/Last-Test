-- ============================================================
-- QUESTION 5: Hostel Room Allocation
-- PostgreSQL solution (pg_cron-safe, nested dollar-quote safe)
-- ============================================================

-- ---------- (a) Database and seed data ----------
DROP TABLE IF EXISTS occupancy_snapshot CASCADE;
DROP TABLE IF EXISTS allocations CASCADE;
DROP TABLE IF EXISTS rooms CASCADE;
DROP TABLE IF EXISTS students CASCADE;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) UNIQUE NOT NULL,
    capacity    INTEGER NOT NULL CHECK (capacity > 0)
);

-- ACTIVE => released_on NULL; ENDED => release date present.
CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER NOT NULL REFERENCES students(student_id),
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL DEFAULT CURRENT_DATE,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE','ENDED')),
    CONSTRAINT chk_alloc_status CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL DEFAULT 0,
    free_beds     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (snapshot_date, room_id)
);

-- Seed: four students
INSERT INTO students (student_number, full_name) VALUES
 ('ST001','Ann'),('ST002','Ben'),('ST003','Cia'),('ST004','Dan');

-- Seed: one full, one partly occupied, one empty room
INSERT INTO rooms (room_number, capacity) VALUES
 ('R101',2),   -- will be full
 ('R102',3),   -- partly occupied
 ('R103',2);   -- empty

-- Seed allocations (built AFTER trigger in (d) so trigger enforces rules)
-- NOTE: we insert these below, after creating trg_alloc_guard().
-- This block just records the intent; actual inserts happen after (d).
--
-- (1,1) ACTIVE   -> fills R101 bed 1
-- (2,1) ACTIVE   -> fills R101 bed 2  (R101 becomes full)
-- (3,2) ACTIVE   -> takes 1 of 3 in R102
-- (4,2) ENDED    -> historical, does NOT consume a bed


-- ---------- (b) Function ----------
-- Returns capacity - ACTIVE allocations. Rejects unknown room.
-- ENDED allocations do not reduce availability.
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER AS $$
DECLARE
    v_cap    INTEGER;
    v_active INTEGER;
BEGIN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
      FROM allocations
     WHERE room_id = p_room_id
       AND status = 'ACTIVE';

    RETURN v_cap - v_active;
END;
$$ LANGUAGE plpgsql;


-- ---------- (c) Procedure ----------
-- Validates IDs, ensures one ACTIVE allocation per student,
-- checks availability; inserts one ACTIVE allocation with released_on NULL.
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id  INTEGER,
    p_room_id     INTEGER,
    p_allocated_on DATE
)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;

    -- Lock the room row for the duration of the check+insert
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id %', p_room_id;
    END IF;

    IF EXISTS (
        SELECT 1 FROM allocations
         WHERE student_id = p_student_id
           AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;

    INSERT INTO allocations
        (student_id, room_id, allocated_on, released_on, status)
    VALUES
        (p_student_id, p_room_id, COALESCE(p_allocated_on, CURRENT_DATE), NULL, 'ACTIVE');
END;
$$;


-- ---------- (d) Trigger ----------
-- BEFORE INSERT OR UPDATE: enforces capacity and one-ACTIVE-per-student
-- for direct SQL changes too. Row being updated is excluded from counts.
CREATE OR REPLACE FUNCTION trg_alloc_guard()
RETURNS TRIGGER AS $$
DECLARE
    v_cap    INTEGER;
    v_active INTEGER;
BEGIN
    -- Only ACTIVE rows consume beds
    IF NEW.status <> 'ACTIVE' THEN
        RETURN NEW;
    END IF;

    SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id %', NEW.room_id;
    END IF;

    -- Count OTHER ACTIVE allocations in this room (exclude the row being updated)
    SELECT COUNT(*) INTO v_active
      FROM allocations
     WHERE room_id = NEW.room_id
       AND status = 'ACTIVE'
       AND allocation_id <> COALESCE(NEW.allocation_id, -1);

    IF v_active >= v_cap THEN
        RAISE EXCEPTION 'Room % capacity % reached', NEW.room_id, v_cap;
    END IF;

    -- One ACTIVE per student (exclude the row being updated)
    IF EXISTS (
        SELECT 1 FROM allocations
         WHERE student_id = NEW.student_id
           AND status = 'ACTIVE'
           AND allocation_id <> COALESCE(NEW.allocation_id, -1)
    ) THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_alloc_guard ON allocations;
CREATE TRIGGER trg_alloc_guard
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_alloc_guard();

-- Now load the seed allocations — trigger is active and enforces rules.
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
 (1,1,CURRENT_DATE-10,NULL,'ACTIVE'),          -- R101 bed 1
 (2,1,CURRENT_DATE-9, NULL,'ACTIVE'),          -- R101 bed 2 (full)
 (3,2,CURRENT_DATE-5, NULL,'ACTIVE'),          -- R102 bed 1
 (4,2,CURRENT_DATE-30,CURRENT_DATE-5,'ENDED'); -- historical, no bed

-- Optional: prove over-capacity is rejected (uncomment to test)
-- INSERT INTO allocations (student_id, room_id, status) VALUES (4,1,'ACTIVE');  -- fails


-- ---------- (e) View ----------
-- Every room, capacity, occupied beds, free beds (incl. empty rooms).
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE') AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy;


-- ---------- (f) Index ----------
-- Partial index: only ACTIVE allocations are queried by room_id.
-- Justification: queries always filter status='ACTIVE', so a partial
-- index is much smaller/faster than indexing the whole table.
CREATE INDEX IF NOT EXISTS idx_alloc_active_room
    ON allocations (room_id) WHERE status = 'ACTIVE';

EXPLAIN
SELECT *
FROM allocations
WHERE room_id = 2
  AND status = 'ACTIVE';


-- ---------- (g) Scheduled job ----------
-- Idempotent refresh: one row per (date, room); replace on rerun.
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE,
           r.room_id,
           COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE'),
           r.capacity - COUNT(a.allocation_id) FILTER (WHERE a.status = 'ACTIVE')
      FROM rooms r
      LEFT JOIN allocations a ON a.room_id = r.room_id
     GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
       SET occupied_beds = EXCLUDED.occupied_beds,
           free_beds     = EXCLUDED.free_beds;
END;
$$;

-- Register schedule ONLY if pg_cron exists.
-- Inner literal uses $cron$ ... $cron$ so it cannot close the outer DO $$.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule(
            'hostel_occupancy',
            '55 23 * * *',
            $cron$CALL pr_refresh_occupancy()$cron$
        );
        RAISE NOTICE 'pg_cron job hostel_occupancy registered (23:55 daily).';
    ELSE
        RAISE NOTICE 'pg_cron not installed; schedule NOT registered.';
        RAISE NOTICE 'Equivalent OS cron: 55 23 * * *  CALL pr_refresh_occupancy();';
    END IF;
END
$$;

-- Prove idempotency: rerun must replace, not duplicate
CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date, room_id;

-- Optional inspection if pg_cron is installed:
-- SELECT jobid, schedule, command FROM cron.job WHERE jobname = 'hostel_occupancy';
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;