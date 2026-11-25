-- ============================================================================
-- ICT371 Advanced Database — Question 8: Transport Fleet Maintenance
-- ============================================================================

-- (a) Database and seed data [6 marks]
CREATE TABLE vehicles (
    vehicle_id            SERIAL PRIMARY KEY,
    registration          VARCHAR(30) NOT NULL UNIQUE,
    current_odometer      NUMERIC(12, 1) NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer NUMERIC(12, 1) NOT NULL CHECK (
        last_service_odometer >= 0
        AND last_service_odometer <= current_odometer
    )
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE NOT NULL,
    start_odometer NUMERIC(12, 1) NOT NULL CHECK (start_odometer >= 0),
    end_odometer   NUMERIC(12, 1) NOT NULL CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service NUMERIC(12, 1) NOT NULL CHECK (km_since_service >= 5000),
    flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

-- Three vehicles with different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('BAA-1024', 14500.0, 10000.0), -- 4,500 km since service (will cross 5,000 after trips)
    ('BCH-4510', 25200.0, 20000.0), -- 5,200 km since service (already due)
    ('BLZ-7890',  8100.0,  7500.0); -- 600 km since service (well below 5,000)

-- (b) Function: fn_service_due(p_vehicle_id) [6 marks]
CREATE OR REPLACE FUNCTION fn_service_due(
    p_vehicle_id INT
)
RETURNS BOOLEAN
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr NUMERIC(12, 1);
    v_last NUMERIC(12, 1);
BEGIN
    SELECT current_odometer, last_service_odometer
    INTO v_curr, v_last
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_curr - v_last) >= 5000;
END;
$$;

-- (d) Trigger: BEFORE INSERT row trigger on trips [8 marks]
CREATE OR REPLACE FUNCTION trg_validate_and_update_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_curr_odo NUMERIC(12, 1);
BEGIN
    IF NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: end_odometer (%) must exceed start_odometer (%).',
            NEW.end_odometer, NEW.start_odometer;
    END IF;

    SELECT current_odometer
    INTO v_curr_odo
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;

    IF NEW.start_odometer <> v_curr_odo THEN
        RAISE EXCEPTION 'Start odometer (%) does not match vehicle % current odometer (%).',
            NEW.start_odometer, NEW.vehicle_id, v_curr_odo;
    END IF;

    UPDATE vehicles
    SET current_odometer = NEW.end_odometer
    WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER before_trip_insert_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_validate_and_update_odometer();

-- (c) Procedure: pr_record_trip(p_vehicle_id, p_trip_on, p_start, p_end) [8 marks]
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INT,
    p_trip_on    DATE,
    p_start      NUMERIC,
    p_end        NUMERIC
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    IF p_trip_on IS NULL THEN
        RAISE EXCEPTION 'Trip date p_trip_on cannot be NULL.';
    END IF;

    IF p_start IS NULL OR p_end IS NULL OR p_end <= p_start THEN
        RAISE EXCEPTION 'Invalid odometer values: end (%) must be greater than start (%).',
            p_end, p_start;
    END IF;

    -- Insert trip only; trigger validates start_odometer and updates current_odometer
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- Seed 6 trips through the procedure after the trigger is installed
CALL pr_record_trip(1, CURRENT_DATE - 3, 14500.0, 14850.0);
CALL pr_record_trip(1, CURRENT_DATE - 1, 14850.0, 15250.0); -- Vehicle 1 now at 5,250 km since service
CALL pr_record_trip(2, CURRENT_DATE - 2, 25200.0, 25500.0);
CALL pr_record_trip(2, CURRENT_DATE,     25500.0, 25800.0);
CALL pr_record_trip(3, CURRENT_DATE - 2,  8100.0,  8450.0);
CALL pr_record_trip(3, CURRENT_DATE,      8450.0,  8900.0); -- Vehicle 3 at 1,400 km since service

-- (e) View: v_service_due [5 marks]
CREATE OR REPLACE VIEW v_service_due AS
SELECT
    registration,
    (current_odometer - last_service_odometer) AS km_since_service
FROM vehicles
WHERE fn_service_due(vehicle_id) = TRUE;

SELECT * FROM v_service_due ORDER BY registration;

-- (f) Index & EXPLAIN [5 marks]
-- Justification: A composite index on (vehicle_id, trip_on) locates all trips
-- for the specified vehicle first and then scans only the requested trip_on
-- date range.
CREATE INDEX idx_trips_vehicle_trip_on
ON trips (vehicle_id, trip_on);

EXPLAIN ANALYZE
SELECT trip_id, vehicle_id, trip_on, start_odometer, end_odometer
FROM trips
WHERE vehicle_id = 1
  AND trip_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;

-- (g) Scheduled job: pr_refresh_service_alerts() [6 marks]
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    -- Remove alerts for vehicles that are no longer due after servicing
    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1
        FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND fn_service_due(v.vehicle_id) = TRUE
    );

    -- Insert or update one alert for each due vehicle
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT
        v.vehicle_id,
        (v.current_odometer - v.last_service_odometer) AS km_since_service,
        CURRENT_DATE
    FROM vehicles v
    WHERE fn_service_due(v.vehicle_id) = TRUE
    ON CONFLICT (vehicle_id)
    DO UPDATE SET
        km_since_service = EXCLUDED.km_since_service,
        flagged_on       = EXCLUDED.flagged_on;
END;
$$;

CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;

-- Schedule every Monday at 06:00 (requires pg_cron)
-- SELECT cron.schedule(
--     'weekly_fleet_service_alerts',
--     '0 6 * * 1',
--     $$CALL pr_refresh_service_alerts();$$
-- );