import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  build: { outDir: "dist", sourcemap: true },
  server: {
    port: 5173,
    // Local dev only. In the cluster, nginx proxies /api to the shift-api
    // Service, so the browser never learns the backend address.
    proxy: { "/api": { target: "http://localhost:8000", changeOrigin: true } },
  },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./src/setupTests.ts"],
    coverage: { reporter: ["text", "lcov"], include: ["src/**"] },
  },
});
