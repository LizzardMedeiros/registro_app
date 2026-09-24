const jwt = require('jsonwebtoken');

const DEV_SECRET = 'troque-este-segredo';
const JWT_SECRET = process.env.JWT_SECRET || DEV_SECRET;

// Em produção o segredo vem do SSM; nunca aceitar o valor padrão de desenvolvimento.
if (process.env.NODE_ENV === 'production' && JWT_SECRET === DEV_SECRET) {
  throw new Error('JWT_SECRET precisa ser definido em produção');
}

function signToken(user) {
  return jwt.sign({ sub: user.id, email: user.email }, JWT_SECRET, { expiresIn: '1h' });
}

function requireAuth(req, res, next) {
  const header = req.headers.authorization || '';
  const [scheme, token] = header.split(' ');
  if (scheme !== 'Bearer' || !token) {
    return res.status(401).json({ error: 'Token ausente' });
  }
  try {
    req.user = jwt.verify(token, JWT_SECRET);
    next();
  } catch {
    return res.status(401).json({ error: 'Token inválido ou expirado' });
  }
}

module.exports = { signToken, requireAuth };
