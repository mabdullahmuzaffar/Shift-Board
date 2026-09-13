/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_DEMO_WORKER_ID?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
