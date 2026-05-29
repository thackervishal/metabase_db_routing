CREATE TABLE orders (
  id SERIAL PRIMARY KEY,
  customer TEXT,
  amount NUMERIC,
  tenant_label TEXT
);

INSERT INTO orders (customer, amount, tenant_label) VALUES
  ('Alice', 100.00, '*** TENANT A ***'),
  ('Bob',   200.00, '*** TENANT A ***'),
  ('Carol', 150.00, '*** TENANT A ***');
