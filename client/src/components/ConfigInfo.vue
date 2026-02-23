<script setup lang="ts">
import { computed } from "vue";
import { useConnectionStore } from "../stores/connection";

const store = useConnectionStore();

const lastUpdateText = computed(() => {
  const ts = store.settings.last_update;
  if (!ts) return "Never updated";

  const secs = parseInt(ts, 10);
  if (isNaN(secs)) return "Never updated";

  const diff = Math.floor(Date.now() / 1000) - secs;
  if (diff < 60) return "Updated just now";
  if (diff < 3600) return `Updated ${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `Updated ${Math.floor(diff / 3600)}h ago`;
  return `Updated ${Math.floor(diff / 86400)}d ago`;
});
</script>

<template>
  <div class="config-info" v-if="store.settings.config_url">
    <span>{{ lastUpdateText }}</span>
    <button class="refresh-btn" @click="store.updateConfig()" title="Refresh config">
      &#8635;
    </button>
  </div>
</template>
