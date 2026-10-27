import { defineConfig } from "vitest/config";
import { resolve } from "path";

export default defineConfig({
    test: {
        environment: "jsdom",
        setupFiles: ["src/test/setup.ts"],
        globals: true,
        include: ["src/**/*.test.{ts,tsx}"],
    },
    resolve: {
        alias: { "@": resolve(import.meta.dirname, "src") },
    },
});
