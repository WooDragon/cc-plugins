import { defineConfig } from 'astro/config';
import manifestGen from './src/integrations/manifest-gen';

export default defineConfig({
  output: 'static',
  site: process.env.PPT_SITE_URL || 'http://localhost:4321',
  integrations: [manifestGen()],
  vite: {
    build: {
      rollupOptions: {
        external: ['/assets/motion.min.js'],
      },
    },
  },
});
