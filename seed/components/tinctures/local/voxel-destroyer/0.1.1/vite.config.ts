import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  base: './',
  // The entry is src/index.html; the build lands in dist/ and is copied to
  // the version root, which is what the tincture serves. Keeping them apart
  // is what lets this tincture be rebuilt more than once — 0.1.0 shipped
  // with its source entry already overwritten by its own build.
  root: 'src',
  publicDir: '../public',
  build: {
    outDir: '../dist',
    emptyOutDir: true,
  },
});
