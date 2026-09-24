const test = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');
const { signToken, requireAuth } = require('../src/auth');

function run(header) {
  const req = { headers: header ? { authorization: header } : {} };
  const res = {
    statusCode: 200,
    body: null,
    status(code) {
      this.statusCode = code;
      return this;
    },
    json(body) {
      this.body = body;
      return this;
    },
  };
  let nextCalled = false;
  requireAuth(req, res, () => {
    nextCalled = true;
  });
  return { req, res, nextCalled };
}

test('signToken gera JWT com sub e email do usuário, válido por 1h', () => {
  const token = signToken({ id: 42, email: 'a@b.com' });
  const payload = jwt.decode(token);
  assert.equal(payload.sub, 42);
  assert.equal(payload.email, 'a@b.com');
  assert.equal(payload.exp - payload.iat, 3600);
});

test('requireAuth aceita Bearer válido e popula req.user', () => {
  const { req, nextCalled } = run(`Bearer ${signToken({ id: 7, email: 'x@y.com' })}`);
  assert.equal(nextCalled, true);
  assert.equal(req.user.sub, 7);
});

test('requireAuth rejeita cabeçalho ausente ou com esquema errado', () => {
  for (const header of [undefined, 'Basic abc', 'Bearer']) {
    const { res, nextCalled } = run(header);
    assert.equal(nextCalled, false);
    assert.equal(res.statusCode, 401);
    assert.equal(res.body.error, 'Token ausente');
  }
});

test('requireAuth rejeita token assinado com outro segredo', () => {
  const forged = jwt.sign({ sub: 1 }, 'outro-segredo');
  const { res, nextCalled } = run(`Bearer ${forged}`);
  assert.equal(nextCalled, false);
  assert.equal(res.statusCode, 401);
  assert.equal(res.body.error, 'Token inválido ou expirado');
});

test('auth recusa o segredo padrão quando NODE_ENV=production', () => {
  const { spawnSync } = require('node:child_process');
  const r = spawnSync(process.execPath, ['-e', "require('./src/auth')"], {
    cwd: require('node:path').join(__dirname, '..'),
    env: { ...process.env, NODE_ENV: 'production', JWT_SECRET: '' },
    encoding: 'utf8',
  });
  assert.notEqual(r.status, 0);
  assert.match(r.stderr, /JWT_SECRET precisa ser definido/);
});
