-- ============================================================
-- QUESTION 10: Scholarship Application Assessment
-- PostgreSQL solution (pg_cron-safe, nested dollar-quote safe)
-- ============================================================

-- ---------- (a) Database and seed data ----------
DROP TABLE IF EXISTS decision_audit CASCADE;
DROP TABLE IF EXISTS applications CASCADE;
DROP TABLE IF EXISTS students CASCADE;

CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20) UNIQUE NOT NULL,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on       DATE NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(10) NOT NULL DEFAULT 'PENDING'
        CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Seed: three students
INSERT INTO students (student_number, full_name) VALUES
 ('ST001','Ann'),('ST002','Ben'),('ST003','Cia');

-- Seed six PENDING applications covering qualifying, non-qualifying, boundary
INSERT INTO applications
  (student_id, age_at_application, monthly_income, average_mark, submitted_on, status)
VALUES
 (1, 18, 3000, 70,    CURRENT_DATE - 10, 'PENDING'),  -- qualifying boundary (age=18, income=3000, mark=70)
 (1, 25, 3000, 70,    CURRENT_DATE - 9,  'PENDING'),  -- qualifying boundary (age=25)
 (2, 17, 2500, 80,    CURRENT_DATE - 8,  'PENDING'),  -- age too low
 (2, 22, 3001, 80,    CURRENT_DATE - 7,  'PENDING'),  -- income too high
 (3, 20, 2000, 69.99, CURRENT_DATE - 6,  'PENDING'),  -- mark too low
 (3, 20, 2000, 75,    CURRENT_DATE - 5,  'PENDING');  -- qualifying


-- ---------- (b) Function ----------
-- Eligible iff 18 <= age <= 25 AND income <= 3000 AND mark >= 70.
-- Rejects NULL inputs, negative income, non-positive age, mark outside 0..100.
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INTEGER,
    p_income NUMERIC,
    p_mark   NUMERIC
)
RETURNS BOOLEAN AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'All inputs (age, income, mark) are required';
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Income must be >= 0 (got %)', p_income;
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Age must be positive (got %)', p_age;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Mark must be between 0 and 100 (got %)', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark   >= 70;
END;
$$ LANGUAGE plpgsql;


-- ---------- (c) Procedure ----------
-- Only PENDING applications can be assessed. Calls the function and
-- flips status to APPROVED / REJECTED. Clear error for unknown/already assessed.
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql AS $$
DECLARE
    v_age    INTEGER;
    v_income NUMERIC(12,2);
    v_mark   NUMERIC(5,2);
    v_status VARCHAR(10);
    v_ok     BOOLEAN;
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
      INTO v_age, v_income, v_mark, v_status
      FROM applications
     WHERE application_id = p_application_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (status = %)',
            p_application_id, v_status;
    END IF;

    v_ok := fn_scholarship_eligible(v_age, v_income, v_mark);

    UPDATE applications
       SET status = CASE WHEN v_ok THEN 'APPROVED' ELSE 'REJECTED' END
     WHERE application_id = p_application_id;
END;
$$;

-- Example: assess a single application up-front
CALL pr_assess_application(1);


-- ---------- (d) Trigger ----------
-- AFTER UPDATE: log actual status changes only (unchanged status = no row).
CREATE OR REPLACE FUNCTION trg_decision_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
        VALUES (OLD.application_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_decision_audit ON applications;
CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
EXECUTE FUNCTION trg_decision_audit();


-- ---------- (e) View ----------
-- APPROVED only; income intentionally omitted.
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

SELECT * FROM v_approved_applicants;


-- ---------- (f) Index ----------
-- Composite index: status equality + submitted_on range.
-- Justification: matches the query filter order below.
CREATE INDEX IF NOT EXISTS idx_apps_status_submitted
    ON applications (status, submitted_on);

EXPLAIN
SELECT *
FROM applications
WHERE status = 'PENDING'
  AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;


-- ---------- (g) Scheduled job ----------
-- Process only PENDING applications; a rerun cannot reassess completed rows
-- (the procedure raises on non-PENDING) and cannot duplicate audit rows
-- (trigger fires only when status actually changes).
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT application_id
               FROM applications
              WHERE status = 'PENDING'
              ORDER BY application_id
    LOOP
        CALL pr_assess_application(r.application_id);
    END LOOP;
END;
$$;

-- Register the schedule ONLY if pg_cron exists.
-- Inner literal uses $cron$ ... $cron$ so it cannot close the outer DO $$.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule(
            'scholarship_pending',
            '0 8 * * 1',        -- every Monday at 08:00
            $cron$CALL pr_assess_pending()$cron$
        );
        RAISE NOTICE 'pg_cron job scholarship_pending registered (Mon 08:00).';
    ELSE
        RAISE NOTICE 'pg_cron not installed; schedule NOT registered.';
        RAISE NOTICE 'Equivalent OS cron: 0 8 * * 1  CALL pr_assess_pending();';
    END IF;
END
$$;

-- Demonstrate idempotency: first run processes PENDING rows,
-- rerun finds nothing PENDING and audits nothing extra.
CALL pr_assess_pending();
CALL pr_assess_pending();

-- Verification: statuses and audit rows
SELECT application_id, status FROM applications ORDER BY application_id;
SELECT * FROM decision_audit ORDER BY audit_id;
SELECT * FROM v_approved_applicants;

-- Optional inspection if pg_cron is installed:
-- SELECT jobid, schedule, command FROM cron.job WHERE jobname = 'scholarship_pending';
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;