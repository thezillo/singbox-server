<script setup lang="ts">
import { useConnectionStore } from "../stores/connection";

const store = useConnectionStore();
const isTauri = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

async function closeWindow() {
  if (!isTauri) return;
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  getCurrentWindow().close();
}

async function minimizeWindow() {
  if (!isTauri) return;
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  getCurrentWindow().minimize();
}
</script>

<template>
  <header class="header">
    <div class="window-controls">
      <button class="win-btn close" @click="closeWindow()" />
      <button class="win-btn minimize" @click="minimizeWindow()" />
    </div>
    <span class="header-title">Singbox</span>
    <div class="header-actions">
      <button class="icon-btn" @click="store.settingsOpen = !store.settingsOpen" title="Settings">
        <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <circle cx="12" cy="12" r="3"/><path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42"/>
        </svg>
      </button>
    </div>
  </header>
</template>
