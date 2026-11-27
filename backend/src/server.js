import express from 'express';
import { neon } from '@neondatabase/serverless';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';

const app = express();
app.use(express.json({ limit: '32kb' }));

const sql = () => {
  if (!process.env.DATABASE_URL) throw new Error('DATABASE_URL no está configurada');
  return neon(process.env.DATABASE_URL);
};
const tokenFor = (user) => jwt.sign(
  { id: user.id, correo: user.correo, rol: user.rol, nombre: user.nombre },
  process.env.JWT_SECRET,
  { expiresIn: '8h' }
);
const auth = (req, res, next) => {
  try {
    const raw = req.headers.authorization?.replace(/^Bearer\s+/i, '');
    if (!raw) return res.status(401).json({ error: 'Inicia sesión para continuar.' });
    req.user = jwt.verify(raw, process.env.JWT_SECRET);
    next();
  } catch { return res.status(401).json({ error: 'Sesión inválida o vencida.' }); }
};
const allow = (...roles) => (req, res, next) =>
  roles.includes(req.user?.rol) ? next() : res.status(403).json({ error: 'No tienes permisos para esta acción.' });

app.get('/api/health', async (_req, res) => {
  try { await sql()`SELECT 1`; res.json({ ok: true, service: 'MetroBus Lima API' }); }
  catch { res.status(503).json({ ok: false, error: 'Base de datos no disponible.' }); }
});

app.post('/api/auth/register', async (req, res) => {
  try {
    const { nombre, correo, contrasena, dni } = req.body || {};
    if (!nombre?.trim() || !/^\S+@\S+\.\S+$/.test(correo || '') || !contrasena || contrasena.length < 8)
      return res.status(400).json({ error: 'Completa nombre, correo válido y contraseña de al menos 8 caracteres.' });
    const db = sql();
    const hash = await bcrypt.hash(contrasena, 12);
    const rows = await db`INSERT INTO usuarios (nombre, correo, contrasena, dni, rol)
      VALUES (${nombre.trim()}, ${correo.toLowerCase().trim()}, ${hash}, ${dni || null}, 'cliente')
      RETURNING id, nombre, correo, rol`;
    res.status(201).json({ user: rows[0], token: tokenFor(rows[0]) });
  } catch (e) {
    if (e.code === '23505') return res.status(409).json({ error: 'Ese correo ya está registrado.' });
    res.status(500).json({ error: 'No se pudo crear la cuenta.' });
  }
});

app.post('/api/auth/login', async (req, res) => {
  try {
    const { correo, contrasena } = req.body || {};
    if (!correo || !contrasena) return res.status(400).json({ error: 'Ingresa correo y contraseña.' });
    const db = sql();
    const rows = await db`SELECT id, nombre, correo, contrasena, rol, turno, hora_inicio, hora_fin
      FROM usuarios WHERE lower(correo) = ${correo.toLowerCase().trim()} LIMIT 1`;
    const row = rows[0];
    if (!row) return res.status(401).json({ error: 'Credenciales incorrectas.' });
    const looksHashed = /^\$2[aby]\$/.test(row.contrasena);
    const valid = looksHashed ? await bcrypt.compare(contrasena, row.contrasena) : contrasena === row.contrasena;
    if (!valid) return res.status(401).json({ error: 'Credenciales incorrectas.' });
    if (!looksHashed) {
      const hash = await bcrypt.hash(contrasena, 12);
      await db`UPDATE usuarios SET contrasena = ${hash} WHERE id = ${row.id}`;
    }
    const user = { id: row.id, nombre: row.nombre, correo: row.correo, rol: row.rol, turno: row.turno, hora_inicio: row.hora_inicio, hora_fin: row.hora_fin };
    res.json({ user, token: tokenFor(user) });
  } catch { res.status(500).json({ error: 'No se pudo iniciar sesión.' }); }
});

app.get('/api/auth/me', auth, async (req, res) => {
  try {
    const rows = await sql()`SELECT id, nombre, correo, rol, turno, hora_inicio, hora_fin FROM usuarios WHERE id = ${req.user.id}`;
    if (!rows[0]) return res.status(404).json({ error: 'Usuario no encontrado.' });
    res.json({ user: rows[0] });
  } catch { res.status(500).json({ error: 'No se pudo consultar la sesión.' }); }
});

app.post('/api/recargas', auth, async (req, res) => {
  try {
    const { numero_tarjeta, monto, tarjeta_nueva = false, pase_universitario = false, canal_pago = 'pasarela' } = req.body || {};
    const amount = Number(monto);
    if (!Number.isFinite(amount) || amount < 1 || amount > 500) return res.status(400).json({ error: 'El monto debe estar entre S/ 1 y S/ 500.' });
    if (!numero_tarjeta || !/^\d{10}$/.test(String(numero_tarjeta))) return res.status(400).json({ error: 'El número de tarjeta debe contener exactamente 10 dígitos.' });
    if (!['pasarela', 'caja'].includes(canal_pago)) return res.status(400).json({ error: 'Canal de pago no válido.' });
    const code = 'MB-' + Date.now().toString(36).toUpperCase() + '-' + Math.random().toString(36).slice(2, 6).toUpperCase();
    const rows = await sql()`INSERT INTO recargas_tarjeta
      (codigo_seguimiento, numero_tarjeta, monto_recarga, monto_calculado, estado_pago, canal_pago, tarjeta_nueva, pase_universitario, id_usuario)
      VALUES (${code}, ${numero_tarjeta || null}, ${amount}, ${amount}, 'pendiente', ${canal_pago}, ${!!tarjeta_nueva}, ${!!pase_universitario}, ${req.user.id})
      RETURNING id, codigo_seguimiento, monto_calculado, estado_pago, fecha_registro`;
    res.status(201).json({ recarga: rows[0] });
  } catch { res.status(500).json({ error: 'No se pudo registrar la recarga.' }); }
});

app.post('/api/recargas/:id/pago-simulado', auth, async (req, res) => {
  try {
    const id = Number(req.params.id);
    if (!Number.isInteger(id)) return res.status(400).json({ error: 'Identificador no válido.' });
    const db = sql();
    const paid = await db`UPDATE recargas_tarjeta SET estado_pago = 'pagado', estado = 'pagado',
      fecha_pago = now(), saldo_actual = COALESCE(saldo_actual, 0) + monto_calculado
      WHERE id = ${id} AND id_usuario = ${req.user.id} AND estado_pago = 'pendiente' AND canal_pago = 'pasarela'
      RETURNING id, codigo_seguimiento, monto_calculado, fecha_pago`;
    if (!paid[0]) return res.status(404).json({ error: 'No se encontró una recarga digital pendiente.' });
    const operation = 'WEB-' + Date.now().toString(36).toUpperCase();
    await db`INSERT INTO pagos (codigo_operacion, id_registro, id_usuario, canal, metodo, monto, estado, verificado)
      VALUES (${operation}, ${id}, ${req.user.id}, 'pasarela', 'tarjeta_debito', ${paid[0].monto_calculado}, 'aprobado', true)`;
    res.json({ operacion: operation, recarga: paid[0], simulated: true });
  } catch { res.status(500).json({ error: 'No se pudo completar el pago simulado.' }); }
});

app.get('/api/recargas', auth, async (req, res) => {
  try {
    const rows = req.user.rol === 'administrador' || req.user.rol === 'empleado' || req.user.rol === 'cajero'
      ? await sql()`SELECT r.*, u.nombre AS usuario_nombre FROM recargas_tarjeta r LEFT JOIN usuarios u ON u.id = r.id_usuario ORDER BY r.fecha_registro DESC LIMIT 100`
      : await sql()`SELECT id, codigo_seguimiento, numero_tarjeta, monto_calculado, estado_pago, canal_pago, fecha_registro FROM recargas_tarjeta WHERE id_usuario = ${req.user.id} ORDER BY fecha_registro DESC LIMIT 50`;
    res.json({ recargas: rows });
  } catch { res.status(500).json({ error: 'No se pudieron consultar las recargas.' }); }
});

app.post('/api/solicitudes', async (req, res) => {
  try {
    const { categoria = 'consulta', tipo, nombre, dni, correo, mensaje } = req.body || {};
    if (!['consulta', 'reclamo'].includes(categoria) || !tipo || !nombre?.trim() || !dni?.trim() || !correo?.trim())
      return res.status(400).json({ error: 'Completa los datos obligatorios de la solicitud.' });
    const rows = await sql()`INSERT INTO solicitudes (categoria, tipo, nombre, dni, correo, mensaje)
      VALUES (${categoria}, ${tipo}, ${nombre.trim()}, ${dni.trim()}, ${correo.trim()}, ${mensaje || null})
      RETURNING id, categoria, estado, fecha_registro`;
    res.status(201).json({ solicitud: rows[0] });
  } catch { res.status(500).json({ error: 'No se pudo registrar la solicitud.' }); }
});

app.get('/api/admin/resumen', auth, allow('administrador', 'empleado', 'cajero'), async (_req, res) => {
  try {
    const [users, topups, pending, requests] = await Promise.all([
      sql()`SELECT count(*)::int AS total FROM usuarios`,
      sql()`SELECT count(*)::int AS total FROM recargas_tarjeta`,
      sql()`SELECT count(*)::int AS total FROM recargas_tarjeta WHERE estado_pago = 'pendiente'`,
      sql()`SELECT count(*)::int AS total FROM solicitudes WHERE estado = 'pendiente'`
    ]);
    res.json({ usuarios: users[0].total, recargas: topups[0].total, pendientes: pending[0].total, solicitudes: requests[0].total });
  } catch { res.status(500).json({ error: 'No se pudo cargar el resumen.' }); }
});


// Apertura y control de turnos de caja. Cada empleado/cajero solo puede tener un turno abierto.
app.get('/api/caja/turnos/actual', auth, allow('administrador', 'cajero', 'empleado'), async (req, res) => {
  try {
    const rows = await sql()`SELECT * FROM caja_turnos WHERE id_cajero = ${req.user.id} AND estado = 'abierto' ORDER BY fecha_apertura DESC LIMIT 1`;
    res.json({ turno: rows[0] || null });
  } catch { res.status(500).json({ error: 'No se pudo consultar el turno de caja.' }); }
});

app.post('/api/caja/turnos/abrir', auth, allow('administrador', 'cajero', 'empleado'), async (req, res) => {
  try {
    const turno = req.body?.turno || req.user.turno || 'manana';
    const monto = Number(req.body?.monto_inicial ?? 0);
    if (!['manana','tarde','noche'].includes(turno) || !Number.isFinite(monto) || monto < 0)
      return res.status(400).json({ error: 'Turno o monto inicial no válido.' });
    const rows = await sql()`INSERT INTO caja_turnos (id_cajero, turno, monto_inicial) VALUES (${req.user.id}, ${turno}, ${monto}) RETURNING *`;
    res.status(201).json({ turno: rows[0] });
  } catch (e) {
    if (e.code === '23505') return res.status(409).json({ error: 'Ya tienes un turno de caja abierto.' });
    res.status(500).json({ error: 'No se pudo abrir el turno.' });
  }
});

app.post('/api/caja/turnos/cerrar', auth, allow('administrador', 'cajero', 'empleado'), async (req, res) => {
  try {
    const contado = Number(req.body?.monto_cierre);
    if (!Number.isFinite(contado) || contado < 0) return res.status(400).json({ error: 'Ingresa un monto de cierre válido.' });
    const rows = await sql()`UPDATE caja_turnos SET estado = 'cerrado', fecha_cierre = now(), monto_cierre = ${contado}, observaciones = ${req.body?.observaciones || null}
      WHERE id_cajero = ${req.user.id} AND estado = 'abierto' RETURNING *`;
    if (!rows[0]) return res.status(404).json({ error: 'No tienes un turno abierto.' });
    res.json({ turno: rows[0] });
  } catch { res.status(500).json({ error: 'No se pudo cerrar el turno.' }); }
});

app.get('/api/caja/resumen', auth, allow('administrador', 'cajero', 'empleado'), async (req, res) => {
  try {
    const rows = req.user.rol === 'administrador'
      ? await sql()`SELECT t.*, u.nombre AS cajero, COALESCE(SUM(p.monto) FILTER (WHERE p.estado='aprobado'),0)::numeric(10,2) AS total_operado, COUNT(p.id)::int AS operaciones
          FROM caja_turnos t JOIN usuarios u ON u.id=t.id_cajero LEFT JOIN pagos p ON p.id_turno=t.id
          GROUP BY t.id,u.nombre ORDER BY t.fecha_apertura DESC LIMIT 100`
      : await sql()`SELECT t.*, u.nombre AS cajero, COALESCE(SUM(p.monto) FILTER (WHERE p.estado='aprobado'),0)::numeric(10,2) AS total_operado, COUNT(p.id)::int AS operaciones
          FROM caja_turnos t JOIN usuarios u ON u.id=t.id_cajero LEFT JOIN pagos p ON p.id_turno=t.id
          WHERE t.id_cajero=${req.user.id} GROUP BY t.id,u.nombre ORDER BY t.fecha_apertura DESC LIMIT 50`;
    res.json({ turnos: rows });
  } catch { res.status(500).json({ error: 'No se pudo cargar el resumen de caja.' }); }
});

app.get('/api/admin/usuarios', auth, allow('administrador'), async (_req, res) => {
  try {
    const rows = await sql()`SELECT id,nombre,correo,dni,rol,turno,hora_inicio,hora_fin,fecha_registro FROM usuarios ORDER BY id DESC LIMIT 200`;
    res.json({ usuarios: rows });
  } catch { res.status(500).json({ error: 'No se pudieron consultar los usuarios.' }); }
});

app.post('/api/admin/usuarios', auth, allow('administrador'), async (req, res) => {
  try {
    const { nombre, correo, contrasena, rol='empleado', turno='manana' } = req.body || {};
    if (!nombre?.trim() || !/^\S+@\S+\.\S+$/.test(correo || '') || !contrasena || contrasena.length < 8)
      return res.status(400).json({ error: 'Completa nombre, correo válido y contraseña de al menos 8 caracteres.' });
    if (!['empleado','cajero'].includes(rol) || !['manana','tarde','noche'].includes(turno))
      return res.status(400).json({ error: 'Rol o turno no permitido.' });
    const hash = await bcrypt.hash(contrasena, 12);
    const rows = await sql()`INSERT INTO usuarios (nombre,correo,contrasena,rol,turno) VALUES (${nombre.trim()},${correo.toLowerCase().trim()},${hash},${rol},${turno})
      RETURNING id,nombre,correo,rol,turno`;
    res.status(201).json({ usuario: rows[0] });
  } catch (e) {
    if (e.code === '23505') return res.status(409).json({ error: 'Ese correo ya está registrado.' });
    res.status(500).json({ error: 'No se pudo crear el usuario.' });
  }
});

app.patch('/api/admin/usuarios/:id/rol', auth, allow('administrador'), async (req, res) => {
  try {
    const id = Number(req.params.id), rol = req.body?.rol;
    if (!Number.isInteger(id) || !['cliente','empleado','cajero','administrador'].includes(rol))
      return res.status(400).json({ error: 'Usuario o rol no válido.' });
    if (id === req.user.id) return res.status(400).json({ error: 'No puedes cambiar tu propio rol.' });
    const rows = await sql()`UPDATE usuarios SET rol=${rol} WHERE id=${id} RETURNING id,nombre,correo,rol,turno`;
    if (!rows[0]) return res.status(404).json({ error: 'Usuario no encontrado.' });
    res.json({ usuario: rows[0] });
  } catch { res.status(500).json({ error: 'No se pudo actualizar el rol.' }); }
});

app.patch('/api/admin/recargas/:id', auth, allow('administrador','empleado'), async (req, res) => {
  try {
    const id=Number(req.params.id), estado=req.body?.estado;
    if (!Number.isInteger(id) || !['registrado','atendido','rechazado'].includes(estado))
      return res.status(400).json({ error: 'Estado o identificador no válido.' });
    const rows=await sql()`UPDATE recargas_tarjeta SET estado=${estado}, id_empleado=${req.user.id}, turno_gestion=${req.user.turno || null}
      WHERE id=${id} RETURNING id,codigo_seguimiento,estado,estado_pago`;
    if (!rows[0]) return res.status(404).json({ error: 'Recarga no encontrada.' });
    res.json({ recarga: rows[0] });
  } catch { res.status(500).json({ error: 'No se pudo actualizar la recarga.' }); }
});

app.get('/api/caja/pendientes', auth, allow('administrador', 'cajero', 'empleado'), async (_req, res) => {
  try {
    const rows = await sql()`SELECT r.id, r.codigo_seguimiento, r.monto_calculado, r.numero_tarjeta, r.fecha_registro, u.nombre
      FROM recargas_tarjeta r LEFT JOIN usuarios u ON u.id = r.id_usuario
      WHERE r.estado_pago = 'pendiente' AND r.canal_pago = 'caja' ORDER BY r.fecha_registro ASC LIMIT 100`;
    res.json({ pendientes: rows });
  } catch { res.status(500).json({ error: 'No se pudieron cargar las operaciones de caja.' }); }
});

app.post('/api/caja/:id/pagar', auth, allow('administrador', 'cajero', 'empleado'), async (req, res) => {
  try {
    const id = Number(req.params.id);
    const turnos = await sql()`SELECT id FROM caja_turnos WHERE id_cajero=${req.user.id} AND estado='abierto' LIMIT 1`;
    if (!turnos[0]) return res.status(409).json({ error: 'Primero debes abrir tu turno de caja.' });
    const rows = await sql()`SELECT * FROM recargas_tarjeta WHERE id = ${id} AND estado_pago = 'pendiente' AND canal_pago = 'caja' LIMIT 1`;
    if (!rows[0]) return res.status(404).json({ error: 'Operación pendiente no encontrada.' });
    const received = Number(req.body?.monto_recibido ?? rows[0].monto_calculado);
    if (!Number.isFinite(received) || received < Number(rows[0].monto_calculado)) return res.status(400).json({ error: 'El monto recibido es insuficiente.' });
    const operation = 'CAJA-' + Date.now().toString(36).toUpperCase();
    const result = await sql()`UPDATE recargas_tarjeta SET estado_pago = 'pagado', estado = 'pagado', id_empleado = ${req.user.id}, fecha_pago = now(), saldo_actual = COALESCE(saldo_actual, 0) + monto_calculado
      WHERE id = ${id} AND estado_pago = 'pendiente' RETURNING id, codigo_seguimiento, monto_calculado`;
    if (!result[0]) return res.status(409).json({ error: 'La operación ya fue procesada.' });
    await sql()`INSERT INTO pagos (codigo_operacion, id_registro, id_usuario, canal, metodo, monto, monto_recibido, vuelto, estado, id_cajero, id_turno, verificado)
      VALUES (${operation}, ${id}, ${rows[0].id_usuario}, 'caja', 'efectivo', ${rows[0].monto_calculado}, ${received}, ${received - Number(rows[0].monto_calculado)}, 'aprobado', ${req.user.id}, ${turnos[0].id}, true)`;
    res.json({ operacion: operation, recarga: result[0], vuelto: received - Number(rows[0].monto_calculado) });
  } catch { res.status(500).json({ error: 'No se pudo procesar el pago de caja.' }); }
});

app.patch('/api/admin/solicitudes/:id', auth, allow('administrador','empleado'), async (req,res)=>{
  try {
    const id=Number(req.params.id), estado=req.body?.estado;
    if(!Number.isInteger(id)||!['pendiente','atendido','rechazado'].includes(estado)) return res.status(400).json({error:'Estado o identificador no válido.'});
    const rows=await sql()`UPDATE solicitudes SET estado=${estado} WHERE id=${id} RETURNING id,categoria,estado`;
    if(!rows[0]) return res.status(404).json({error:'Solicitud no encontrada.'});
    res.json({solicitud:rows[0]});
  } catch { res.status(500).json({error:'No se pudo actualizar la solicitud.'}); }
});

app.get('/api/admin/solicitudes', auth, allow('administrador', 'empleado'), async (_req, res) => {
  try {
    const rows = await sql()`SELECT * FROM solicitudes ORDER BY fecha_registro DESC LIMIT 100`;
    res.json({ solicitudes: rows });
  } catch { res.status(500).json({ error: 'No se pudieron consultar las solicitudes.' }); }
});

export default app;