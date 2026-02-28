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
      <svg viewBox="250 230 524 540" fill="none" stroke="white" stroke-width="28" stroke-linecap="round" stroke-linejoin="round">
        <polygon points="512,270 730,390 512,510 294,390"/>
        <polygon points="294,390 512,510 512,730 294,610"/>
        <polygon points="730,390 512,510 512,730 730,610"/>
      </svg>
    </div>
    <div class="logo-title">singbox</div>
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
