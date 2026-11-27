-- =====================================================================
-- Semana 7 — MetroBus Lima (Neon / PostgreSQL)
-- Pega este archivo completo en Neon → SQL Editor y ejecútalo.
-- Se puede ejecutar más de una vez sin duplicar datos.
-- =====================================================================

-- 0) Tablas base (por si todavía no existen)
CREATE TABLE IF NOT EXISTS usuarios (
  id SERIAL PRIMARY KEY,
  nombre TEXT NOT NULL,
  correo TEXT NOT NULL UNIQUE,
  contrasena TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS recargas_tarjeta (
  id SERIAL PRIMARY KEY,
  codigo_seguimiento TEXT NOT NULL,
  numero_tarjeta TEXT NOT NULL,
  monto_recarga NUMERIC(10,2) NOT NULL,
  saldo_actual NUMERIC(10,2) NOT NULL,
  fecha_registro TIMESTAMP NOT NULL DEFAULT NOW()
);

-- 0b) Si las tablas ya existían de la Semana 6 con menos columnas, se completan aquí.
--     (Sin NOT NULL para no fallar con filas antiguas.)
ALTER TABLE usuarios ADD COLUMN IF NOT EXISTS nombre TEXT;
ALTER TABLE usuarios ADD COLUMN IF NOT EXISTS correo TEXT;
ALTER TABLE usuarios ADD COLUMN IF NOT EXISTS contrasena TEXT;
ALTER TABLE recargas_tarjeta ADD COLUMN IF NOT EXISTS codigo_seguimiento TEXT;
ALTER TABLE recargas_tarjeta ADD COLUMN IF NOT EXISTS numero_tarjeta TEXT;
ALTER TABLE recargas_tarjeta ADD COLUMN IF NOT EXISTS monto_recarga NUMERIC(10,2);
ALTER TABLE recargas_tarjeta ADD COLUMN IF NOT EXISTS saldo_actual NUMERIC(10,2);
ALTER TABLE recargas_tarjeta ADD COLUMN IF NOT EXISTS fecha_registro TIMESTAMP DEFAULT NOW();
-- ON CONFLICT (correo) necesita que "correo" sea único:
CREATE UNIQUE INDEX IF NOT EXISTS usuarios_correo_unico ON usuarios (correo);

-- 1) Roles en usuarios
ALTER TABLE usuarios
  ADD COLUMN IF NOT EXISTS rol VARCHAR(20) NOT NULL DEFAULT 'cliente'
  CHECK (rol IN ('cliente', 'administrador', 'empleado'));

-- 2) Columnas nuevas en recargas_tarjeta
ALTER TABLE recargas_tarjeta ADD COLUMN IF NOT EXISTS id_usuario INT REFERENCES usuarios(id);
ALTER TABLE recargas_tarjeta ADD COLUMN IF NOT EXISTS estado VARCHAR(20) NOT NULL DEFAULT 'registrado';
-- El panel crea registros sin cliente (atención presencial), así que id_usuario debe aceptar NULL:
ALTER TABLE recargas_tarjeta ALTER COLUMN id_usuario DROP NOT NULL;

-- 2b) Turnos de trabajo (mañana, tarde, noche).
--     usuarios.turno: solo lo usan los empleados (los demás roles quedan en NULL).
--     recargas_tarjeta.id_empleado / turno_gestion: qué empleado y de qué turno gestionó el registro.
ALTER TABLE usuarios ADD COLUMN IF NOT EXISTS turno VARCHAR(10)
  CHECK (turno IN ('manana', 'tarde', 'noche'));
-- Horario propio de cada empleado (hora de Lima, 0-23; la hora de fin no se incluye).
-- Si el fin es menor que el inicio, el horario cruza la medianoche (ej. 22 → 6; no hace falta con la jornada de 06:00 a 22:00).
ALTER TABLE usuarios ADD COLUMN IF NOT EXISTS hora_inicio SMALLINT CHECK (hora_inicio BETWEEN 0 AND 23);
ALTER TABLE usuarios ADD COLUMN IF NOT EXISTS hora_fin SMALLINT CHECK (hora_fin BETWEEN 0 AND 23);
ALTER TABLE recargas_tarjeta ADD COLUMN IF NOT EXISTS id_empleado INT REFERENCES usuarios(id);
ALTER TABLE recargas_tarjeta ADD COLUMN IF NOT EXISTS turno_gestion VARCHAR(10)
  CHECK (turno_gestion IN ('manana', 'tarde', 'noche'));

-- 3) 10 clientes + 1 administrador + 3 empleados de prueba (uno por turno) (contraseña: 1234)
INSERT INTO usuarios (nombre, correo, contrasena, rol)
SELECT 'Cliente ' || n, 'cliente' || n || '@correo.com', '1234', 'cliente'
FROM generate_series(1, 10) AS n
UNION ALL
VALUES
  ('Admin de prueba', 'admin@correo.com', '1234', 'administrador'),
  ('Empleado Uno', 'empleado1@correo.com', '1234', 'empleado'),
  ('Empleado Dos', 'empleado2@correo.com', '1234', 'empleado'),
  ('Empleado Tres', 'empleado3@correo.com', '1234', 'empleado')
ON CONFLICT (correo) DO NOTHING
RETURNING id, nombre, rol;

-- 4) 3 recargas por cada uno de los 10 clientes de prueba = 30 registros
INSERT INTO recargas_tarjeta (id_usuario, codigo_seguimiento, numero_tarjeta, monto_recarga, saldo_actual, estado)
SELECT
  u.id,
  'COD-' || lpad((u.id * 10 + s)::text, 8, '0'),
  lpad((u.id * 100 + s)::text, 10, '0'),
  s * 5,
  s * 5,
  CASE WHEN s = 1 THEN 'registrado' ELSE 'atendido' END
FROM usuarios u
CROSS JOIN generate_series(1, 3) AS s
WHERE u.correo ~ '^cliente[0-9]+@correo\.com$'
  AND NOT EXISTS (SELECT 1 FROM recargas_tarjeta r WHERE r.id_usuario = u.id);

-- 4b) Un empleado por turno, cada uno con SU horario (hora_inicio y hora_fin).
--     La jornada termina a las 22:00: mañana 06-12, tarde 12-17, noche 17-22.
--     Para cambiar el horario de alguien, edita los dos números de su línea y vuelve a ejecutar esta parte.
UPDATE usuarios SET turno = 'manana', hora_inicio = 6,  hora_fin = 12 WHERE correo = 'empleado1@correo.com';
UPDATE usuarios SET turno = 'tarde',  hora_inicio = 12, hora_fin = 17 WHERE correo = 'empleado2@correo.com';
UPDATE usuarios SET turno = 'noche',  hora_inicio = 17, hora_fin = 22 WHERE correo = 'empleado3@correo.com';

-- 4c) Las recargas atendidas de los clientes de prueba se reparten entre los tres empleados
--     (con el turno de cada uno). Se puede ejecutar varias veces: siempre da el mismo reparto.
UPDATE recargas_tarjeta r
SET id_empleado = e.id, turno_gestion = e.turno
FROM usuarios e
WHERE r.estado = 'atendido'
  AND r.id_usuario IS NOT NULL
  AND e.correo = CASE r.id % 3
                   WHEN 0 THEN 'empleado1@correo.com'
                   WHEN 1 THEN 'empleado2@correo.com'
                   ELSE 'empleado3@correo.com'
                 END;

-- 4d) Toda recarga debe tener turno. Las que no lo tengan reciben el que corresponde a la hora (Lima)
--     en que se registraron: mañana 06-12, tarde 12-17, noche 17-22 (fuera de jornada → mañana).
UPDATE recargas_tarjeta
SET turno_gestion = CASE
  WHEN h >= 6  AND h < 12 THEN 'manana'
  WHEN h >= 12 AND h < 17 THEN 'tarde'
  WHEN h >= 17 AND h < 22 THEN 'noche'
  ELSE 'manana'
END
FROM (
  SELECT id AS rid,
         EXTRACT(HOUR FROM (fecha_registro AT TIME ZONE 'UTC') AT TIME ZONE 'America/Lima')::int AS h
  FROM recargas_tarjeta
  WHERE turno_gestion IS NULL
) t
WHERE recargas_tarjeta.id = t.rid;

-- 4e) Consultas y reclamos (formulario de contacto.html). Los ven el administrador y los 3 empleados en el panel.
CREATE TABLE IF NOT EXISTS solicitudes (
  id SERIAL PRIMARY KEY,
  categoria VARCHAR(10) NOT NULL DEFAULT 'consulta' CHECK (categoria IN ('consulta', 'reclamo')),
  tipo VARCHAR(20) NOT NULL,
  nombre TEXT NOT NULL,
  dni VARCHAR(8) NOT NULL,
  correo TEXT NOT NULL,
  mensaje TEXT,
  estado VARCHAR(20) NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente', 'atendido')),
  turno_gestion VARCHAR(10) CHECK (turno_gestion IN ('manana', 'tarde', 'noche')),
  id_empleado INT REFERENCES usuarios(id),
  fecha_registro TIMESTAMP NOT NULL DEFAULT NOW()
);

-- Ejemplos para ver el panel con datos (solo se insertan si la tabla está vacía)
INSERT INTO solicitudes (categoria, tipo, nombre, dni, correo, mensaje, turno_gestion)
SELECT * FROM (VALUES
  ('reclamo',  'tarjeta',  'Rosa Quispe',   '45871236', 'rosa@correo.com',   'Recargué S/ 10 y el saldo no se refleja en mi tarjeta.', 'manana'),
  ('consulta', 'ruta',     'Luis Huamán',   '70123456', 'luis@correo.com',   '¿Cada cuánto pasa el bus de la Línea B en hora punta?', 'manana'),
  ('reclamo',  'estacion', 'Ana Torres',    '41236987', 'ana@correo.com',    'El torniquete de la estación Naranjal está malogrado.', 'tarde'),
  ('consulta', 'tarjeta',  'Carlos Rojas',  '72345698', 'carlos@correo.com', '¿Dónde puedo comprar una tarjeta nueva?', 'tarde'),
  ('reclamo',  'ruta',     'Marta Salas',   '46789123', 'marta@correo.com',  'El bus de la Línea A demoró más de 30 minutos.', 'noche'),
  ('consulta', 'otro',     'Jorge Ñahui',   '43219876', 'jorge@correo.com',  '¿Hasta qué hora atienden en la oficina principal?', 'noche')
) AS v(categoria, tipo, nombre, dni, correo, mensaje, turno_gestion)
WHERE NOT EXISTS (SELECT 1 FROM solicitudes);

-- 5) Verificación (esto es lo que se captura para el entregable)
SELECT rol, COUNT(*) AS cantidad FROM usuarios GROUP BY rol ORDER BY rol;
SELECT nombre, correo, turno, hora_inicio, hora_fin FROM usuarios WHERE rol = 'empleado' ORDER BY id;
SELECT turno_gestion, COUNT(*) AS recargas FROM recargas_tarjeta GROUP BY turno_gestion ORDER BY turno_gestion;
SELECT COUNT(*) AS total_recargas FROM recargas_tarjeta;
SELECT id_usuario, COUNT(*) AS recargas FROM recargas_tarjeta GROUP BY id_usuario ORDER BY id_usuario;
SELECT categoria, estado, COUNT(*) AS cantidad FROM solicitudes GROUP BY categoria, estado ORDER BY categoria, estado;
