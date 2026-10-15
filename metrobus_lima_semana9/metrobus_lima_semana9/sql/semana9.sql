-- =====================================================================
-- Semana 9 — MetroBus Lima: Tarifario, Pasarela de Pagos y Módulo Caja
-- Neon / PostgreSQL.  Caso 23: tabla recargas_tarjeta.
--
-- ANTES de este archivo debes haber ejecutado sql/semana7.sql.
-- Pega este archivo completo en Neon → SQL Editor y ejecútalo.
-- Se puede ejecutar más de una vez sin duplicar datos.
--
-- Regla de cobro (caso 23):
--   total = monto de la recarga + S/ 4.50 si pide tarjeta nueva
--   (con pase universitario la emisión cuesta 50 %: S/ 2.25).
-- =====================================================================

-- ---------------------------------------------------------------------
-- Paso 1. Rol "cajero" y DNI en usuarios
-- ---------------------------------------------------------------------
-- Se eliminan los CHECK anteriores sobre "rol" (sea cual sea su nombre) y se crea uno nuevo.
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.usuarios'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%rol%'
  LOOP
    EXECUTE format('ALTER TABLE usuarios DROP CONSTRAINT %I', r.conname);
  END LOOP;
END $$;

ALTER TABLE usuarios ADD CONSTRAINT usuarios_rol_check
  CHECK (rol IN ('cliente', 'administrador', 'empleado', 'cajero'));

-- El cajero busca al cliente por DNI
ALTER TABLE usuarios ADD COLUMN IF NOT EXISTS dni VARCHAR(8);

-- ---------------------------------------------------------------------
-- Paso 2. Columnas de cobro en recargas_tarjeta (+ columnas de la tarifa)
-- ---------------------------------------------------------------------
ALTER TABLE recargas_tarjeta
  ADD COLUMN IF NOT EXISTS monto_calculado NUMERIC(10,2) NOT NULL DEFAULT 0
      CHECK (monto_calculado >= 0),
  ADD COLUMN IF NOT EXISTS estado_pago VARCHAR(20) NOT NULL DEFAULT 'pendiente'
      CHECK (estado_pago IN ('pendiente', 'pagado', 'exonerado')),
  ADD COLUMN IF NOT EXISTS canal_pago VARCHAR(10)
      CHECK (canal_pago IN ('pasarela', 'caja')),
  ADD COLUMN IF NOT EXISTS fecha_pago TIMESTAMPTZ;

-- Columnas que alimentan la tarifa del caso 23 (monto_recarga ya existe desde la Semana 6)
ALTER TABLE recargas_tarjeta
  ADD COLUMN IF NOT EXISTS monto_recarga NUMERIC(8,2) NOT NULL DEFAULT 0 CHECK (monto_recarga >= 0),
  ADD COLUMN IF NOT EXISTS tarjeta_nueva BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS pase_universitario BOOLEAN NOT NULL DEFAULT false;

-- "estado" sigue siendo el estado operativo (registrado, atendido, rechazado).
-- "estado_pago" es el estado financiero. Son independientes.

-- ---------------------------------------------------------------------
-- Paso 3. Entidad emisora simulada (banco y billeteras)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS banco_cuentas (
  id               SERIAL PRIMARY KEY,
  numero_cuenta    VARCHAR(20) UNIQUE NOT NULL,
  titular          VARCHAR(100) NOT NULL,
  tipo             VARCHAR(10) NOT NULL CHECK (tipo IN ('ahorros', 'credito')),
  saldo_disponible NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (saldo_disponible >= 0),
  moneda           CHAR(3) NOT NULL DEFAULT 'PEN'
);

CREATE TABLE IF NOT EXISTS banco_tarjetas (
  id        SERIAL PRIMARY KEY,
  numero    VARCHAR(19) UNIQUE NOT NULL,          -- solo dígitos, sin espacios
  id_cuenta INT NOT NULL REFERENCES banco_cuentas(id),
  titular   VARCHAR(100) NOT NULL,
  marca     VARCHAR(20) NOT NULL,
  tipo      VARCHAR(10) NOT NULL CHECK (tipo IN ('debito', 'credito')),
  mes_venc  SMALLINT NOT NULL CHECK (mes_venc BETWEEN 1 AND 12),
  anio_venc SMALLINT NOT NULL,
  cvv       VARCHAR(4) NOT NULL,                  -- solo existe del lado del emisor simulado
  estado    VARCHAR(10) NOT NULL DEFAULT 'activa' CHECK (estado IN ('activa', 'bloqueada'))
);

CREATE TABLE IF NOT EXISTS billeteras (
  id                SERIAL PRIMARY KEY,
  proveedor         VARCHAR(12) NOT NULL CHECK (proveedor IN ('andipay', 'pagomovil')),
  celular           VARCHAR(9) NOT NULL,
  titular           VARCHAR(100) NOT NULL,
  saldo_disponible  NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (saldo_disponible >= 0),
  codigo_aprobacion VARCHAR(6) NOT NULL,          -- simula el código que la app muestra al cliente
  UNIQUE (proveedor, celular)
);

-- ---------------------------------------------------------------------
-- Paso 4. Tabla pagos del comercio (auditoría)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS pagos (
  id                  SERIAL PRIMARY KEY,
  codigo_operacion    VARCHAR(20) UNIQUE NOT NULL,
  id_registro         INT NOT NULL REFERENCES recargas_tarjeta(id),
  id_usuario          INT REFERENCES usuarios(id),          -- cliente que paga (puede ser NULL)
  canal               VARCHAR(10) NOT NULL CHECK (canal IN ('pasarela', 'caja')),
  metodo              VARCHAR(20) NOT NULL
                      CHECK (metodo IN ('tarjeta_debito', 'tarjeta_credito', 'billetera', 'efectivo', 'pos')),
  proveedor_billetera VARCHAR(12) CHECK (proveedor_billetera IN ('andipay', 'pagomovil')),
  marca_tarjeta       VARCHAR(20),
  referencia          VARCHAR(30),                          -- '**** 1111', '*** *** 321', 'Voucher 004512'
  monto               NUMERIC(10,2) NOT NULL CHECK (monto > 0),
  monto_recibido      NUMERIC(10,2),                        -- solo efectivo
  vuelto              NUMERIC(10,2),                        -- solo efectivo
  estado              VARCHAR(10) NOT NULL CHECK (estado IN ('aprobado', 'rechazado')),
  motivo_rechazo      VARCHAR(120),
  id_cajero           INT REFERENCES usuarios(id),          -- quién cobró en ventanilla
  verificado          BOOLEAN NOT NULL DEFAULT false,       -- conciliación de pagos en línea
  verificado_por      INT REFERENCES usuarios(id),
  fecha_verificacion  TIMESTAMPTZ,
  fecha_pago          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Regla de oro: un registro no puede tener dos pagos APROBADOS (evita el doble cobro)
CREATE UNIQUE INDEX IF NOT EXISTS uq_pagos_un_aprobado_por_registro
  ON pagos (id_registro) WHERE estado = 'aprobado';

-- ---------------------------------------------------------------------
-- Paso 5. Datos de prueba
-- ---------------------------------------------------------------------
-- 5.1 Cuentas, tarjetas y billeteras de prueba (números de prueba públicos que cumplen Luhn)
INSERT INTO banco_cuentas (numero_cuenta, titular, tipo, saldo_disponible) VALUES
  ('0011-000001', 'ANA TORRES QUISPE',  'ahorros', 1500.00),
  ('0011-000002', 'LUIS PEREZ ROJAS',   'ahorros',   10.00),
  ('0022-000001', 'MARIA HUAMAN SOTO',  'credito', 3000.00),
  ('0022-000002', 'JORGE LIMA CRUZ',    'credito', 2000.00),
  ('0011-000003', 'ROSA CCENCHO VEGA',  'ahorros',  800.00)
ON CONFLICT (numero_cuenta) DO NOTHING;

INSERT INTO banco_tarjetas (numero, id_cuenta, titular, marca, tipo, mes_venc, anio_venc, cvv, estado)
SELECT t.numero, c.id, c.titular, t.marca, t.tipo, t.mes, t.anio, t.cvv, t.estado
FROM (VALUES
  ('4111111111111111', '0011-000001', 'Visa',             'debito',  12, 2029, '123',  'activa'),
  ('4000000000000002', '0011-000002', 'Visa',             'debito',   8, 2028, '456',  'activa'),
  ('5555555555554444', '0022-000001', 'Mastercard',       'credito',  5, 2030, '789',  'activa'),
  ('5105105105105100', '0022-000002', 'Mastercard',       'credito',  3, 2027, '321',  'bloqueada'),
  ('378282246310005',  '0022-000001', 'American Express', 'credito', 11, 2028, '1234', 'activa'),
  ('4242424242424242', '0011-000003', 'Visa',             'debito',   1, 2025, '111',  'activa')
) AS t(numero, cuenta, marca, tipo, mes, anio, cvv, estado)
JOIN banco_cuentas c ON c.numero_cuenta = t.cuenta
ON CONFLICT (numero) DO NOTHING;

INSERT INTO billeteras (proveedor, celular, titular, saldo_disponible, codigo_aprobacion) VALUES
  ('andipay',   '987654321', 'ANA TORRES QUISPE',  500.00, '123456'),
  ('pagomovil', '912345678', 'LUIS PEREZ ROJAS',    15.00, '654321'),
  ('andipay',   '999888777', 'MARIA HUAMAN SOTO', 1000.00, '111222')
ON CONFLICT (proveedor, celular) DO NOTHING;

-- 5.2 Cajeros (contraseña: 1234) y DNI de los 10 clientes de prueba
INSERT INTO usuarios (nombre, correo, contrasena, rol) VALUES
  ('Cajera de Turno', 'caja@correo.com',  '1234', 'cajero'),
  ('Cajero Dos',      'caja2@correo.com', '1234', 'cajero')
ON CONFLICT (correo) DO NOTHING;

UPDATE usuarios
SET dni = (70000000 + id)::text
WHERE rol = 'cliente' AND dni IS NULL;

-- 5.3 Montos de los 30 registros ya precargados, calculados con la regla de MetroBus:
--     recarga + S/ 4.50 si pide tarjeta nueva (S/ 2.25 con pase universitario).
--     Para tener variedad: 1 de cada 4 registros pidió tarjeta nueva y 1 de cada 8 con pase universitario.
UPDATE recargas_tarjeta
SET tarjeta_nueva = (id % 4 = 0),
    pase_universitario = (id % 8 = 0)
WHERE monto_calculado = 0 AND estado_pago = 'pendiente';

UPDATE recargas_tarjeta
SET monto_calculado = ROUND(
      monto_recarga
      + CASE WHEN tarjeta_nueva THEN (CASE WHEN pase_universitario THEN 2.25 ELSE 4.50 END) ELSE 0 END
    , 2)
WHERE monto_calculado = 0 AND estado_pago = 'pendiente';

-- 5.4 Pagos ya realizados (para que caja no aparezca vacía el día de la sustentación):
--     4 por pasarela, 2 en caja y 1 rechazado. Solo se insertan una vez.
WITH elegidos AS (
  SELECT r.id, r.id_usuario, r.monto_calculado,
         ROW_NUMBER() OVER (ORDER BY r.id) AS n
  FROM recargas_tarjeta r
  WHERE r.estado_pago = 'pendiente' AND r.id_usuario IS NOT NULL
    AND NOT EXISTS (SELECT 1 FROM pagos WHERE codigo_operacion LIKE 'OP-SEED-%')
  ORDER BY r.id
  LIMIT 6
)
INSERT INTO pagos (codigo_operacion, id_registro, id_usuario, canal, metodo, proveedor_billetera,
                   marca_tarjeta, referencia, monto, monto_recibido, vuelto, estado, id_cajero)
SELECT
  'OP-SEED-' || LPAD(n::text, 3, '0'),
  id, id_usuario,
  CASE WHEN n <= 4 THEN 'pasarela' ELSE 'caja' END,
  (ARRAY['tarjeta_debito', 'tarjeta_credito', 'billetera', 'billetera', 'efectivo', 'pos'])[n],
  CASE n WHEN 3 THEN 'andipay' WHEN 4 THEN 'pagomovil' END,
  CASE n WHEN 1 THEN 'Visa' WHEN 2 THEN 'Mastercard' END,
  CASE n WHEN 1 THEN '**** 1111' WHEN 2 THEN '**** 4444' WHEN 3 THEN '*** *** 321'
         WHEN 4 THEN '*** *** 678' WHEN 5 THEN 'Efectivo' ELSE 'Voucher 004512' END,
  monto_calculado,
  CASE WHEN n = 5 THEN CEIL(monto_calculado / 10) * 10 END,
  CASE WHEN n = 5 THEN CEIL(monto_calculado / 10) * 10 - monto_calculado END,
  'aprobado',
  CASE WHEN n > 4 THEN (SELECT id FROM usuarios WHERE rol = 'cajero' ORDER BY id LIMIT 1) END
FROM elegidos;

-- Marcar como pagados los registros que ya tienen pago aprobado
UPDATE recargas_tarjeta r
SET estado_pago = 'pagado', canal_pago = p.canal, fecha_pago = p.fecha_pago
FROM pagos p
WHERE p.id_registro = r.id AND p.estado = 'aprobado' AND r.estado_pago = 'pendiente';

-- El pago habilita la activación del saldo: pagado → saldo = recarga; pendiente → saldo en 0
UPDATE recargas_tarjeta SET saldo_actual = monto_recarga WHERE estado_pago = 'pagado';
UPDATE recargas_tarjeta SET saldo_actual = 0 WHERE estado_pago = 'pendiente';

-- Un intento rechazado por la pasarela
INSERT INTO pagos (codigo_operacion, id_registro, id_usuario, canal, metodo, marca_tarjeta,
                   referencia, monto, estado, motivo_rechazo)
SELECT 'RCH-SEED-001', r.id, r.id_usuario, 'pasarela', 'tarjeta_debito', 'Visa',
       '**** 0002', r.monto_calculado, 'rechazado', 'Saldo insuficiente en la cuenta de ahorros.'
FROM recargas_tarjeta r
WHERE r.estado_pago = 'pendiente' AND r.id_usuario IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM pagos WHERE codigo_operacion = 'RCH-SEED-001')
ORDER BY r.id DESC
LIMIT 1;

-- ---------------------------------------------------------------------
-- Paso 6. Consultas de verificación (captura obligatoria)
-- ---------------------------------------------------------------------
SELECT rol, COUNT(*) FROM usuarios GROUP BY rol ORDER BY rol;

SELECT estado_pago, canal_pago, COUNT(*) AS registros, SUM(monto_calculado) AS total
FROM recargas_tarjeta GROUP BY estado_pago, canal_pago ORDER BY estado_pago;

SELECT canal, metodo, estado, COUNT(*) AS operaciones, SUM(monto) AS total
FROM pagos GROUP BY canal, metodo, estado ORDER BY canal, metodo, estado;

-- Resultado esperado aproximado: 10 clientes, 1 administrador, 3 empleados, 2 cajeros;
-- 6 registros pagados (4 por pasarela, 2 por caja) y 24 pendientes;
-- 7 filas en pagos (6 aprobadas, 1 rechazada).
