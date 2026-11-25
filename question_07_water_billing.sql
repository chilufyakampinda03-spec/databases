-- ============================================================================
-- ICT371 Advanced Database — Question 7: Water Meter Readings and Billing
-- ============================================================================

-- (a) Database and seed data [6 marks]
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(120) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
    previous_reading NUMERIC(12, 2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(12, 2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT uq_readings_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12, 2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (amount_paid >= 0 AND amount_paid <= charge),
    due_on      DATE NOT NULL
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_due >= 0)
);

INSERT INTO customers (full_name) VALUES
    ('Bupe Katongo'),
    ('Sibusiso Ndlovu'),
    ('Misozi Sichone');

-- (b) Function: fn_water_charge(p_units) [6 marks]
CREATE OR REPLACE FUNCTION fn_water_charge(
    p_units NUMERIC
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_charge NUMERIC(12, 2);
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Consumption units (%) cannot be NULL or negative.', p_units;
    END IF;

    IF p_units = 0 THEN
        v_charge := 0.00;
    ELSIF p_units <= 10 THEN
        v_charge := p_units * 5.00;
    ELSE
        v_charge := (10 * 5.00) + ((p_units - 10) * 8.00);
    END IF;

    RETURN ROUND(v_charge, 2);
END;
$$;

-- (d) Trigger: BEFORE INSERT OR UPDATE trigger on readings [8 marks]
CREATE OR REPLACE FUNCTION trg_validate_meter_reading()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'Invalid reading: current_reading (%) cannot be less than previous_reading (%).',
            NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER before_reading_validate
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_validate_meter_reading();

-- (c) Procedure: pr_generate_bill(p_reading_id, p_due_on) [8 marks]
CREATE OR REPLACE PROCEDURE pr_generate_bill(
    p_reading_id INT,
    p_due_on     DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev   NUMERIC(12, 2);
    v_curr   NUMERIC(12, 2);
    v_units  NUMERIC(12, 2);
    v_charge NUMERIC(12, 2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date p_due_on cannot be NULL.';
    END IF;

    SELECT previous_reading, current_reading
    INTO v_prev, v_curr
    FROM readings
    WHERE reading_id = p_reading_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'A bill already exists for reading_id %.', p_reading_id;
    END IF;

    v_units  := v_curr - v_prev;
    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0.00, p_due_on);
END;
$$;

-- Seed 6 readings covering zero, exactly 10, and above 10 units
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, DATE '2026-09-01', 100.00, 100.00), -- 0 units -> K0.00
    (1, DATE '2026-10-01', 100.00, 110.00), -- 10 units -> K50.00
    (2, DATE '2026-09-01', 200.00, 215.00), -- 15 units -> K50 + K40 = K90.00
    (2, DATE '2026-10-01', 215.00, 225.00), -- 10 units -> K50.00
    (3, DATE '2026-09-01',  50.00,  70.00), -- 20 units -> K50 + K80 = K130.00
    (3, DATE '2026-10-01',  70.00,  70.00); -- 0 units -> K0.00

CALL pr_generate_bill(1, CURRENT_DATE - 20);
CALL pr_generate_bill(2, CURRENT_DATE - 5);
CALL pr_generate_bill(3, CURRENT_DATE - 15);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(5, CURRENT_DATE - 3);
CALL pr_generate_bill(6, CURRENT_DATE + 15);

-- Record a partial payment on bill 3 (charge K90, paid K40 -> K50 overdue)
UPDATE bills SET amount_paid = 40.00 WHERE bill_id = 3;

-- (e) View: v_overdue_bills [5 marks]
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT
    c.full_name AS customer_name,
    b.due_on,
    (b.charge - b.amount_paid) AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills ORDER BY due_on;

-- (f) Index & EXPLAIN [5 marks]
-- Justification: A partial index on due_on WHERE amount_paid < charge indexes
-- only unpaid/partially paid bills, allowing date-range scans for overdue
-- receivables without scanning settled bills.
CREATE INDEX idx_bills_unpaid_due_on
ON bills (due_on)
WHERE amount_paid < charge;

EXPLAIN ANALYZE
SELECT bill_id, reading_id, charge, amount_paid, due_on
FROM bills
WHERE due_on < CURRENT_DATE
  AND amount_paid < charge;

-- (g) Scheduled job: pr_refresh_receivables() [6 marks]
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_due NUMERIC(12, 2);
BEGIN
    SELECT COALESCE(SUM(charge - amount_paid), 0.00)
    INTO v_total_due
    FROM bills
    WHERE amount_paid < charge;

    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    VALUES (CURRENT_DATE, v_total_due)
    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        total_due = EXCLUDED.total_due;
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();
SELECT * FROM receivable_snapshot ORDER BY snapshot_date DESC;

-- Schedule daily at 00:30 (requires pg_cron)
-- SELECT cron.schedule(
--     'refresh_water_receivables',
--     '30 0 * * *',
--     $$CALL pr_refresh_receivables();$$
-- );