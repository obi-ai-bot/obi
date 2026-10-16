import { readFileSync, existsSync, statSync } from 'node:fs';
import { resolve, extname, join } from 'node:path';
import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';

// Oby lives in ../oby and stays standalone. In dev it's served at /oby/;
// a build copies the page and three.js in next to the app.
const OBY = resolve(__dirname, '../oby');
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

export default defineConfig({
  root: resolve(__dirname, 'src/renderer'),
  base: './',
  plugins: [react(), oby()],
  server: { port: Number(process.env.PORT) || 5175, strictPort: true },
  build: { outDir: resolve(__dirname, 'out/renderer'), emptyOutDir: true },
});
