CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL,
    fee_due        NUMERIC(12, 2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    logged_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER NOT NULL DEFAULT 0 CHECK (payment_count >= 0),
    total_amount    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0)
);

INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('STU-2026-001', 'Mutale Banda',  5000.00),
    ('STU-2026-002', 'Chanda Mwape',  8000.00),
    ('STU-2026-003', 'Bwalya Phiri',  6500.00);

CREATE OR REPLACE FUNCTION fn_fee_balance(
    p_student_id INT
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due    NUMERIC(12, 2);
    v_paid_total NUMERIC(12, 2);
BEGIN
    SELECT fee_due
    INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0.00)
    INTO v_paid_total
    FROM payments
    WHERE student_id = p_student_id;

    RETURN ROUND(v_fee_due - v_paid_total, 2);
END;
$$;

CREATE OR REPLACE FUNCTION trg_audit_payment_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER after_payment_insert_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_audit_payment_insert();

CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INT,
    p_amount     NUMERIC(12, 2),
    p_paid_on    DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12, 2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount (%) must be positive and non-NULL.', p_amount;
    END IF;

    PERFORM 1
    FROM students
    WHERE student_id = p_student_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment (%) exceeds outstanding balance (%) for student_id %.',
            p_amount, v_balance, p_student_id;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, COALESCE(p_paid_on, CURRENT_DATE));
END;
$$;

CALL pr_receive_payment(1, 2000.00, DATE '2026-11-24');
CALL pr_receive_payment(1, 1500.00, DATE '2026-11-24');
CALL pr_receive_payment(1, 1500.00, DATE '2026-11-24');
CALL pr_receive_payment(2, 2500.00, DATE '2026-11-24');
CALL pr_receive_payment(2, 1500.00, DATE '2026-11-24');
CALL pr_receive_payment(2, 1000.00, DATE '2026-11-24');

SELECT * FROM payment_audit ORDER BY audit_id;

CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    fn_fee_balance(s.student_id) AS outstanding_balance
FROM students s
WHERE fn_fee_balance(s.student_id) > 0;

SELECT * FROM v_fee_balances ORDER BY student_number;

CREATE INDEX idx_payments_student_paid_on
ON payments (student_id, paid_on);

EXPLAIN ANALYZE
SELECT payment_id, student_id, amount, paid_on
FROM payments
WHERE student_id = 2
  AND paid_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';

CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_payment_count INT;
    v_total_amount  NUMERIC(12, 2);
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Collection date p_day cannot be NULL.';
    END IF;

    SELECT
        COUNT(*),
        COALESCE(SUM(amount), 0.00)
    INTO v_payment_count, v_total_amount
    FROM payments
    WHERE paid_on = p_day;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    VALUES (p_day, v_payment_count, v_total_amount)
    ON CONFLICT (collection_date)
    DO UPDATE SET
        payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);
SELECT * FROM daily_collections ORDER BY collection_date DESC;

-- SELECT cron.schedule(
--     'refresh_university_daily_collections',
--     '0 1 * * *',
--     $$CALL pr_refresh_collections(CURRENT_DATE - 1);$$
-- );