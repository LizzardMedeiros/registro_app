// Testa o comportamento do frontend num DOM simulado (jsdom), com fetch falso.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { JSDOM } = require('jsdom');

const DIR = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(DIR, 'index.html'), 'utf8');
const appJs = fs.readFileSync(path.join(DIR, 'app.js'), 'utf8');

// Monta a página com a config informada e um fetch que registra as chamadas.
function load({ config, responses = {}, token } = {}) {
  const dom = new JSDOM(html, { runScripts: 'outside-only', url: 'http://site.example/' });
  const { window } = dom;
  const calls = [];
  window.fetch = async (url, options = {}) => {
    calls.push({ url, options });
    const key = `${options.method || 'GET'} ${new URL(url, window.location.href).pathname}`;
    const [status, body] = responses[key] || [404, { error: 'não mapeado' }];
    return { ok: status < 400, status, json: async () => body };
  };
  if (token) window.localStorage.setItem('token', token);
  if (config) window.APP_CONFIG = config;
  window.eval(appJs);
  return { window, doc: window.document, calls };
}

const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

function submit(doc, formId, values) {
  const form = doc.getElementById(formId);
  for (const [name, value] of Object.entries(values)) form.elements[name].value = value;
  form.dispatchEvent(new doc.defaultView.Event('submit', { cancelable: true }));
}

const USER = { id: 1, name: 'Ana', email: 'ana@example.com', created_at: '2026-09-24T12:00:00Z' };

test('usa apiBaseUrl da config para chamar a API e exibe a versão', async () => {
  const { doc, calls } = load({
    config: { apiBaseUrl: 'http://10.0.0.1:3000/', version: 'abc1234' },
    responses: { 'POST /api/register': [201, { user: USER, token: 't1' }] },
  });
  assert.equal(doc.getElementById('version').textContent, 'abc1234');

  submit(doc, 'register-form', { name: 'Ana', email: 'ana@example.com', password: 'segredo1' });
  await tick();

  assert.equal(calls[0].url, 'http://10.0.0.1:3000/api/register');
  assert.deepEqual(JSON.parse(calls[0].options.body), { name: 'Ana', email: 'ana@example.com', password: 'segredo1' });
  assert.equal(doc.getElementById('profile-name').textContent, 'Ana');
  assert.equal(doc.getElementById('profile-view').classList.contains('hidden'), false);
});

test('sem config, usa a mesma origem (proxy local)', async () => {
  const { doc, calls } = load({ responses: { 'POST /api/login': [200, { user: USER, token: 't1' }] } });
  submit(doc, 'login-form', { email: 'ana@example.com', password: 'segredo1' });
  await tick();
  assert.equal(calls[0].url, '/api/login');
  assert.equal(doc.getElementById('version').textContent, 'dev');
});

test('login com erro mostra a mensagem da API e mantém a tela de login', async () => {
  const { doc, window } = load({
    responses: { 'POST /api/login': [401, { error: 'Credenciais inválidas' }] },
  });
  submit(doc, 'login-form', { email: 'ana@example.com', password: 'errada00' });
  await tick();
  assert.equal(doc.getElementById('message').textContent, 'Credenciais inválidas');
  assert.equal(doc.getElementById('profile-view').classList.contains('hidden'), true);
  assert.equal(window.localStorage.getItem('token'), null);
});

test('restaura a sessão com token salvo e envia Authorization', async () => {
  const { doc, calls } = load({ token: 'salvo', responses: { 'GET /api/me': [200, { user: USER }] } });
  await tick();
  assert.equal(calls[0].options.headers.Authorization, 'Bearer salvo');
  assert.equal(doc.getElementById('profile-email').textContent, 'ana@example.com');
});

test('logout remove o token e volta para o login', async () => {
  const { doc, window } = load({ token: 'salvo', responses: { 'GET /api/me': [200, { user: USER }] } });
  await tick();
  doc.getElementById('logout').click();
  assert.equal(window.localStorage.getItem('token'), null);
  assert.equal(doc.getElementById('auth-view').classList.contains('hidden'), false);
});
