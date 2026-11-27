// Conexión a Neon: se crea una sola vez y la usan todas las demás carpetas de js/.
import { neon } from "https://esm.sh/@neondatabase/serverless";

// Pega aquí la cadena de conexión de tu proyecto Neon (Dashboard → Connect).
const CADENA_DE_CONEXION = "postgresql://neondb_owner:npg_b9hI4RHCnEJY@ep-purple-resonance-b5bv6ioa-pooler.c-7.us-east-2.aws.neon.tech/neondb?sslmode=require";

let sql;
try {
  sql = neon(CADENA_DE_CONEXION);
} catch (error) {
  console.error("No se pudo crear la conexión a Neon. Revisa la cadena en js/config/neon-config.js", error);
  sql = () => {
    throw new Error("Falta configurar tu cadena de conexión real de Neon en js/config/neon-config.js");
  };
}

export { sql };
