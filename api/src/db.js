const fs = require('fs');
const { Pool } = require('pg');

// Em produção (RDS) a conexão usa TLS verificado com o bundle de CA da AWS.
// Sem DATABASE_URL, o pg usa PGHOST/PGUSER/PGPASSWORD/PGDATABASE do ambiente.
function sslConfig() {
  if (process.env.DB_SSL !== 'true') return undefined;
  const caPath = process.env.DB_SSL_CA || '/app/certs/rds-global-bundle.pem';
  return { rejectUnauthorized: true, ca: fs.readFileSync(caPath, 'utf8') };
}

const pool = new Pool({ connectionString: process.env.DATABASE_URL, ssl: sslConfig() });

module.exports = pool;
