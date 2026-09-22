import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

// Static site — relative base so the build works when served from any path
// (GitHub Pages subfolder, file://, or a plain static host).
export default defineConfig({
  base: './',
  plugins: [svelte()],
  build: {
    target: 'es2020',
    outDir: 'dist',
  },
});
