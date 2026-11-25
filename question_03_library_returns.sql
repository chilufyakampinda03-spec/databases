-- ============================================================================
-- ICT371 Advanced Database — Question 3: Library Returns and Overdue Fines
-- ============================================================================

-- (a) Database and seed data [6 marks]
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(120) NOT NULL,
    borrowed_on   DATE NOT NULL,
    due_on        DATE NOT NULL CHECK (due_on >= borrowed_on),
    returned_on   DATE NULL CHECK (returned_on IS NULL OR returned_on >= borrowed_on),
    fine_amount   NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (fine_amount >= 0)
);

CREATE TABLE loan_audit (
    audit_id        SERIAL PRIMARY KEY,
    loan_id         INTEGER NOT NULL REFERENCES loans(loan_id),
    old_returned_on DATE NULL,
    new_returned_on DATE NULL,
    changed_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER NOT NULL DEFAULT 0 CHECK (overdue_count >= 0),
    total_fine    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_fine >= 0)
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Designing Data-Intensive Applications'),
    ('PostgreSQL: Up and Running');

-- (b) Function: fn_loan_fine(p_loan_id, p_as_of) [6 marks]
CREATE OR REPLACE FUNCTION fn_loan_fine(
    p_loan_id INT,
    p_as_of   DATE DEFAULT CURRENT_DATE
)
RETURNS NUMERIC(10, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_due_on        DATE;
    v_returned_on   DATE;
    v_effective_end DATE;
    v_overdue_days  INT;
BEGIN
    SELECT due_on, returned_on
    INTO v_due_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    v_effective_end := COALESCE(p_as_of, CURRENT_DATE);

    IF v_returned_on IS NOT NULL AND v_returned_on < v_effective_end THEN
        v_effective_end := v_returned_on;
    END IF;

    v_overdue_days := GREATEST(0, v_effective_end - v_due_on);

    RETURN ROUND(v_overdue_days * 2.00, 2);
END;
$$;

-- (d) Trigger: AFTER UPDATE row trigger on loans [8 marks]
CREATE OR REPLACE FUNCTION trg_audit_loan_return()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
    VALUES (NEW.loan_id, OLD.returned_on, NEW.returned_on, CURRENT_TIMESTAMP);
    RETURN NEW;
END;
$$;

CREATE TRIGGER after_loan_returned_on_update
AFTER UPDATE OF returned_on ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_audit_loan_return();

-- (c) Procedure: pr_return_loan(p_loan_id, p_returned_on) [8 marks]
CREATE OR REPLACE PROCEDURE pr_return_loan(
    p_loan_id     INT,
    p_returned_on DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed_on DATE;
    v_returned_on DATE;
    v_return_date DATE;
    v_final_fine  NUMERIC(10, 2);
BEGIN
    v_return_date := COALESCE(p_returned_on, CURRENT_DATE);

    SELECT borrowed_on, returned_on
    INTO v_borrowed_on, v_returned_on
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    IF v_returned_on IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % has already been returned on %.', p_loan_id, v_returned_on;
    END IF;

    IF v_return_date < v_borrowed_on THEN
        RAISE EXCEPTION 'Return date (%) cannot be before borrowed_on (%).',
            v_return_date, v_borrowed_on;
    END IF;

    v_final_fine := fn_loan_fine(p_loan_id, v_return_date);

    UPDATE loans
    SET returned_on = v_return_date,
        fine_amount = v_final_fine
    WHERE loan_id = p_loan_id;
END;
$$;

-- Seed 6 loans (includes open overdue loans, on-time loans, and a returned loan)
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on, returned_on, fine_amount) VALUES
    (1, 'Mutale Banda',   CURRENT_DATE - 15, CURRENT_DATE - 5,  NULL, 0.00), -- Open overdue (5 days = K10)
    (2, 'Chanda Mwape',   CURRENT_DATE - 10, CURRENT_DATE - 2,  NULL, 0.00), -- Open overdue (2 days = K4)
    (3, 'Bwalya Phiri',   CURRENT_DATE - 5,  CURRENT_DATE + 3,  NULL, 0.00), -- On-time open loan
    (1, 'Thandiwe Zulu',  CURRENT_DATE - 3,  CURRENT_DATE,      NULL, 0.00), -- Due today (on-time)
    (2, 'Mwamba Lungu',   CURRENT_DATE - 12, CURRENT_DATE - 4,  NULL, 0.00), -- Will be returned via procedure
    (3, 'Kabwe Tembo',    CURRENT_DATE - 7,  CURRENT_DATE,      NULL, 0.00); -- Will be returned on time via procedure

-- Process returns through procedure to populate returned_on, fine_amount, and loan_audit
CALL pr_return_loan(5, CURRENT_DATE - 1);
CALL pr_return_loan(6, CURRENT_DATE);

SELECT * FROM loan_audit ORDER BY audit_id;

-- (e) View: v_overdue_loans [5 marks]
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT
    b.title AS book_title,
    l.borrower_name,
    l.due_on,
    fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans ORDER BY due_on;

-- (f) Index & EXPLAIN [5 marks]
-- Partial composite index covers unreturned loans filtered by book_id.
CREATE INDEX idx_loans_unreturned_book
ON loans (book_id, due_on)
WHERE returned_on IS NULL;

EXPLAIN ANALYZE
SELECT loan_id, book_id, borrower_name, borrowed_on, due_on
FROM loans
WHERE book_id = 1
  AND returned_on IS NULL;

-- (g) Scheduled job: pr_refresh_overdue(p_as_of) [6 marks]
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(
    p_as_of DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_target_date   DATE;
    v_overdue_count INT;
    v_total_fine    NUMERIC(12, 2);
BEGIN
    v_target_date := COALESCE(p_as_of, CURRENT_DATE);

    SELECT
        COUNT(*),
        COALESCE(SUM(fn_loan_fine(loan_id, v_target_date)), 0.00)
    INTO v_overdue_count, v_total_fine
    FROM loans
    WHERE (returned_on IS NULL OR returned_on > v_target_date)
      AND due_on < v_target_date;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    VALUES (v_target_date, v_overdue_count, v_total_fine)
    ON CONFLICT (snapshot_date)
    DO UPDATE SET
        overdue_count = EXCLUDED.overdue_count,
        total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT * FROM overdue_summary ORDER BY snapshot_date DESC;

-- Schedule daily at 00:10 for CURRENT_DATE (requires pg_cron)
-- SELECT cron.schedule(
--     'refresh_library_overdue_summary',
--     '10 0 * * *',
--     $$CALL pr_refresh_overdue(CURRENT_DATE);$$
-- );