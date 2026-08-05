import { build } from 'esbuild';
import { cpSync, mkdirSync, rmSync } from 'node:fs';

rmSync('dist', { recursive: true, force: true });
mkdirSync('dist', { recursive: true });

await build({
  entryPoints: ['src/content.ts', 'src/worker.ts', 'src/levelMain.ts'],
  outdir: 'dist',
  bundle: true,
  format: 'esm',
  target: 'chrome120',
  logLevel: 'info',
});

cpSync('manifest.json', 'dist/manifest.json');
console.log('✓ Расширение собрано в extension/dist');
