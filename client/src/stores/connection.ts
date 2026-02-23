import { defineStore } from "pinia";
import { ref, computed } from "vue";

export type ConnectionStatus =
  | "Disconnected"
  | "Connecting"
  | "Connected"
  | "Disconnecting";

export interface TrafficData {
  up_speed: number;
  down_speed: number;
  up_total: number;
  down_total: number;
}

export interface AppSettings {
  config_url: string;
  refresh_interval_min: number;
  last_update: string | null;
}

const isTauri = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

async function tauriInvoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<T>(cmd, args);
}

async function tauriListen<T>(event: string, handler: (e: { payload: T }) => void) {
  const { listen } = await import("@tauri-apps/api/event");
  return listen<T>(event, handler);
}

export const useConnectionStore = defineStore("connection", () => {
  const status = ref<ConnectionStatus>("Disconnected");
  const traffic = ref<TrafficData>({
    up_speed: 0,
    down_speed: 0,
    up_total: 0,
    down_total: 0,
  });
  const settings = ref<AppSettings>({
    config_url: "",
    refresh_interval_min: 30,
    last_update: null,
  });
  const error = ref<string | null>(null);
  const settingsOpen = ref(false);

  const isConnected = computed(() => status.value === "Connected");
  const isTransitioning = computed(
    () => status.value === "Connecting" || status.value === "Disconnecting"
  );

  async function init() {
    if (!isTauri) {
      // Browser dev mode — show mock data for UI preview
      settings.value = {
        config_url: "https://vpn:pass@example.com:8443/secret/config.json",
        refresh_interval_min: 30,
        last_update: String(Math.floor(Date.now() / 1000) - 3600),
      };
      return;
    }

    try {
      const s = await tauriInvoke<AppSettings>("get_settings");
      settings.value = s;
    } catch (e) {
      console.error("Failed to load settings:", e);
    }

    try {
      const s = await tauriInvoke<ConnectionStatus>("get_status");
      status.value = s;
    } catch (e) {
      console.error("Failed to get status:", e);
    }

    tauriListen<string>("status-change", (event) => {
      status.value = event.payload as ConnectionStatus;
      error.value = null;
    });

    tauriListen<TrafficData>("traffic-update", (event) => {
      traffic.value = event.payload;
    });
  }

  async function connect() {
    if (isTransitioning.value || isConnected.value) return;
    error.value = null;

    if (!isTauri) {
      // Browser mock: simulate connect flow
      status.value = "Connecting";
      setTimeout(() => {
        status.value = "Connected";
        traffic.value = { up_speed: 12400, down_speed: 458700, up_total: 1024000, down_total: 52428800 };
      }, 1500);
      return;
    }

    try {
      await tauriInvoke("connect");
    } catch (e) {
      error.value = String(e);
      status.value = "Disconnected";
    }
  }

  async function disconnect() {
    if (isTransitioning.value || !isConnected.value) return;
    error.value = null;

    if (!isTauri) {
      status.value = "Disconnecting";
      setTimeout(() => {
        status.value = "Disconnected";
        traffic.value = { up_speed: 0, down_speed: 0, up_total: 0, down_total: 0 };
      }, 800);
      return;
    }

    try {
      await tauriInvoke("disconnect");
    } catch (e) {
      error.value = String(e);
    }
  }

  async function toggle() {
    if (isConnected.value) {
      await disconnect();
    } else {
      await connect();
    }
  }

  async function updateConfig() {
    if (!isTauri) return;
    try {
      const timestamp = await tauriInvoke<string>("update_config");
      settings.value.last_update = timestamp;
      error.value = null;
    } catch (e) {
      error.value = String(e);
    }
  }

  async function saveSettings(url: string, interval: number) {
    if (!isTauri) {
      settings.value.config_url = url;
      settings.value.refresh_interval_min = interval;
      return;
    }
    try {
      await tauriInvoke("save_settings", {
        configUrl: url,
        refreshIntervalMin: interval,
      });
      settings.value.config_url = url;
      settings.value.refresh_interval_min = interval;
      error.value = null;
    } catch (e) {
      error.value = String(e);
    }
  }

  return {
    status,
    traffic,
    settings,
    error,
    settingsOpen,
    isConnected,
    isTransitioning,
    init,
    connect,
    disconnect,
    toggle,
    updateConfig,
    saveSettings,
  };
});
