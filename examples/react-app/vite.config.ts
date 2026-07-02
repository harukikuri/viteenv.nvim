import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// https://vite.dev/config/
export default defineConfig(({ mode }) => ({
  plugins: [react()],
  define: {
    // a user define the lens can also surface
    __BUILD_MODE__: JSON.stringify(mode),
  },
}));
