// Comportamentos HTTP que não dependem do banco (validação, CORS, health).
const test = require('node:test');
const assert = require('node:assert/strict');
const { startApp } = require('./helpers');

const SITE = 'http://site.example';
let app;

test.before(async () => {
  app = await startApp({ corsOrigins: [SITE] });
});
test.after(() => app.close());

test('health responde ok', async () => {
  const r = await app.request('/api/health');
  assert.equal(r.status, 200);
  assert.equal(r.body.ok, true);
});

test('register valida campos obrigatórios, e-mail e tamanho da senha', async () => {
  const cases = [
    [{ email: 'a@b.com', password: '123456' }, 'Nome, e-mail e senha são obrigatórios'],
    [{ name: 'A', email: 'invalido', password: '123456' }, 'E-mail inválido'],
    [{ name: 'A', email: 'a@b.com', password: '123' }, 'A senha deve ter pelo menos 6 caracteres'],
  ];
  for (const [body, error] of cases) {
    const r = await app.request('/api/register', { method: 'POST', body });
    assert.equal(r.status, 400);
    assert.equal(r.body.error, error);
  }
});

test('login exige e-mail e senha', async () => {
  const r = await app.request('/api/login', { method: 'POST', body: { email: 'a@b.com' } });
  assert.equal(r.status, 400);
});

test('me sem token retorna 401', async () => {
  const r = await app.request('/api/me');
  assert.equal(r.status, 401);
});

test('CORS libera somente a origem configurada', async () => {
  const ok = await app.request('/api/health', { headers: { Origin: SITE } });
  assert.equal(ok.headers.get('access-control-allow-origin'), SITE);

  const other = await app.request('/api/health', { headers: { Origin: 'http://evil.example' } });
  assert.equal(other.headers.get('access-control-allow-origin'), null);
});

test('preflight OPTIONS responde 204 com cabeçalhos permitidos', async () => {
  const r = await app.request('/api/register', {
    method: 'OPTIONS',
    headers: { Origin: SITE, 'Access-Control-Request-Method': 'POST' },
  });
  assert.equal(r.status, 204);
  assert.match(r.headers.get('access-control-allow-headers'), /Authorization/);
});
