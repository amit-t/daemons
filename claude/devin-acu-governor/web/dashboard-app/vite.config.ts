import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

// base './' — the build is copied into $DAG_STATE_DIR/dashboard/latest and
// served from an arbitrary local port, so all asset URLs must be relative.
export default defineConfig({
  plugins: [react()],
  base: './',
  build: {
    outDir: 'dist',
    chunkSizeWarningLimit: 900,
  },
  test: {
    environment: 'jsdom',
  },
})
