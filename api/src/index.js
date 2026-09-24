const { createApp } = require('./app');

const corsOrigins = (process.env.CORS_ORIGIN || '')
  .split(',')
  .map((o) => o.trim())
  .filter(Boolean);

const PORT = process.env.PORT || 3000;
createApp({ corsOrigins }).listen(PORT, () => console.log(`API rodando na porta ${PORT}`));
