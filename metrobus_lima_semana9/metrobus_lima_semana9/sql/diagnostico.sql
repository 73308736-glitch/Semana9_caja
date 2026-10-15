-- Diagnóstico: pega esto en Neon → SQL Editor para ver qué columnas existen de verdad.
-- Debe aparecer "rol" y "turno" en usuarios, y "id_usuario", "estado", "id_empleado", "turno_gestion" en recargas_tarjeta.
SELECT table_name, column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public' AND table_name IN ('usuarios', 'recargas_tarjeta')
ORDER BY table_name, ordinal_position;
