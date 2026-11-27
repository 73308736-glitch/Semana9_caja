# MetroBus Lima

Proyecto académico de movilidad urbana organizado en frontend y backend, siguiendo la estructura de referencia SAT-LIMA-Final.

## Estructura
- `frontend/`: React + Vite, componentes, páginas, estilos y utilidades.
- `backend/`: API Express, configuración, control de acceso y lógica del servidor.
- `api/index.js`: adaptador para publicar la API en Vercel.

## Desarrollo
- Instalar dependencias: `npm install`
- Ejecutar frontend: `npm run dev`
- Compilar: `npm run build`

Configurar `DATABASE_URL` y `JWT_SECRET` como variables de entorno del servidor. No colocar secretos en variables `VITE_*`.

El sistema conserva autenticación, registro, recargas simuladas, pagos en caja, historial, panel de gestión, comprobantes y solicitudes de atención.
