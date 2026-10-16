import { existsSync, readFileSync, statSync } from 'node:fs';
import { extname, join, resolve } from 'node:path';
import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';

// Oby, the mascot, is character/ at the repository's root and stays standalone. In dev it's
// served at /oby/; a build copies its page and three.js in next to the app, as dist/oby/.
const OBY = resolve(__dirname, '../../character');
const OBY_FILES = ['oby.html', 'vendor/three.module.js'];
const TYPES: Record<string, string> = { '.html': 'text/html', '.js': 'text/javascript' };

function oby(): Plugin {
  return {
    name: 'oby',
    configureServer(server) {
      server.middlewares.use('/oby', (req, res, next) => {
        const file = join(OBY, decodeURIComponent((req.url || '/').split('?')[0]));
        if (!file.startsWith(OBY) || !existsSync(file) || !statSync(file).isFile()) return next();
        res.setHeader('Content-Type', TYPES[extname(file)] || 'application/octet-stream');
        res.end(readFileSync(file));
      });
    },
    generateBundle() {
      for (const f of OBY_FILES) this.emitFile({ type: 'asset', fileName: `oby/${f}`, source: readFileSync(join(OBY, f)) });
    },
  };
}

// In dev (npm run dev), /v1 goes to obid: OBID_URL (http://127.0.0.1:7777 unless set), with the
// API token read from obid's home (OBID_HOME) here in the dev server, so the page never holds it.
// Built, obid serves the page itself at /app/ and the page signs in with obid's session cookie.
function obid() {
  const home = process.env.OBID_HOME;
  if (!home) return undefined;
  const token = readFileSync(join(home, 'api-token'), 'utf8').trim();
  return {
    '/v1': { target: process.env.OBID_URL || 'http://127.0.0.1:7777', changeOrigin: true, headers: { Authorization: `Bearer ${token}` } },
  };
}

export default defineConfig({
  root: __dirname,
  base: './',
  plugins: [react(), oby()],
  server: { port: Number(process.env.PORT) || 5175, strictPort: true, proxy: obid() },
  build: { outDir: resolve(__dirname, 'dist'), emptyOutDir: true },
});
