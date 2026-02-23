<script setup lang="ts">
import { computed } from "vue";
import { useConnectionStore } from "../stores/connection";

const store = useConnectionStore();

function formatSpeed(bytes: number): string {
  if (bytes < 1024) return `${bytes} B/s`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB/s`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB/s`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB/s`;
}

function formatTotal(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

const upSpeed = computed(() => formatSpeed(store.traffic.up_speed));
const downSpeed = computed(() => formatSpeed(store.traffic.down_speed));
const upTotal = computed(() => formatTotal(store.traffic.up_total));
const downTotal = computed(() => formatTotal(store.traffic.down_total));
</script>

<template>
  <div class="traffic-stats" v-if="store.isConnected">
    <div class="stat-card">
      <span class="stat-icon up">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <line x1="12" y1="19" x2="12" y2="5"/><polyline points="5 12 12 5 19 12"/>
        </svg>
      </span>
      <div class="stat-speed">{{ upSpeed }}</div>
      <div class="stat-total">{{ upTotal }}</div>
      <div class="stat-label">Upload</div>
    </div>
    <div class="stat-card">
      <span class="stat-icon down">
        <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
          <line x1="12" y1="5" x2="12" y2="19"/><polyline points="19 12 12 19 5 12"/>
        </svg>
      </span>
      <div class="stat-speed">{{ downSpeed }}</div>
      <div class="stat-total">{{ downTotal }}</div>
      <div class="stat-label">Download</div>
    </div>
  </div>
</template>
