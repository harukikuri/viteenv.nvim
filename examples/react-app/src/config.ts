// Central place that reads Vite env. Each `import.meta.env.VITE_*` below is a
// spot where viteenv.nvim will render the resolved value inline.

export const config = {
  appName: import.meta.env.VITE_APP_NAME,
  apiUrl: import.meta.env.VITE_API_URL, // expanded from VITE_API_BASE
  apiBase: import.meta.env.VITE_API_BASE, // differs dev vs prod
  publicKey: import.meta.env.VITE_PUBLIC_KEY,
  featureFlags: import.meta.env.VITE_FEATURE_FLAGS,
  debug: import.meta.env.VITE_DEBUG === "true",

  // bracket access is also supported by the lens
  rawDebug: import.meta.env["VITE_DEBUG"],

  // built-ins
  mode: import.meta.env.MODE,
  isDev: import.meta.env.DEV,
};
