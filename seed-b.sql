CREATE TABLE orders (
  id SERIAL PRIMARY KEY,
  customer TEXT,
  amount NUMERIC,
  tenant_label TEXT
);

INSERT INTO orders (customer, amount, tenant_label) VALUES
  ('Dave',  300.00, '=== TENANT B ==='),
  ('Eve',   400.00, '=== TENANT B ==='),
  ('Frank', 250.00, '=== TENANT B ===');
