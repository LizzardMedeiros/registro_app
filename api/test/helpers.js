const { createApp } = require('../src/app');

// Sobe o app numa porta efêmera e devolve um cliente fetch simples.
async function startApp(options) {
  const server = createApp(options).listen(0);
  await new Promise((resolve) => server.once('listening', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  async function request(path, { method = 'GET', body, headers = {} } = {}) {
    const res = await fetch(base + path, {
      method,
      headers: { 'Content-Type': 'application/json', ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    let json = null;
    try {
      json = JSON.parse(text);
    } catch {
      /* resposta sem JSON */
    }
    return { status: res.status, headers: res.headers, body: json };
  }
  return { request, close: () => new Promise((resolve) => server.close(resolve)) };
}

module.exports = { startApp };
