// Integração com PostgreSQL real e descartável (docker local ou service do CI).
// Requer DATABASE_URL (ou PG*); as migrations são aplicadas pelo próprio teste.
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { Client } = require('pg');
const { startApp } = require('./helpers');

const hasDb = Boolean(process.env.DATABASE_URL);
// No CI (REQUIRE_DB=1) a ausência do banco é falha, não teste pulado.
if (!hasDb && process.env.REQUIRE_DB === '1') throw new Error('REQUIRE_DB=1, mas DATABASE_URL não foi definido');
const opts = { skip: hasDb ? false : 'DATABASE_URL não definido' };

function migrate() {
  return spawnSync(process.execPath, [path.join(__dirname, '..', 'src', 'migrate.js')], {
    env: process.env,
    encoding: 'utf8',
  });
}

async function sql(query, params) {
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  try {
    return await client.query(query, params);
  } finally {
    await client.end();
  }
}

test.describe('integração com PostgreSQL', opts, () => {
  let app;

  test.before(async () => {
    await sql('DROP TABLE IF EXISTS users, schema_migrations');
    const r = migrate();
    assert.equal(r.status, 0, r.stderr);
    app = await startApp();
  });
  test.after(async () => {
    if (app) await app.close();
    await require('../src/db').end();
  });

  test('migrations são aplicadas uma única vez e registradas', async () => {
    const again = migrate();
    assert.equal(again.status, 0, again.stderr);
    assert.doesNotMatch(again.stdout, /Aplicando/);
    const { rows } = await sql('SELECT name FROM schema_migrations ORDER BY name');
    assert.deepEqual(
      rows.map((r) => r.name),
      ['001_init.sql'],
    );
  });

  test('fluxo register → login → me persiste o usuário no banco', async () => {
    const reg = await app.request('/api/register', {
      method: 'POST',
      body: { name: ' Ana ', email: 'Ana@Example.com ', password: 'segredo1' },
    });
    assert.equal(reg.status, 201);
    assert.equal(reg.body.user.name, 'Ana');
    assert.equal(reg.body.user.email, 'ana@example.com');
    assert.equal(reg.body.user.password_hash, undefined);

    const { rows } = await sql('SELECT email, password_hash FROM users WHERE email = $1', ['ana@example.com']);
    assert.equal(rows.length, 1);
    assert.notEqual(rows[0].password_hash, 'segredo1');

    const login = await app.request('/api/login', {
      method: 'POST',
      body: { email: 'ANA@example.com', password: 'segredo1' },
    });
    assert.equal(login.status, 200);
    assert.equal(login.body.user.password_hash, undefined);

    const me = await app.request('/api/me', { headers: { Authorization: `Bearer ${login.body.token}` } });
    assert.equal(me.status, 200);
    assert.equal(me.body.user.email, 'ana@example.com');
  });

  test('e-mail duplicado retorna 409', async () => {
    const body = { name: 'Bia', email: 'bia@example.com', password: 'segredo1' };
    assert.equal((await app.request('/api/register', { method: 'POST', body })).status, 201);
    const dup = await app.request('/api/register', { method: 'POST', body });
    assert.equal(dup.status, 409);
    assert.equal(dup.body.error, 'E-mail já cadastrado');
  });

  test('senha errada retorna 401', async () => {
    const r = await app.request('/api/login', {
      method: 'POST',
      body: { email: 'bia@example.com', password: 'errada00' },
    });
    assert.equal(r.status, 401);
  });
});
