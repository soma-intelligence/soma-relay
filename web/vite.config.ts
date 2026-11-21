import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// The node serves web/dist at `/`, so every asset path stays relative to the origin.
export default defineConfig({
  plugins: [react()],
  build: { target: 'es2022', sourcemap: false },
  worker: { format: 'es' },
  server: {
    port: 5180,
    // RELAY_NODE_URL lets `pnpm dev` talk to a local node through the dev server.
    proxy: process.env.RELAY_NODE_URL
      ? {
          '/v1': { target: process.env.RELAY_NODE_URL, ws: true, changeOrigin: true },
          '/healthz': { target: process.env.RELAY_NODE_URL, changeOrigin: true },
        }
      : undefined,
  },
})
