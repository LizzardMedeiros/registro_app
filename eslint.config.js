const js = require('@eslint/js');
const globals = require('globals');

module.exports = [
  { ignores: ['**/node_modules/**', 'dist/**'] },
  js.configs.recommended,
  {
    files: ['api/**/*.js', 'eslint.config.js', 'frontend/test/**/*.js'],
    languageOptions: { sourceType: 'commonjs', globals: globals.node },
  },
  {
    files: ['frontend/*.js'],
    languageOptions: { sourceType: 'script', globals: globals.browser },
  },
];
