-- ============================================================================
-- ICT371 Advanced Database — Question 4: Clinic Appointment Scheduling
-- ============================================================================

-- (a) Database and seed data [6 marks]
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(120) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(120) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00')),
    status          VARCHAR(15) NOT NULL CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL DEFAULT 0 CHECK (booked_count >= 0),
    attended_count  INTEGER NOT NULL DEFAULT 0 CHECK (attended_count >= 0),
    cancelled_count INTEGER NOT NULL DEFAULT 0 CHECK (cancelled_count >= 0)
);

INSERT INTO patients (full_name) VALUES
    ('Lubuto Chanda'),
    ('Natasha Mulenga'),
    ('Kondwani Banda');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Mwewa Musonda'),
    ('Dr. Chisomo Phiri'),
    ('Dr. Tawanda Moyo');

-- (b) Function: fn_daily_load(p_doctor_id, p_day) [6 marks]
CREATE OR REPLACE FUNCTION fn_daily_load(
    p_doctor_id INT,
    p_day       DATE
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_load INT;
BEGIN
    PERFORM 1
    FROM doctors
    WHERE doctor_id = p_doctor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*)
    INTO v_load
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN COALESCE(v_load, 0);
END;
$$;

-- (d) Trigger: BEFORE INSERT OR UPDATE row trigger preventing slot clashes [8 marks]
CREATE OR REPLACE FUNCTION trg_prevent_slot_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1
            FROM appointments a
            WHERE a.doctor_id = NEW.doctor_id
              AND a.appointment_day = NEW.appointment_day
              AND a.slot_time = NEW.slot_time
              AND a.status <> 'CANCELLED'
              AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)
        ) THEN
            RAISE EXCEPTION 'Slot clash: doctor_id % already has a non-cancelled appointment on % at %.',
                NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER before_appointment_clash_check
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_prevent_slot_clash();

-- (c) Procedure: pr_book_appointment(p_patient_id, p_doctor_id, p_day, p_slot) [8 marks]
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INT,
    p_doctor_id  INT,
    p_day        DATE,
    p_slot       TIME
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment day (%) cannot be NULL or in the past.', p_day;
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot_time (%): allowed slots are 09:00, 10:00, 11:00, 12:00.', p_slot;
    END IF;

    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- Seed 6 appointments without violating the slot rule
CALL pr_book_appointment(1, 1, CURRENT_DATE, TIME '09:00');
CALL pr_book_appointment(2, 1, CURRENT_DATE, TIME '10:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE, TIME '09:00');
CALL pr_book_appointment(1, 2, CURRENT_DATE + 1, TIME '11:00');
CALL pr_book_appointment(2, 3, CURRENT_DATE + 1, TIME '12:00');
CALL pr_book_appointment(3, 1, CURRENT_DATE + 1, TIME '09:00');

-- Add past-day history rows to test daily summary for CURRENT_DATE - 1
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE - 1, TIME '09:00', 'ATTENDED'),
    (2, 1, CURRENT_DATE - 1, TIME '10:00', 'CANCELLED'),
    (3, 2, CURRENT_DATE - 1, TIME '11:00', 'BOOKED');

-- (e) View: v_today_appointments [5 marks]
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors d ON d.doctor_id = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time;

-- (f) Index & EXPLAIN [5 marks]
-- Justification: Non-unique composite B-tree index on (appointment_day, doctor_id)
-- allows multiple slots per doctor per day (and cancelled retries) while
-- locating all appointments for a given day and doctor directly.
CREATE INDEX idx_appointments_day_doctor
ON appointments (appointment_day, doctor_id);

EXPLAIN ANALYZE
SELECT appointment_id, patient_id, doctor_id, appointment_day, slot_time, status
FROM appointments
WHERE appointment_day = CURRENT_DATE
  AND doctor_id = 1;

-- (g) Scheduled job: pr_refresh_clinic_summary(p_day) [6 marks]
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_booked    INT;
    v_attended  INT;
    v_cancelled INT;
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'Target summary date p_day cannot be NULL.';
    END IF;

    SELECT
        COUNT(*) FILTER (WHERE status = 'BOOKED'),
        COUNT(*) FILTER (WHERE status = 'ATTENDED'),
        COUNT(*) FILTER (WHERE status = 'CANCELLED')
    INTO v_booked, v_attended, v_cancelled
    FROM appointments
    WHERE appointment_day = p_day;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    VALUES (p_day, COALESCE(v_booked, 0), COALESCE(v_attended, 0), COALESCE(v_cancelled, 0))
    ON CONFLICT (summary_date)
    DO UPDATE SET
        booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
SELECT * FROM clinic_summary ORDER BY summary_date DESC;

-- Schedule daily at 01:00 for the previous day (requires pg_cron)
-- SELECT cron.schedule(
--     'refresh_clinic_daily_summary',
--     '0 1 * * *',
--     $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);$$
-- );