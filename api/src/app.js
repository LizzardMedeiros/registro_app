const express = require('express');
const bcrypt = require('bcryptjs');
const pool = require('./db');
const { signToken, requireAuth } = require('./auth');

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// Libera CORS apenas para as origens configuradas (site no S3, em outra origem).
// Sem CORS_ORIGIN, nenhuma origem externa é liberada: o front local usa o proxy do nginx.
function cors(allowed) {
  return (req, res, next) => {
    const origin = req.headers.origin;
    if (origin && allowed.includes(origin)) {
      res.set('Access-Control-Allow-Origin', origin);
      res.set('Vary', 'Origin');
      res.set('Access-Control-Allow-Headers', 'Content-Type, Authorization');
      res.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
      res.set('Access-Control-Max-Age', '600');
    }
    if (req.method === 'OPTIONS') return res.sendStatus(204);
    next();
  };
}

function createApp({ corsOrigins = [] } = {}) {
  const app = express();
  app.use(cors(corsOrigins));
  app.use(express.json());

  app.get('/api/health', (req, res) => res.json({ ok: true, version: process.env.APP_VERSION || 'dev' }));

  app.post('/api/register', async (req, res) => {
    const body = req.body || {};
    const name = typeof body.name === 'string' ? body.name.trim() : '';
    const email = typeof body.email === 'string' ? body.email.toLowerCase().trim() : '';
    const { password } = body;
    if (!name || !email || !password) {
      return res.status(400).json({ error: 'Nome, e-mail e senha são obrigatórios' });
    }
    if (!EMAIL_RE.test(email)) {
      return res.status(400).json({ error: 'E-mail inválido' });
    }
    if (typeof password !== 'string' || password.length < 6) {
      return res.status(400).json({ error: 'A senha deve ter pelo menos 6 caracteres' });
    }

    try {
      const hash = await bcrypt.hash(password, 10);
      const { rows } = await pool.query(
        'INSERT INTO users (name, email, password_hash) VALUES ($1, $2, $3) RETURNING id, name, email, created_at',
        [name, email, hash],
      );
      const user = rows[0];
      res.status(201).json({ user, token: signToken(user) });
    } catch (err) {
      if (err.code === '23505') {
        return res.status(409).json({ error: 'E-mail já cadastrado' });
      }
      console.error(err);
      res.status(500).json({ error: 'Erro interno' });
    }
  });

  app.post('/api/login', async (req, res) => {
    const { email, password } = req.body || {};
    if (!email || !password) {
      return res.status(400).json({ error: 'E-mail e senha são obrigatórios' });
    }

    try {
      const { rows } = await pool.query('SELECT * FROM users WHERE email = $1', [email.toLowerCase().trim()]);
      const user = rows[0];
      if (!user || !(await bcrypt.compare(password, user.password_hash))) {
        return res.status(401).json({ error: 'Credenciais inválidas' });
      }
      // eslint-disable-next-line no-unused-vars
      const { password_hash, ...publicUser } = user;
      res.json({ user: publicUser, token: signToken(user) });
    } catch (err) {
      console.error(err);
      res.status(500).json({ error: 'Erro interno' });
    }
  });

  app.get('/api/me', requireAuth, async (req, res) => {
    try {
      const { rows } = await pool.query('SELECT id, name, email, created_at FROM users WHERE id = $1', [req.user.sub]);
      if (!rows[0]) return res.status(404).json({ error: 'Usuário não encontrado' });
      res.json({ user: rows[0] });
    } catch (err) {
      console.error(err);
      res.status(500).json({ error: 'Erro interno' });
    }
  });

  return app;
}

module.exports = { createApp };
