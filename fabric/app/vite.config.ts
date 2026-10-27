// Vite configuration from the Fabric Apps data app template (MIT), trimmed to what this app uses:
// React with SWC, the dev-only Local Network Access headers for running inside the Fabric portal's frame,
// and THIRD_PARTY_NOTICES.txt for every bundled dependency.
import react from "@vitejs/plugin-react-swc";
import { defineConfig, type PluginOption } from "vite";
import license from "rollup-plugin-license";
import { resolve } from "path";

const projectRoot = process.env.PROJECT_ROOT || import.meta.dirname;

// Dev only: lets the Fabric portal (a public origin) frame http://localhost under Local Network Access checks.
const localNetworkAccessPlugin: PluginOption = {
    name: "local-network-access-headers",
    configureServer(server) {
        server.middlewares.use((req, res, next) => {
            res.setHeader("Access-Control-Allow-Private-Network", "true");
            if (req.method === "OPTIONS" && req.headers["access-control-request-private-network"]) {
                const origin = req.headers.origin || "*";
                res.setHeader("Access-Control-Allow-Origin", origin);
                res.setHeader("Access-Control-Allow-Credentials", "true");
                res.setHeader("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS");
                res.setHeader("Access-Control-Allow-Headers", req.headers["access-control-request-headers"] || "*");
                res.statusCode = 204;
                res.end();
                return;
            }
            next();
        });
    },
};

export default defineConfig({
    plugins: [react(), localNetworkAccessPlugin],
    resolve: {
        alias: { "@": resolve(projectRoot, "src") },
    },
    build: {
        sourcemap: false,
        chunkSizeWarningLimit: 700,
        rollupOptions: {
            plugins: [
                license({
                    thirdParty: {
                        multipleVersions: true,
                        output: {
                            file: resolve(projectRoot, "dist", "THIRD_PARTY_NOTICES.txt"),
                            template(dependencies) {
                                if (dependencies.length === 0) return "No third-party dependencies.";
                                return (
                                    "This file was generated at build time.\n\n" +
                                    dependencies
                                        .map((dep) => {
                                            const lines = [`${dep.name}@${dep.version}`, `License: ${dep.license || "UNKNOWN"}`];
                                            if (dep.licenseText) lines.push("", dep.licenseText.trim());
                                            return lines.join("\n");
                                        })
                                        .join("\n\n" + "=".repeat(60) + "\n\n")
                                );
                            },
                        },
                    },
                }),
            ],
        },
    },
});
