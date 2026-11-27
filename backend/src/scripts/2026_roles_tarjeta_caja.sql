-- MetroBus Lima: roles, validacion de tarjeta y control de turnos de caja
-- Migracion idempotente para Neon PostgreSQL.
-- La tarjeta se guarda como texto para conservar ceros iniciales.

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'recargas_tarjeta_numero_10_digitos_check'
      AND conrelid = 'public.recargas_tarjeta'::regclass
  ) THEN
    ALTER TABLE public.recargas_tarjeta
      ADD CONSTRAINT recargas_tarjeta_numero_10_digitos_check
      CHECK (numero_tarjeta IS NULL OR numero_tarjeta ~ '^[0-9]{10}$');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.caja_turnos (
  id BIGSERIAL PRIMARY KEY,
  id_cajero INTEGER NOT NULL REFERENCES public.usuarios(id),
  turno VARCHAR(10) NOT NULL CHECK (turno IN ('manana','tarde','noche')),
  fecha_apertura TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fecha_cierre TIMESTAMPTZ,
  monto_inicial NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (monto_inicial >= 0),
  monto_cierre NUMERIC(10,2) CHECK (monto_cierre IS NULL OR monto_cierre >= 0),
  estado VARCHAR(10) NOT NULL DEFAULT 'abierto' CHECK (estado IN ('abierto','cerrado')),
  observaciones TEXT
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_caja_turno_abierto_por_cajero
  ON public.caja_turnos (id_cajero) WHERE estado = 'abierto';

ALTER TABLE public.pagos
  ADD COLUMN IF NOT EXISTS id_turno BIGINT REFERENCES public.caja_turnos(id);

CREATE INDEX IF NOT EXISTS idx_pagos_fecha_canal
  ON public.pagos (fecha_pago DESC, canal);

CREATE INDEX IF NOT EXISTS idx_caja_turnos_cajero_fecha
  ON public.caja_turnos (id_cajero, fecha_apertura DESC);
