-- ============================================================
-- QUESTION 6: Monthly Payroll Processing
-- PostgreSQL solution (pg_cron-safe, nested dollar-quote safe)
-- ============================================================

-- ---------- (a) Database and seed data ----------
DROP TABLE IF EXISTS salary_audit CASCADE;
DROP TABLE IF EXISTS payroll CASCADE;
DROP TABLE IF EXISTS employees CASCADE;

CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100) NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);

-- pay_month is stored as the FIRST day of the month; unique per employee.
CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    CONSTRAINT uq_payroll_emp_month UNIQUE (employee_id, pay_month),
    CONSTRAINT chk_pay_month_first CHECK (EXTRACT(DAY FROM pay_month) = 1)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2),
    new_salary  NUMERIC(12,2),
    changed_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Seed: active + inactive employees
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
 ('Emp A', 5000.00, 500.00, 300.00, TRUE),
 ('Emp B', 8000.00, 700.00, 400.00, TRUE),
 ('Emp C', 6500.00, 300.00, 200.00, TRUE),
 ('Emp D', 4000.00, 200.00, 150.00, FALSE);

-- Seed two payroll months for active employees (call procedure after (c))
-- This is done below after pr_process_payroll() is defined.


-- ---------- (b) Function ----------
-- Net pay = basic + allowance - deduction. Rejects unknown or negative net.
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC AS $$
DECLARE
    v_basic     NUMERIC(12,2);
    v_allowance NUMERIC(12,2);
    v_deduction NUMERIC(12,2);
    v_net       NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction
      INTO v_basic, v_allowance, v_deduction
      FROM employees
     WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id %', p_employee_id;
    END IF;

    v_net := v_basic + v_allowance - v_deduction;

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Computed net pay is negative (%) for employee %',
            v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$ LANGUAGE plpgsql;


-- ---------- (c) Procedure ----------
-- Requires month-start date. Inserts missing employee/month rows only;
-- existing payroll rows are left unchanged.
-- Any invalid calculation aborts the whole call (implicit transaction).
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_emp   RECORD;
    v_gross NUMERIC(12,2);
    v_net   NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month (got %)', p_month;
    END IF;

    -- FOR loop over ACTIVE employees
    FOR v_emp IN SELECT employee_id, basic_salary, allowance, deduction
                   FROM employees
                  WHERE active = TRUE
    LOOP
        v_gross := v_emp.basic_salary + v_emp.allowance;
        v_net   := fn_net_pay(v_emp.employee_id);   -- may raise and abort

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (v_emp.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;  -- leave existing unchanged
    END LOOP;
END;
$$;

-- Seed two payroll months via the procedure
CALL pr_process_payroll(DATE_TRUNC('month', CURRENT_DATE - INTERVAL '2 month')::DATE);
CALL pr_process_payroll(DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::DATE);


-- ---------- (d) Trigger ----------
-- Log only actual basic_salary changes.
CREATE OR REPLACE FUNCTION trg_salary_audit()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.basic_salary IS DISTINCT FROM OLD.basic_salary THEN
        INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
        VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, CURRENT_TIMESTAMP);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_salary_audit ON employees;
CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
EXECUTE FUNCTION trg_salary_audit();

-- Optional: prove no audit row when salary unchanged
-- UPDATE employees SET allowance = allowance + 10 WHERE employee_id = 1;


-- ---------- (e) View ----------
-- Join names to payroll; includes historical rows for inactive employees.
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;


-- ---------- (f) Index ----------
-- Report index on pay_month alone (existing UQ covers employee/month).
-- Justification: monthly reports filter ALL employees by pay_month, so
-- a single-column index on pay_month is optimal and does not duplicate
-- the existing unique (employee_id, pay_month) index.
CREATE INDEX IF NOT EXISTS idx_payroll_month
    ON payroll (pay_month);

EXPLAIN
SELECT *
FROM payroll
WHERE pay_month = DATE_TRUNC('month', CURRENT_DATE)::DATE;


-- ---------- (g) Scheduled job ----------
-- First day of each month at 02:00, passing the previous month's first date.
-- pg_cron uses standard cron, but "day-of-month = 1" gives us the monthly run.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        PERFORM cron.schedule(
            'payroll_monthly',
            '0 2 1 * *',
            $cron$CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month'))::DATE)$cron$
        );
        RAISE NOTICE 'pg_cron job payroll_monthly registered (02:00 on the 1st).';
    ELSE
        RAISE NOTICE 'pg_cron not installed; schedule NOT registered.';
        RAISE NOTICE 'Equivalent OS cron: 0 2 1 * *  CALL pr_process_payroll(previous month start);';
    END IF;
END
$$;

-- Inspect the job and run history (only works if pg_cron is installed)
-- SELECT jobid, schedule, command FROM cron.job WHERE jobname = 'payroll_monthly';
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 5;

-- Prove idempotency: rerun must not duplicate or change existing rows
CALL pr_process_payroll(DATE_TRUNC('month', CURRENT_DATE - INTERVAL '1 month')::DATE);
SELECT * FROM payroll ORDER BY pay_month, employee_id;