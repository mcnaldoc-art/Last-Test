-- ============================================================
-- QUESTION 4: Clinic Appointment Scheduling
-- PostgreSQL solution (pg_cron-safe, nested dollar-quote safe)
-- ============================================================

-- ---------- (a) Database and seed data ----------
DROP TABLE IF EXISTS clinic_summary CASCADE;
DROP TABLE IF EXISTS appointments CASCADE;
DROP TABLE IF EXISTS doctors CASCADE;
DROP TABLE IF EXISTS patients CASCADE;

CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

-- Appointments: slot_time is TIME; status in three states;
-- only the four supported slots are allowed.
CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL,
    status          VARCHAR(10) NOT NULL
        CHECK (status IN ('BOOKED','ATTENDED','CANCELLED')),
    CONSTRAINT chk_slot CHECK (slot_time IN
        (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL DEFAULT 0,
    attended_count  INTEGER NOT NULL DEFAULT 0,
    cancelled_count INTEGER NOT NULL DEFAULT 0
);

-- Seed: three patients, three doctors
INSERT INTO patients (full_name) VALUES ('Pat A'),('Pat B'),('Pat C');
INSERT INTO doctors  (full_name) VALUES ('Dr X'),('Dr Y'),('Dr Z');

-- Seed: six appointments, no slot conflicts per (doctor, day, slot).
-- Two slots per doctor per day; two future days used.
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
 (1,1, CURRENT_DATE,   TIME '09:00','BOOKED'),
 (2,1, CURRENT_DATE,   TIME '10:00','ATTENDED'),
 (3,2, CURRENT_DATE,   TIME '09:00','CANCELLED'),
 (1,2, CURRENT_DATE,   TIME '11:00','BOOKED'),
 (2,3, CURRENT_DATE+1, TIME '09:00','BOOKED'),
 (3,3, CURRENT_DATE+1, TIME '12:00','BOOKED');


-- ---------- (b) Function ----------
-- Count of doctor's NON-CANCELLED appointments on a day.
-- Rejects unknown doctor; returns 0 if no bookings.
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER AS $$
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id %', p_doctor_id;
    END IF;

    RETURN COALESCE((
        SELECT COUNT(*)
          FROM appointments
         WHERE doctor_id = p_doctor_id
           AND appointment_day = p_day
           AND status <> 'CANCELLED'
    ), 0);
END;
$$ LANGUAGE plpgsql;


-- ---------- (c) Procedure ----------
-- Validates IDs, past date, supported slot; inserts BOOKED appointment.
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id  INTEGER,
    p_day        DATE,
    p_slot       TIME
)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id %', p_doctor_id;
    END IF;

    IF p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Cannot book a past date %', p_day;
    END IF;

    IF p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot %', p_slot;
    END IF;

    -- Clash check is also enforced by the trigger in (d),
    -- but a clear message here improves usability.
    IF EXISTS (
        SELECT 1 FROM appointments
         WHERE doctor_id = p_doctor_id
           AND appointment_day = p_day
           AND slot_time = p_slot
           AND status <> 'CANCELLED'
    ) THEN
        RAISE EXCEPTION 'Slot % on % for doctor % is already taken',
            p_slot, p_day, p_doctor_id;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- Example valid booking (no clash)
CALL pr_book_appointment(1, 3, CURRENT_DATE + 2, TIME '10:00');


-- ---------- (d) Trigger ----------
-- BEFORE INSERT OR UPDATE row trigger rejects clashes with another
-- non-cancelled appointment. On UPDATE the row itself is excluded.
CREATE OR REPLACE FUNCTION trg_appt_clash()
RETURNS TRIGGER AS $$
DECLARE
    v_conflict INTEGER;
BEGIN
    -- Cancelled appointments do not occupy a slot
    IF NEW.status = 'CANCELLED' THEN
        RETURN NEW;
    END IF;

    SELECT COUNT(*) INTO v_conflict
      FROM appointments
     WHERE doctor_id = NEW.doctor_id
       AND appointment_day = NEW.appointment_day
       AND slot_time = NEW.slot_time
       AND status <> 'CANCELLED'
       -- Exclude the row being updated (NULL on INSERT)
       AND appointment_id <> COALESCE(NEW.appointment_id, -1);

    IF v_conflict > 0 THEN
        RAISE EXCEPTION 'Clash: slot % on % for doctor % is already taken',
            NEW.slot_time, NEW.appointment_day, NEW.doctor_id;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_appt_clash ON appointments;
CREATE TRIGGER trg_appt_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_appt_clash();

-- Optional: prove clash rejection (uncomment to test)
-- CALL pr_book_appointment(3, 1, CURRENT_DATE, TIME '09:00');  -- should fail


-- ---------- (e) View ----------
-- Only today's BOOKED appointments; only the columns needed.
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments;


-- ---------- (f) Index ----------
-- Non-unique index for appointments searched by day and doctor.
-- Justification: the matching query filters both columns, so a
-- composite index (appointment_day, doctor_id) is optimal.
CREATE INDEX IF NOT EXISTS idx_appt_day_doctor
    ON appointments (appointment_day, doctor_id);

EXPLAIN
SELECT *
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;


-- ---------- (g) Scheduled job ----------
-- Idempotent refresh: replaces summary for the given day on rerun.
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO clinic_summary
        (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
      FROM appointments
     WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
       SET booked_count    = EXCLUDED.booked_count,
           attended_count  = EXCLUDED.attended_count,
           cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

-- Register schedule ONLY if pg_cron exists.
-- Inner literal uses $cron$ ... $cron$ so it cannot close the outer DO $$.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule(
            'clinic_summary',
            '0 1 * * *',
            $cron$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$cron$
        );
        RAISE NOTICE 'pg_cron job clinic_summary registered (01:00 daily).';
    ELSE
        RAISE NOTICE 'pg_cron not installed; schedule NOT registered.';
        RAISE NOTICE 'Equivalent OS cron: 0 1 * * *  CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);';
    END IF;
END
$$;

-- Prove idempotency: rerun must replace, not double-count
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
SELECT * FROM clinic_summary ORDER BY summary_date;

-- Optional inspection if pg_cron is installed:
-- SELECT jobid, schedule, command FROM cron.job WHERE jobname = 'clinic_summary';
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;