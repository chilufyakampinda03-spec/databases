-- ============================================================================
-- ICT371 Advanced Database — Question 1: Pharmacy Stock and Daily Sales
-- ============================================================================

-- (a) Database Tables and Seed Medicines
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(120) NOT NULL,
    unit_price    NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10, 2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER NOT NULL CHECK (old_qty >= 0),
    new_qty     INTEGER NOT NULL CHECK (new_qty >= 0),
    changed_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER NOT NULL DEFAULT 0 CHECK (total_qty >= 0),
    total_amount NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0)
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Amoxicillin 500mg', 25.00, 100),
    ('Paracetamol 500mg', 10.00, 50),
    ('Ibuprofen 400mg',   15.00, 18);

-- (b) Function: fn_sale_value(p_medicine_id, p_quantity)
CREATE OR REPLACE FUNCTION fn_sale_value(
    p_medicine_id INT,
    p_quantity    INT
)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_unit_price NUMERIC(10, 2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity (%): quantity must be greater than zero.', p_quantity;
    END IF;

    SELECT unit_price
    INTO v_unit_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN ROUND(v_unit_price * p_quantity, 2);
END;
$$;

-- (d) Trigger: AFTER UPDATE row trigger on medicines
CREATE OR REPLACE FUNCTION trg_audit_medicine_stock()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
    VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER after_medicine_stock_update
AFTER UPDATE OF stock_qty ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_audit_medicine_stock();

-- (c) Procedure: pr_record_sale(p_medicine_id, p_quantity, p_sold_on)
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INT,
    p_quantity    INT,
    p_sold_on     DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_value NUMERIC(12, 2);
    v_unit_price  NUMERIC(10, 2);
    v_stock_qty   INT;
BEGIN
    v_total_value := fn_sale_value(p_medicine_id, p_quantity);

    SELECT unit_price, stock_qty
    INTO v_unit_price, v_stock_qty
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF v_stock_qty < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine_id % (available: %, requested: %).',
            p_medicine_id, v_stock_qty, p_quantity;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_unit_price, COALESCE(p_sold_on, CURRENT_DATE));

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- Load 6 valid sales through the completed procedure (completes part a)
CALL pr_record_sale(1, 10, DATE '2026-11-24');
CALL pr_record_sale(2, 15, DATE '2026-11-24');
CALL pr_record_sale(3, 10, DATE '2026-11-24');
CALL pr_record_sale(1, 5,  DATE '2026-11-24');
CALL pr_record_sale(2, 27, DATE '2026-11-24');
CALL pr_record_sale(3, 2,  DATE '2026-11-24');

SELECT * FROM stock_audit ORDER BY audit_id;

-- (e) View: v_low_stock
CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    medicine_name,
    unit_price,
    stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

SELECT * FROM v_low_stock;

-- (f) Index & EXPLAIN Plan
-- Justification: A composite index on (medicine_id, sold_on) filters by exact
-- medicine_id first and narrows the date range on sold_on without scanning
-- unrelated medicines or dates.
CREATE INDEX idx_sales_medicine_sold_on
ON sales (medicine_id, sold_on);

EXPLAIN ANALYZE
SELECT sale_id, medicine_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN DATE '2026-11-01' AND DATE '2026-11-30';

-- (g) Procedure: pr_refresh_sales(p_day) & Rerunnable Refresh Test
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_total_qty    INT;
    v_total_amount NUMERIC(12, 2);
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Target date p_day cannot be NULL.';
    END IF;

    SELECT
        COALESCE(SUM(quantity), 0),
        COALESCE(SUM(quantity * unit_price), 0.00)
    INTO v_total_qty, v_total_amount
    FROM sales
    WHERE sold_on = p_day;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    VALUES (p_day, v_total_qty, v_total_amount)
    ON CONFLICT (sales_date)
    DO UPDATE SET
        total_qty    = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

-- Simulate daily 00:15 run for previous day and test rerunning without duplicates
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales ORDER BY sales_date DESC;