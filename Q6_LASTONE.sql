-- ==========================================
-- ICT371 QUESTION 6: Monthly Payroll Processing
-- ==========================================

-- Clean up existing tables
DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- ---------------------------------------------------------
-- (a) Database and seed data [6 marks]
-- ---------------------------------------------------------
CREATE TABLE employees (
  employee_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  full_name    VARCHAR(100) NOT NULL,
  basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
  deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
  active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
  payroll_id  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  pay_month   DATE NOT NULL,
  gross_pay   NUMERIC(12,2) NOT NULL,
  net_pay     NUMERIC(12,2) NOT NULL,
  UNIQUE (employee_id, pay_month),
  -- Store pay_month as the first date of a month
  CONSTRAINT chk_month_start CHECK (pay_month = DATE_TRUNC('month', pay_month)::date)
);

CREATE TABLE salary_audit (
  audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  old_salary  NUMERIC(12,2) NOT NULL,
  new_salary  NUMERIC(12,2) NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------
-- (b) Function [6 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT) RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE v_net NUMERIC;
BEGIN
  SELECT basic_salary + allowance - deduction INTO v_net
  FROM employees WHERE employee_id = p_employee_id;
  
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown employee %', p_employee_id; END IF;
  IF v_net < 0 THEN RAISE EXCEPTION 'Computed net pay negative for employee %', p_employee_id; END IF;
  
  RETURN v_net;
END $$;

-- ---------------------------------------------------------
-- (c) Procedure [8 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE) LANGUAGE plpgsql AS $$
DECLARE 
  r RECORD; 
  v_gross NUMERIC; 
  v_net NUMERIC;
BEGIN
  -- Require month-start date
  IF p_month IS NULL OR p_month <> DATE_TRUNC('month', p_month)::date THEN
    RAISE EXCEPTION 'Month must be first day of month';
  END IF;
  
  -- Query FOR loop over active employees
  FOR r IN SELECT employee_id, basic_salary, allowance, deduction
           FROM employees WHERE active ORDER BY employee_id LOOP
           
    v_gross := r.basic_salary + r.allowance;
    v_net   := v_gross - r.deduction;
    
    -- Invalid employee calculation fails the whole call (transaction rolls back)
    IF v_net < 0 THEN 
      RAISE EXCEPTION 'Negative net pay computed for employee %', r.employee_id; 
    END IF;
    
    -- Insert each missing employee/month payroll row; leave existing row unchanged
    INSERT INTO payroll(employee_id, pay_month, gross_pay, net_pay)
    VALUES (r.employee_id, p_month, v_gross, v_net)
    ON CONFLICT (employee_id, pay_month) DO NOTHING; 
  END LOOP;
END $$;

-- ---------------------------------------------------------
-- (d) Trigger [8 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_salary_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO salary_audit(employee_id, old_salary, new_salary)
  VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary);
  RETURN NEW;
END $$;

-- Logs actual basic_salary change only
CREATE TRIGGER trg_employees_salary_audit 
AFTER UPDATE ON employees
FOR EACH ROW WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_salary_audit();

-- ---------------------------------------------------------
-- (e) View [5 marks]
-- ---------------------------------------------------------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p 
JOIN employees e USING (employee_id);

-- ---------------------------------------------------------
-- (f) Index [5 marks]
-- ---------------------------------------------------------
-- Avoids duplicating the existing UNIQUE(employee_id, pay_month) index.
-- This one optimizes filtering by pay_month across ALL employees.
CREATE INDEX idx_payroll_month ON payroll(pay_month);
-- EXPLAIN SELECT * FROM payroll WHERE pay_month = '2025-01-01';

-- ---------------------------------------------------------
-- (g) Scheduled job [6 marks]
-- ---------------------------------------------------------
-- Scheduled to run at 02:00 on the first day of each month, passing previous month.
-- SELECT cron.schedule('payroll-monthly','0 2 1 * *',
--   $$CALL pr_process_payroll((DATE_TRUNC('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- Inspect job and history:
-- SELECT * FROM cron.job;
-- SELECT * FROM cron.job_run_details ORDER BY start_time DESC LIMIT 10;

-- ==========================================
-- SEED DATA & TESTING
-- ==========================================

-- 1. Insert employees (2 active, 1 inactive)
INSERT INTO employees(full_name, basic_salary, allowance, deduction, active) VALUES
 ('Alice', 4000, 500, 300, TRUE),
 ('Bob',   3500, 400, 250, TRUE),
 ('Cara',  5000, 700, 400, FALSE);

-- 2. Process two months
CALL pr_process_payroll('2025-01-01');
CALL pr_process_payroll('2025-02-01');

-- 3. Rerun Feb payroll (Should not duplicate or change existing rows)
CALL pr_process_payroll('2025-02-01');

-- 4. Update Alice's salary to test trigger
UPDATE employees SET basic_salary = 4500 WHERE employee_id = 1;
-- Update Bob's allowance (Trigger should NOT fire because basic_salary didn't change)
UPDATE employees SET allowance = 600 WHERE employee_id = 2;

-- 5. Check the views and audit log
SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;
SELECT * FROM salary_audit;