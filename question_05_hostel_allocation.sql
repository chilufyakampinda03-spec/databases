-- ============================================================================
-- ICT371 Advanced Database — Question 5: Hostel Room Allocation
-- ============================================================================

-- (a) Database and seed data [6 marks]
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(20) NOT NULL UNIQUE,
    capacity    INTEGER NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER NOT NULL REFERENCES students(student_id),
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE NOT NULL,
    released_on   DATE NULL,
    status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT chk_allocation_status_dates CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
        OR (status = 'ENDED' AND released_on IS NOT NULL AND released_on >= allocated_on)
    )
);

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL CHECK (occupied_beds >= 0),
    free_beds     INTEGER NOT NULL CHECK (free_beds >= 0),
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
    ('STU-2026-101', 'Bupe Katongo'),
    ('STU-2026-102', 'Sibusiso Ndlovu'),
    ('STU-2026-103', 'Misozi Sichone'),
    ('STU-2026-104', 'Mwila Chilufya'),
    ('STU-2026-105', 'Taonga Banda');

-- Room 1 (cap 2 -> full), Room 2 (cap 3 -> partly occupied), Room 3 (cap 2 -> empty)
INSERT INTO rooms (room_number, capacity) VALUES
    ('H1-101', 2),
    ('H1-102', 3),
    ('H1-103', 2);

-- (b) Function: fn_free_beds(p_room_id) [6 marks]
CREATE OR REPLACE FUNCTION fn_free_beds(
    p_room_id INT
)
RETURNS INT
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity     INT;
    v_active_count INT;
BEGIN
    SELECT capacity
    INTO v_capacity
    FROM rooms
    WHERE room_id = p_room_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*)
    INTO v_active_count
    FROM allocations
    WHERE room_id = p_room_id
      AND status = 'ACTIVE';

    RETURN v_capacity - v_active_count;
END;
$$;

-- (d) Trigger: BEFORE INSERT OR UPDATE row trigger on allocations [8 marks]
CREATE OR REPLACE FUNCTION trg_validate_allocation()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity     INT;
    v_active_in_rm INT;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        -- Lock room row to serialize concurrent capacity checks
        SELECT capacity
        INTO v_capacity
        FROM rooms
        WHERE room_id = NEW.room_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
        END IF;

        -- Enforce one ACTIVE allocation per student
        IF EXISTS (
            SELECT 1
            FROM allocations a
            WHERE a.student_id = NEW.student_id
              AND a.status = 'ACTIVE'
              AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id)
        ) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE hostel allocation.', NEW.student_id;
        END IF;

        -- Enforce room capacity excluding current row on UPDATE
        SELECT COUNT(*)
        INTO v_active_in_rm
        FROM allocations a
        WHERE a.room_id = NEW.room_id
          AND a.status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id);

        IF v_active_in_rm >= v_capacity THEN
            RAISE EXCEPTION 'Room % is at full capacity (% beds).', NEW.room_id, v_capacity;
        END IF;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER before_allocation_validate
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_validate_allocation();

-- (c) Procedure: pr_allocate_room(p_student_id, p_room_id, p_allocated_on) [8 marks]
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INT,
    p_room_id      INT,
    p_allocated_on DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM 1 FROM students WHERE student_id = p_student_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    PERFORM 1 FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM allocations
        WHERE student_id = p_student_id
          AND status = 'ACTIVE'
    ) THEN
        RAISE EXCEPTION 'Student % already holds an ACTIVE room allocation.', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'No free beds available in room_id %.', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, COALESCE(p_allocated_on, CURRENT_DATE), NULL, 'ACTIVE');
END;
$$;

-- Historical ENDED allocation (does not occupy a bed)
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
VALUES (5, 3, CURRENT_DATE - 30, CURRENT_DATE - 5, 'ENDED');

-- Active allocations: Room 1 full (2/2), Room 2 partly occupied (1/3), Room 3 empty (0/2)
CALL pr_allocate_room(1, 1, CURRENT_DATE - 10);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 8);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 4);

-- (e) View: v_room_occupancy [5 marks]
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT
    r.room_number,
    r.capacity,
    COUNT(a.allocation_id) AS occupied_beds,
    r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
    ON a.room_id = r.room_id
   AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_number;

-- (f) Index & EXPLAIN [5 marks]
-- Justification: A partial index on room_id WHERE status = 'ACTIVE' indexes
-- only active bed assignments, keeping the index compact and fast for room
-- occupancy lookups while ignoring historical ENDED rows.
CREATE INDEX idx_allocations_active_room
ON allocations (room_id)
WHERE status = 'ACTIVE';

EXPLAIN ANALYZE
SELECT allocation_id, student_id, room_id, allocated_on
FROM allocations
WHERE room_id = 1
  AND status = 'ACTIVE';

-- (g) Scheduled job: pr_refresh_occupancy() [6 marks]
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT
        CURRENT_DATE,
        r.room_id,
        COUNT(a.allocation_id) AS occupied_beds,
        r.capacity - COUNT(a.allocation_id) AS free_beds
    FROM rooms r
    LEFT JOIN allocations a
        ON a.room_id = r.room_id
       AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id)
    DO UPDATE SET
        occupied_beds = EXCLUDED.occupied_beds,
        free_beds     = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();
SELECT * FROM occupancy_snapshot ORDER BY snapshot_date DESC, room_id;

-- Schedule daily at 23:55 (requires pg_cron)
-- SELECT cron.schedule(
--     'refresh_hostel_daily_occupancy',
--     '55 23 * * *',
--     $$CALL pr_refresh_occupancy();$$
-- );