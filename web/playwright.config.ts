import { defineConfig, devices } from '@playwright/test'

// End to end tests run against a live relay node that serves the built client (web/dist).
// RELAY_NODE_URL=http://127.0.0.1:8080 pnpm e2e
export default defineConfig({
  testDir: './tests',
  timeout: 60_000,
  retries: 0,
  reporter: [['list']],
  use: {
    baseURL: process.env.RELAY_NODE_URL,
    trace: 'retain-on-failure',
  },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
})
