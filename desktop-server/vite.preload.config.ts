import { defineConfig } from 'vite';

// Preload config. Override the plugin's `[name].js` filename so the output
// is `.cjs` (the project is `"type": "module"`, which would otherwise refuse
// the CommonJS-shaped preload bundle).
export default defineConfig({
  build: {
    rollupOptions: {
      output: {
        entryFileNames: '[name].cjs',
        chunkFileNames: '[name].cjs',
      },
    },
  },
});
