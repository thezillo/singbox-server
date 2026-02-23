<script setup lang="ts">
import { computed } from "vue";
import { useConnectionStore } from "../stores/connection";

const store = useConnectionStore();

const btnClass = computed(() => {
  switch (store.status) {
    case "Connected": return "connected";
    case "Connecting": return "connecting";
    case "Disconnecting": return "disconnecting";
    default: return "";
  }
});

const statusClass = computed(() => store.status.toLowerCase());

const statusText = computed(() => {
  switch (store.status) {
    case "Connected": return "Connected";
    case "Connecting": return "Connecting...";
    case "Disconnecting": return "Disconnecting...";
    default: return "Not connected";
  }
});
</script>

<template>
  <div class="logo-section">
    <div class="logo-icon">
      <svg viewBox="0 0 24 24" fill="none" stroke="white" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">
        <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z"/>
        <polyline points="9 12 11 14 15 10" v-if="store.isConnected"/>
      </svg>
    </div>
    <div class="logo-title">Singbox</div>
    <div class="logo-subtitle">VPN Client</div>
    <div class="status-pill" :class="statusClass">
      <span class="dot"></span>
      {{ statusText }}
    </div>
  </div>
  <div class="toggle-wrap">
    <button
      class="toggle-btn"
      :class="btnClass"
      :disabled="store.isTransitioning"
      @click="store.toggle()"
    >
      <span class="power-icon">&#9211;</span>
    </button>
  </div>
</template>
