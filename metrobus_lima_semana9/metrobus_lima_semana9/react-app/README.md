# MetroBus Lima — migración React

Aplicación en migración desde HTML/CSS/JavaScript a React + Vite con API Express y Neon PostgreSQL.

## Estructura
- `src/`: interfaz React y navegación.
- `api/index.js`: API Express servida como función de Vercel.
- `DATABASE_URL`: conexión Neon solo del lado servidor.
- `JWT_SECRET`: firma de sesiones, solo servidor.

## Desarrollo
1. Copiar `.env.example` a `.env` y completar las variables de entorno.
2. Instalar dependencias con `npm install`.
3. Ejecutar `npm run dev` para la interfaz.

La API se publica bajo `/api` en Vercel. Para pruebas locales se puede usar Vercel CLI o configurar un proxy de desarrollo.

## Seguridad
- Nunca colocar credenciales de Neon en variables `VITE_*` ni en el navegador.
- La autenticación usa JWT y bcrypt; las contraseñas antiguas en texto plano se convierten a bcrypt después de un inicio de sesión válido.
- Los pagos son simulados para el proyecto académico; no se almacenan números completos de tarjeta ni CVV.
- La base de datos de desarrollo debe apuntar a la rama Neon `metrobus-react-dev`.
