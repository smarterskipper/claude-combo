// playwright.config.ts: one server per lane on LANE_PORT; never reuse another lane's server.
import { defineConfig, devices } from '@playwright/test'
const port = Number(process.env.LANE_PORT)
if (!port) throw new Error('LANE_PORT is not set')
export default defineConfig({
  use: { baseURL: `http://127.0.0.1:${port}`, timezoneId: 'UTC', locale: 'en-US' },
  projects: [
    { name: 'desktop', use: { viewport: { width: 1440, height: 900 } } },
    { name: 'phone', use: { ...devices['iPhone 13'] } },
  ],
  webServer: { command: `npx vite --port ${port} --strictPort --host 127.0.0.1`, url: `http://127.0.0.1:${port}`, reuseExistingServer: false },
  expect: { toHaveScreenshot: { animations: 'disabled', maxDiffPixelRatio: 0.01 } },
})
