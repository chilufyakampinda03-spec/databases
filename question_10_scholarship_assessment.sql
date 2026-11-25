-- ============================================================================
-- ICT371 Advanced Database — Question 10: Scholarship Application Assessment
-- ============================================================================

-- (a) Database and seed data [6 marks]
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL
);

CREATE TABLE applications (
    application_id     SERIAL PRIMARY KEY,
    student_id         INTEGER NOT NULL REFERENCES students(student_id),
    age_at_application INTEGER NOT NULL CHECK (age_at_application > 0),
    monthly_income     NUMERIC(12, 2) NOT NULL CHECK (monthly_income >= 0),
    average_mark       NUMERIC(5, 2) NOT NULL CHECK (average_mark >= 0 AND average_mark <= 100),
    submitted_on       DATE NOT NULL DEFAULT CURRENT_DATE,
    status             VARCHAR(15) NOT NULL DEFAULT 'PENDING'
                       CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(15) NOT NULL,
    new_status     VARCHAR(15) NOT NULL,
    changed_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO students (student_number, full_name) VALUES
    ('STU-2026-201', 'Lubuto Chanda'),
    ('STU-2026-202', 'Natasha Mulenga'),
    ('STU-2026-203', 'Kondwani Banda'),
    ('STU-2026-204', 'Thandiwe Zulu');

-- Six PENDING applications covering qualifying, non-qualifying, and boundary cases
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 20, 1800.00, 82.50, CURRENT_DATE - 5, 'PENDING'), -- Qualifying (APPROVED)
    (2, 18, 3000.00, 70.00, CURRENT_DATE - 4, 'PENDING'), -- Lower age + max income + min mark boundary (APPROVED)
    (3, 25, 2500.00, 75.00, CURRENT_DATE - 3, 'PENDING'), -- Upper age boundary (APPROVED)
    (4, 26, 2000.00, 85.00, CURRENT_DATE - 2, 'PENDING'), -- Fails age > 25 (REJECTED)
    (1, 21, 3001.00, 80.00, CURRENT_DATE - 1, 'PENDING'), -- Fails income > 3000 (REJECTED)
    (2, 22, 1500.00, 69.99, CURRENT_DATE,     'PENDING'); -- Fails mark < 70 (REJECTED)

-- (b) Function: fn_scholarship_eligible(p_age, p_income, p_mark) [6 marks]
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INT,
    p_income NUMERIC,
    p_mark   NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income, and mark inputs must not be NULL.';
    END IF;

    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Invalid age (%): age must be positive.', p_age;
    END IF;

    IF p_income < 0 THEN
        RAISE EXCEPTION 'Invalid monthly income (%): income cannot be negative.', p_income;
    END IF;

    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Invalid average mark (%): mark must be between 0 and 100.', p_mark;
    END IF;

    RETURN (p_age BETWEEN 18 AND 25)
       AND (p_income <= 3000.00)
       AND (p_mark >= 70.00);
END;
$$;

-- (d) Trigger: AFTER UPDATE row trigger on applications [8 marks]
CREATE OR REPLACE FUNCTION trg_audit_application_status()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (NEW.application_id, OLD.status, NEW.status, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER after_application_status_update
AFTER UPDATE OF status ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_audit_application_status();

-- (c) Procedure: pr_assess_application(p_application_id) [8 marks]
CREATE OR REPLACE PROCEDURE pr_assess_application(
    p_application_id INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age      INT;
    v_income   NUMERIC(12, 2);
    v_mark     NUMERIC(5, 2);
    v_status   VARCHAR(15);
    v_eligible BOOLEAN;
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
    INTO v_age, v_income, v_mark, v_status
    FROM applications
    WHERE application_id = p_application_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;

    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % has already been assessed (current status: %).',
            p_application_id, v_status;
    END IF;

    v_eligible := fn_scholarship_eligible(v_age, v_income, v_mark);

    UPDATE applications
    SET status = CASE WHEN v_eligible THEN 'APPROVED' ELSE 'REJECTED' END
    WHERE application_id = p_application_id;
END;
$$;

-- (g) Scheduled job: pr_assess_pending() [6 marks]
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    rec_app RECORD;
BEGIN
    FOR rec_app IN
        SELECT application_id
        FROM applications
        WHERE status = 'PENDING'
        ORDER BY application_id
    LOOP
        CALL pr_assess_application(rec_app.application_id);
    END LOOP;
END;
$$;

-- Run twice to verify all 6 PENDING applications are assessed once and reruns produce no duplicate audit entries
CALL pr_assess_pending();
CALL pr_assess_pending();

SELECT * FROM decision_audit ORDER BY audit_id;

-- Schedule every Monday at 08:00 (requires pg_cron)
-- SELECT cron.schedule(
--     'weekly_scholarship_assessment',
--     '0 8 * * 1',
--     $$CALL pr_assess_pending();$$
-- );

-- (e) View: v_approved_applicants [5 marks]
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT
    s.student_number,
    s.full_name,
    a.average_mark,
    a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

SELECT * FROM v_approved_applicants ORDER BY student_number;

-- (f) Index & EXPLAIN [5 marks]
-- Justification: A composite index on (status, submitted_on) filters by the
-- exact status first and then range-scans submitted_on directly inside that
-- status partition without scanning other statuses.
CREATE INDEX idx_applications_status_submitted_on
ON applications (status, submitted_on);

EXPLAIN ANALYZE
SELECT application_id, student_id, age_at_application, average_mark, submitted_on, status
FROM applications
WHERE status = 'APPROVED'
  AND submitted_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;