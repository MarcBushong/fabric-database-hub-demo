import { defineConfig } from "vitest/config";
import { resolve } from "path";

export default defineConfig({
    test: {
        environment: "jsdom",
        setupFiles: ["src/test/setup.ts"],
        globals: true,
        include: ["src/**/*.test.{ts,tsx}"],
        // A page test waits for every query and chart, and on a busy machine (several runs at once, a shared CI runner) one
        // took 5.24 s at 97 % CPU: 15 seconds, not Vitest's 5, keeps a slow run from failing a correct test.
        testTimeout: 15000,
    },
    resolve: {
        alias: { "@": resolve(import.meta.dirname, "src") },
    },
});
