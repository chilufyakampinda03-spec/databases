-- ============================================================================
-- ICT371 Advanced Database — Question 6: Monthly Payroll Processing
-- ============================================================================

-- (a) Database and seed data [6 marks]
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(120) NOT NULL,
    basic_salary NUMERIC(12, 2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12, 2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12, 2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE NOT NULL CHECK (EXTRACT(DAY FROM pay_month) = 1),
    gross_pay   NUMERIC(12, 2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12, 2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT uq_payroll_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id   SERIAL PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary NUMERIC(12, 2) NOT NULL CHECK (old_salary >= 0),
    new_salary NUMERIC(12, 2) NOT NULL CHECK (new_salary >= 0),
    changed_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

-- Active and inactive employees
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Mwila Chilufya',  10000.00, 2000.00, 1500.00, TRUE),
    ('Taonga Banda',     8500.00, 1500.00, 1200.00, TRUE),
    ('Mulenga Sakala',   7000.00, 1000.00,  800.00, FALSE);

-- (b) Function: fn_net_pay(p_employee_id) [6 marks]
CREATE OR REPLACE FUNCTION fn_net_pay(
    p_employee_id INT
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic     NUMERIC(12, 2);
    v_allowance NUMERIC(12, 2);
    v_deduction NUMERIC(12, 2);
    v_net_pay   NUMERIC(12, 2);
BEGIN
    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allowance, v_deduction
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net_pay := ROUND((v_basic + v_allowance) - v_deduction, 2);

    IF v_net_pay < 0 THEN
        RAISE EXCEPTION 'Computed net pay (%) is negative for employee_id %.',
            v_net_pay, p_employee_id;
    END IF;

    RETURN v_net_pay;
END;
$$;

-- (d) Trigger: AFTER UPDATE trigger on employees for basic_salary changes [8 marks]
CREATE OR REPLACE FUNCTION trg_audit_basic_salary()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER after_employee_basic_salary_update
AFTER UPDATE OF basic_salary ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_audit_basic_salary();

-- (c) Procedure: pr_process_payroll(p_month) [8 marks]
CREATE OR REPLACE PROCEDURE pr_process_payroll(
    p_month DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    rec_emp   RECORD;
    v_gross   NUMERIC(12, 2);
    v_net     NUMERIC(12, 2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month (%) must be the first date of a month (e.g., 2026-10-01).', p_month;
    END IF;

    FOR rec_emp IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active = TRUE
        ORDER BY employee_id
    LOOP
        v_gross := ROUND(rec_emp.basic_salary + rec_emp.allowance, 2);
        v_net   := fn_net_pay(rec_emp.employee_id);

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec_emp.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- Seed two payroll months (including historical row for employee 3 before becoming inactive)
INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay) VALUES
    (3, DATE '2026-09-01', 8000.00, 7200.00);

CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');
-- Rerun October to verify existing payroll rows remain unchanged
CALL pr_process_payroll(DATE '2026-10-01');

-- Test salary change audit (and verify non-salary update produces no audit entry)
UPDATE employees SET basic_salary = 10800.00 WHERE employee_id = 1;
UPDATE employees SET allowance = 2200.00 WHERE employee_id = 1;

SELECT * FROM salary_audit ORDER BY audit_id;

-- (e) View: v_payroll_report [5 marks]
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT
    e.full_name,
    p.pay_month,
    p.gross_pay,
    p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) Index & EXPLAIN [5 marks]
-- Justification: The unique constraint uq_payroll_employee_month leads with
-- (employee_id, pay_month), so filtering solely by pay_month across all
-- employees cannot use its leading column efficiently. A dedicated index on
-- pay_month supports full monthly payroll reports directly.
CREATE INDEX idx_payroll_pay_month
ON payroll (pay_month);

EXPLAIN ANALYZE
SELECT payroll_id, employee_id, pay_month, gross_pay, net_pay
FROM payroll
WHERE pay_month = DATE '2026-10-01';

-- (g) Scheduled job & inspection queries [6 marks]
-- Schedule at 02:00 on the 1st of each month for the 1st day of previous month (requires pg_cron)
-- SELECT cron.schedule(
--     'monthly_payroll_processing',
--     '0 2 1 * *',
--     $$CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::DATE);$$
-- );

-- Inspect scheduled job and run history in pg_cron:
-- SELECT jobid, jobname, schedule, command, active
-- FROM cron.job
-- WHERE jobname = 'monthly_payroll_processing';
--
-- SELECT runid, jobid, status, return_message, start_time, end_time
-- FROM cron.job_run_details
-- WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'monthly_payroll_processing')
-- ORDER BY start_time DESC;