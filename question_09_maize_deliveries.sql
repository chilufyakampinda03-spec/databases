-- ============================================================================
-- ICT371 Advanced Database — Question 9: Farmer Cooperative Maize Deliveries
-- ============================================================================

-- (a) Database and seed data [6 marks]
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(30) NOT NULL UNIQUE,
    full_name     VARCHAR(120) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10, 2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10, 2) NOT NULL CHECK (unit_rate > 0),
    total_value  NUMERIC(12, 2) NOT NULL CHECK (total_value > 0),
    delivered_on DATE NOT NULL DEFAULT CURRENT_DATE,
    is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_weight >= 0),
    total_value   NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_value >= 0)
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('FRM-2026-001', 'Mutale Banda'),
    ('FRM-2026-002', 'Chanda Mwape'),
    ('FRM-2026-003', 'Bwalya Phiri');

-- (b) Function: fn_maize_rate(p_grade) [6 marks]
CREATE OR REPLACE FUNCTION fn_maize_rate(
    p_grade VARCHAR
)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade cannot be NULL.';
    END IF;

    CASE UPPER(TRIM(p_grade))
        WHEN 'A' THEN RETURN 5.00;
        WHEN 'B' THEN RETURN 4.00;
        WHEN 'C' THEN RETURN 3.00;
        ELSE
            RAISE EXCEPTION 'Unsupported maize grade (%): allowed grades are A, B, or C.', p_grade;
    END CASE;
END;
$$;

-- (d) Trigger: BEFORE INSERT OR UPDATE row trigger on deliveries [8 marks]
CREATE OR REPLACE FUNCTION trg_calculate_delivery_value()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Delivery weight (%) must be greater than zero.', NEW.weight_kg;
    END IF;

    NEW.grade       := UPPER(TRIM(NEW.grade));
    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);

    RETURN NEW;
END;
$$;

CREATE TRIGGER before_delivery_price_calc
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_calculate_delivery_value();

-- (c) Procedure: pr_receive_delivery(p_farmer_id, p_grade, p_weight, p_date) [8 marks]
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INT,
    p_grade     VARCHAR,
    p_weight    NUMERIC,
    p_date      DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1
    FROM farmers
    WHERE farmer_id = p_farmer_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;

    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Invalid weight (%): weight must be positive.', p_weight;
    END IF;

    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date p_date cannot be NULL.';
    END IF;

    -- Insert basic delivery fields; trigger supplies unit_rate and total_value
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- Load 6 deliveries covering all grades (A, B, C) and both payment states
-- Farmer 3's deliveries will be marked paid so Farmer 3 tests the zero-due case in the view
CALL pr_receive_delivery(1, 'A', 120.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(1, 'B',  80.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'C', 150.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(2, 'A',  60.00, CURRENT_DATE);
CALL pr_receive_delivery(3, 'B', 100.00, CURRENT_DATE - 1);
CALL pr_receive_delivery(3, 'C',  50.00, CURRENT_DATE);

-- Mark selected deliveries as paid (both payment states represented)
UPDATE deliveries SET is_paid = TRUE WHERE delivery_id IN (2, 5, 6);

-- (e) View: v_farmer_amount_due [5 marks]
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT
    f.farmer_number,
    f.full_name,
    COALESCE(SUM(d.total_value), 0.00) AS total_unpaid_value
FROM farmers f
LEFT JOIN deliveries d
    ON d.farmer_id = f.farmer_id
   AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;

-- (f) Index & EXPLAIN [5 marks]
-- Justification: A composite index on (farmer_id, delivered_on) filters by a
-- specific farmer first and then range-scans delivered_on directly between
-- the two dates without scanning other farmers' deliveries.
CREATE INDEX idx_deliveries_farmer_delivered_on
ON deliveries (farmer_id, delivered_on);

EXPLAIN ANALYZE
SELECT delivery_id, farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid
FROM deliveries
WHERE farmer_id = 1
  AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled job: pr_refresh_purchases(p_day) [6 marks]
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_weight NUMERIC(12, 2);
    v_total_value  NUMERIC(12, 2);
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Purchase date p_day cannot be NULL.';
    END IF;

    SELECT
        COALESCE(SUM(weight_kg), 0.00),
        COALESCE(SUM(total_value), 0.00)
    INTO v_total_weight, v_total_value
    FROM deliveries
    WHERE delivered_on = p_day;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    VALUES (p_day, v_total_weight, v_total_value)
    ON CONFLICT (purchase_date)
    DO UPDATE SET
        total_weight = EXCLUDED.total_weight,
        total_value  = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);
SELECT * FROM daily_purchases ORDER BY purchase_date DESC;

-- Schedule daily at 01:30 for the previous day (requires pg_cron)
-- SELECT cron.schedule(
--     'refresh_maize_daily_purchases',
--     '30 1 * * *',
--     $$CALL pr_refresh_purchases(CURRENT_DATE - 1);$$
-- );