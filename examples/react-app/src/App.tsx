import { config } from "./config";

export default function App() {
  return (
    <main>
      <h1>{import.meta.env.VITE_APP_NAME}</h1>
      <ul>
        <li>API URL: {config.apiUrl}</li>
        <li>API base: {import.meta.env.VITE_API_BASE}</li>
        <li>Flags: {import.meta.env.VITE_FEATURE_FLAGS}</li>
        <li>Debug: {String(config.debug)}</li>
      </ul>
    </main>
  );
}
